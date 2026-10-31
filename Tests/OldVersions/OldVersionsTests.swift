import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceOldVersions

/// Old Versions on a fake home folder and fake Applications folders: which copy stays, what is offered, what is kept, and that the
/// cleaner moves only what a fresh scan still offers, never touching the Mac's own Library, Applications or launchd.
final class OldVersionsTests: XCTestCase {
    private var home: String!
    private var system: String!
    private var trash: String!
    private var library: String { (home as NSString).appendingPathComponent("Library") }
    private var userApps: String { (home as NSString).appendingPathComponent("Applications") }

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-old-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let root = (base as NSString).resolvingSymlinksInPath
        home = (root as NSString).appendingPathComponent("home")
        system = (root as NSString).appendingPathComponent("Applications")
        trash = (root as NSString).appendingPathComponent("Trash")
        for folder in [home!, system!, trash!, userApps] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: ((home as NSString).deletingLastPathComponent))
    }

    private func scanner(running: Set<String> = [], ids: Set<String> = []) -> OldVersionScanner {
        OldVersionScanner(home: home, appFolders: [system, userApps], running: { (running, ids) })
    }

    private func mover() -> OldVersionCleaner.Mover {
        let trash = self.trash!
        return { url in
            let target = URL(fileURLWithPath: trash).appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    private struct NoCommands: CommandRunning {
        func run(_ executable: String, _ arguments: [String]) throws -> CommandResult { CommandResult(stdout: Data(), stderr: Data(), exitCode: 0) }
    }

    @discardableResult
    private func app(_ folder: String, _ name: String, id: String, version: String) throws -> String {
        let path = (folder as NSString).appendingPathComponent("\(name).app")
        let contents = (path as NSString).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleShortVersionString": version],
                                                       format: .xml, options: 0)
        try plist.write(to: URL(fileURLWithPath: contents).appendingPathComponent("Info.plist"))
        return path
    }

    @discardableResult
    private func make(_ relative: String, file: Bool = false) throws -> String {
        let path = (library as NSString).appendingPathComponent(relative)
        if file {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 5_000).write(to: URL(fileURLWithPath: path))
        } else {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 5_000).write(to: URL(fileURLWithPath: path).appendingPathComponent("data"))
        }
        return path
    }

    private func report(_ id: String, _ scanner: OldVersionScanner) -> AppReport? {
        scanner.scan().first { $0.bundleID == id }
    }

    // MARK: Copies

    func testTheNewestCopyStaysAndTheOlderIsOffered() throws {
        let new = try app(system, "Wallflower", id: "com.swollzy.wallflower", version: "0.2.3")
        let old = try app(userApps, "Wallflower", id: "com.swollzy.wallflower", version: "0.1.1")
        let report = try XCTUnwrap(report("com.swollzy.wallflower", scanner()))
        XCTAssertEqual(report.current?.path, new)
        XCTAssertEqual(report.findings.filter { $0.kind == .oldCopy }.map(\.path), [old])
        XCTAssertTrue(report.findings.first { $0.path == old }?.checked == true)
    }

    func testVersionsCompareAsNumbers() {
        XCTAssertEqual(OldVersionScanner.compareVersions("0.10.0", "0.9.2"), .orderedDescending)
        XCTAssertEqual(OldVersionScanner.compareVersions("", "0.1"), .orderedAscending)
        XCTAssertEqual(OldVersionScanner.compareVersions("1.0", "1.0"), .orderedSame)
    }

    func testTheOpenCopyStaysEvenWhenOlder() throws {
        let new = try app(system, "Swivel", id: "com.swollzy.swivel", version: "0.3.0")
        let old = try app(userApps, "Swivel", id: "com.swollzy.swivel", version: "0.2.0")
        let report = try XCTUnwrap(report("com.swollzy.swivel", scanner(running: [old], ids: ["com.swollzy.swivel"])))
        XCTAssertEqual(report.current?.path, old)
        XCTAssertEqual(report.findings.filter { $0.kind == .oldCopy }.map(\.path), [new], "the newer copy is offered, the open one never")
        XCTAssertEqual(report.findings.first { $0.path == new }?.checked, false, "but not checked: it is most likely the one to keep")
    }

    func testAnAppOpenFromElsewhereLeavesItsCopiesUnchecked() throws {
        try app(system, "Swivel", id: "com.swollzy.swivel", version: "0.3.0")
        let old = try app(userApps, "Swivel", id: "com.swollzy.swivel", version: "0.2.0")
        let scanner = scanner(running: ["/Volumes/Swivel/Swivel.app"], ids: ["com.swollzy.swivel"])
        let finding = try XCTUnwrap(report("com.swollzy.swivel", scanner)?.findings.first { $0.path == old })
        XCTAssertFalse(finding.checked)
        let outcome = OldVersionCleaner(scanner: scanner, move: mover(), runner: NoCommands()).trash([old], of: "com.swollzy.swivel")
        XCTAssertTrue(outcome.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old))
    }

    func testOneCopyIsNeverOffered() throws {
        try app(system, "Burrow", id: "com.swollzy.burrow", version: "0.3.3")
        let report = try XCTUnwrap(report("com.swollzy.burrow", scanner()))
        XCTAssertTrue(report.findings.filter { $0.kind == .oldCopy }.isEmpty)
    }

    /// Burrow's simple AppleScript menu app carries Script Editor's identifier: an old copy next to the real app, the only copy alone.
    func testTheAppleScriptStandInIsAnOldCopyOnlyNextToTheRealApp() throws {
        let script = try app(userApps, "Burrow", id: "com.apple.ScriptEditor.id.Burrow", version: "1.0")
        XCTAssertTrue(report("com.swollzy.burrow", scanner())?.findings.filter { $0.kind == .oldCopy }.isEmpty ?? true)
        let real = try app(system, "Burrow", id: "com.swollzy.burrow", version: "0.3.3")
        let report = try XCTUnwrap(report("com.swollzy.burrow", scanner()))
        XCTAssertEqual(report.current?.path, real)
        XCTAssertEqual(report.findings.filter { $0.kind == .oldCopy }.map(\.path), [script])
        XCTAssertEqual(report.findings.first { $0.path == script }?.checked, false, "it may be the user's own applet")
        // Only Burrow ever shipped as an AppleScript app: an applet named Swivel is the user's.
        try app(system, "Swivel", id: "com.swollzy.swivel", version: "0.3.0")
        try app(userApps, "Swivel", id: "com.apple.ScriptEditor.id.Swivel", version: "1.0")
        XCTAssertTrue(self.report("com.swollzy.swivel", scanner())?.findings.isEmpty ?? false)
    }

    /// Another maker's app with the same name keeps folders under that name: without a sign of Swollzy's app, they are left alone.
    func testNameFoldersNeedTheAppToBeHere() throws {
        try make("Logs/Swivel")
        try make("Caches/Burrow")
        try make("Application Support/Burrow/logs")
        try make("Logs/DiagnosticReports/Wallflower-2026-10-30-101010.ips", file: true)
        XCTAssertTrue(scanner().scan().allSatisfy { $0.findings.isEmpty }, "\(scanner().scan().flatMap(\.findings).map(\.path))")
        try make("Preferences/com.swollzy.swivel.plist", file: true)
        XCTAssertEqual(report("com.swollzy.swivel", scanner())?.findings.map(\.path), [(library as NSString).appendingPathComponent("Logs/Swivel")])
    }

    func testWebStorageIsNeverChecked() throws {
        try app(system, "Wallflower", id: "com.swollzy.wallflower", version: "0.2.3")
        let web = try make("HTTPStorages/com.swollzy.wallflower")
        XCTAssertEqual(report("com.swollzy.wallflower", scanner())?.findings.first { $0.path == web }?.checked, false)
    }

    /// A game shortcut in ~/Applications/Burrow, or another vendor's app named like one of these, is never taken for a copy.
    func testOtherAppsAreNeverCopies() throws {
        try app(system, "Burrow", id: "com.swollzy.burrow", version: "0.3.3")
        try FileManager.default.createDirectory(atPath: (userApps as NSString).appendingPathComponent("Burrow"), withIntermediateDirectories: true)
        try app((userApps as NSString).appendingPathComponent("Burrow"), "Burrow", id: "com.apple.ScriptEditor.id.Burrow", version: "1")
        try app(userApps, "Swivel", id: "com.other.swivel", version: "9")
        XCTAssertTrue(report("com.swollzy.burrow", scanner())?.findings.filter { $0.kind == .oldCopy }.isEmpty ?? false)
        XCTAssertNil(report("com.swollzy.swivel", scanner()))
    }

    func testALinkedCopyIsNotFollowed() throws {
        try app(system, "Wallflower", id: "com.swollzy.wallflower", version: "0.2.3")
        let elsewhere = try app(home, "Wallflower", id: "com.swollzy.wallflower", version: "0.1.0")
        try FileManager.default.createSymbolicLink(atPath: (userApps as NSString).appendingPathComponent("Wallflower.app"), withDestinationPath: elsewhere)
        XCTAssertTrue(report("com.swollzy.wallflower", scanner())?.findings.filter { $0.kind == .oldCopy }.isEmpty ?? false)
    }

    // MARK: Library

    func testCachesLogsAndReportsAreOfferedAndSettingsKept() throws {
        try app(system, "Wallflower", id: "com.swollzy.wallflower", version: "0.2.3")
        let cache = try make("Caches/com.swollzy.wallflower")
        let state = try make("Saved Application State/com.swollzy.wallflower.savedState")
        let crash = try make("Logs/DiagnosticReports/Wallflower-2026-10-30-101010.ips", file: true)
        try make("Logs/DiagnosticReports/WallflowerPro-2026-10-30-101010.ips", file: true)
        let prefs = try make("Preferences/com.swollzy.wallflower.plist", file: true)
        let library = try make("Application Support/Wallflower")
        let report = try XCTUnwrap(report("com.swollzy.wallflower", scanner()))
        XCTAssertEqual(Set(report.findings.map(\.path)), [cache, state, crash])
        XCTAssertEqual(Set(report.kept.keys), [prefs, library])
        XCTAssertTrue(report.findings.allSatisfy(\.checked))
    }

    func testAnOpenAppsCachesAreUncheckedAndRefused() throws {
        try app(system, "Wallflower", id: "com.swollzy.wallflower", version: "0.2.3")
        let cache = try make("Caches/com.swollzy.wallflower")
        let scanner = scanner(running: [(system as NSString).appendingPathComponent("Wallflower.app")], ids: ["com.swollzy.wallflower"])
        XCTAssertEqual(report("com.swollzy.wallflower", scanner)?.findings.first?.checked, false)
        let outcome = OldVersionCleaner(scanner: scanner, move: mover(), runner: NoCommands()).trash([cache], of: "com.swollzy.wallflower")
        XCTAssertNotNil(outcome.refused[cache])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
    }

    /// Burrow's logs and old build folder go; its bottles and the rest of its folder stay.
    func testBurrowsDataStaysAndItsListedPathsGo() throws {
        try app(system, "Burrow", id: "com.swollzy.burrow", version: "0.3.3")
        let logs = try make("Application Support/Burrow/logs")
        let turbo = try make("Application Support/Burrow/cache/turbo")
        let downloads = try make("Application Support/Burrow/cache/downloads")
        let bottles = try make("Application Support/Burrow/bottles")
        try make("Application Support/Burrow/cache/wine.tar.xz", file: true)
        let report = try XCTUnwrap(report("com.swollzy.burrow", scanner()))
        XCTAssertEqual(Set(report.findings.map(\.path)), [logs, turbo, downloads])
        XCTAssertEqual(report.findings.first { $0.path == downloads }?.checked, false, "downloads are slow to get back")
        XCTAssertNotNil(report.kept[bottles])
        XCTAssertFalse(report.findings.contains { $0.path.hasSuffix("/Burrow") || $0.path.hasSuffix("/cache") })
    }

    func testAKeptPathIsNeverOfferedEvenIfListed() {
        let library = "/u/Library"
        let kept = ["/u/Library/Application Support/Burrow/bottles"]
        XCTAssertTrue(OldVersionScanner.touchesKept("/u/Library/Application Support/Burrow", kept: kept), "holds a kept path")
        XCTAssertTrue(OldVersionScanner.touchesKept("/u/Library/Application Support/Burrow/bottles/x", kept: kept), "inside one")
        XCTAssertTrue(OldVersionScanner.touchesKept("/u/Library/application support/burrow/BOTTLES", kept: kept), "case-insensitive")
        XCTAssertFalse(OldVersionScanner.touchesKept("/u/Library/Application Support/Burrow/bottlesOld", kept: kept), "a prefix is not a folder")
        XCTAssertFalse(OldVersionScanner.isInside("\(library)/CachesX", "\(library)/Caches"))
    }

    func testALinkedCacheIsNotOffered() throws {
        try app(system, "Swivel", id: "com.swollzy.swivel", version: "0.3.0")
        let documents = (home as NSString).appendingPathComponent("Documents")
        try FileManager.default.createDirectory(atPath: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (library as NSString).appendingPathComponent("Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: (library as NSString).appendingPathComponent("Caches/com.swollzy.swivel"), withDestinationPath: documents)
        XCTAssertTrue(report("com.swollzy.swivel", scanner())?.findings.isEmpty ?? false)
    }

    func testAnAgentWhoseProgramIsGoneIsOfferedAndOneThatWorksIsNot() throws {
        try app(system, "Wallflower", id: "com.swollzy.wallflower", version: "0.2.3")
        let gone = try agent("com.swollzy.wallflower.helper", program: "/nowhere/wallflower-helper")
        try agent("com.swollzy.wallflower.ok", program: "/bin/ls")
        try agent("com.other.thing", program: "/nowhere/else")
        let report = try XCTUnwrap(report("com.swollzy.wallflower", scanner()))
        XCTAssertEqual(report.findings.filter { $0.kind == .launchAgent }.map(\.path), [gone])
    }

    @discardableResult
    private func agent(_ label: String, program: String) throws -> String {
        let path = (library as NSString).appendingPathComponent("LaunchAgents/\(label).plist")
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": program], format: .xml, options: 0)
        try plist.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Any app under com.swollzy. is looked after, listed or not, with its Application Support folder kept.
    func testAnUnlistedFamilyAppGetsTheSharedRules() throws {
        try app(system, "Headroom", id: "com.swollzy.headroom", version: "0.1.2")
        let cache = try make("Caches/com.swollzy.headroom")
        let data = try make("Application Support/Headroom")
        let report = try XCTUnwrap(report("com.swollzy.headroom", scanner()))
        XCTAssertEqual(report.findings.map(\.path), [cache])
        XCTAssertNotNil(report.kept[data])
    }

    // MARK: Cleaner

    func testTheCleanerMovesOnlyWhatTheScanStillOffers() throws {
        try app(system, "Wallflower", id: "com.swollzy.wallflower", version: "0.2.3")
        let old = try app(userApps, "Wallflower", id: "com.swollzy.wallflower", version: "0.1.1")
        let cache = try make("Caches/com.swollzy.wallflower")
        let prefs = try make("Preferences/com.swollzy.wallflower.plist", file: true)
        let cleaner = OldVersionCleaner(scanner: scanner(), move: mover(), runner: NoCommands())
        let outcome = cleaner.trash([old, cache, prefs, "/etc/hosts"], of: "com.swollzy.wallflower")
        XCTAssertEqual(Set(outcome.trashed.keys), [old, cache])
        XCTAssertEqual(Set(outcome.refused.keys), [prefs, "/etc/hosts"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefs))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old))
    }

    func testTheKeptCopyIsRefused() throws {
        let new = try app(system, "Wallflower", id: "com.swollzy.wallflower", version: "0.2.3")
        try app(userApps, "Wallflower", id: "com.swollzy.wallflower", version: "0.1.1")
        let outcome = OldVersionCleaner(scanner: scanner(), move: mover(), runner: NoCommands()).trash([new], of: "com.swollzy.wallflower")
        XCTAssertNotNil(outcome.refused[new])
        XCTAssertTrue(FileManager.default.fileExists(atPath: new))
    }

    // MARK: Page

    func testThePageChecksWhatIsSafeAndListsWhatIsKept() throws {
        try app(system, "Burrow", id: "com.swollzy.burrow", version: "0.3.3")
        let logs = try make("Application Support/Burrow/logs")
        let downloads = try make("Application Support/Burrow/cache/downloads")
        try make("Application Support/Burrow/bottles")
        let snapshot = OldVersionsSnapshot(apps: scanner().scan())
        let screen = OldVersionsScreenBuilder.screen(snapshot)
        guard case let .section(section)? = screen.widgets.first, case let .list(list)? = section.widgets.first else { return XCTFail("no section") }
        let selection = try XCTUnwrap(list.rows.first?.selection)
        XCTAssertEqual(selection.checked, ["item:\(logs)"])
        XCTAssertNotNil(selection.choices["item:\(downloads)"])
        XCTAssertNil(list.rows.last?.selection, "what is kept has no checkbox")
        XCTAssertEqual(OldVersionsScreenBuilder.tile(snapshot).needsAttention, true)
    }
}
