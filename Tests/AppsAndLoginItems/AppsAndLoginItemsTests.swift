import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceAppsAndLoginItems

/// Apps & Login Items on a fake home folder: strict leftover matching, apps that are gone, launch agents switched off and back on,
/// all without touching the Mac's own Library or launchd.
final class AppsAndLoginItemsTests: XCTestCase {
    private var home: String!
    private var library: String { (home as NSString).appendingPathComponent("Library") }

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-apps-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        home = (base as NSString).resolvingSymlinksInPath
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    @discardableResult
    private func make(_ relative: String, file: Bool = false) throws -> String {
        let path = (library as NSString).appendingPathComponent(relative)
        if file {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 10_000).write(to: URL(fileURLWithPath: path))
        } else {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 10_000).write(to: URL(fileURLWithPath: path).appendingPathComponent("data"))
        }
        return path
    }

    private func container(_ folder: String, owner: String) throws {
        let path = try make("Containers/\(folder)")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": owner], format: .xml, options: 0)
        try plist.write(to: URL(fileURLWithPath: path).appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
    }

    func testLeftoversAreMatchedStrictly() throws {
        let id = "com.example.Widget"
        let support = try make("Application Support/\(id)")
        let byName = try make("Application Support/Widget")
        let caches = try make("Caches/\(id)")
        let prefs = try make("Preferences/\(id).plist", file: true)
        let byHost = try make("Preferences/ByHost/\(id).0A1B2C3D-0000-1111-2222-333344445555.plist", file: true)
        let state = try make("Saved Application State/\(id).savedState")
        let webkit = try make("WebKit/\(id)")
        let group = try make("Group Containers/ABCDE12345.\(id)")
        try container(id, owner: id)
        // Never: another app's container under this name, a vendor's shared group, a prefix match, the user's documents.
        try container("com.example.WidgetPro", owner: "com.example.WidgetPro")
        try make("Group Containers/group.com.example.shared")
        try make("Application Support/\(id).Helper")
        try make("Preferences/\(id)Pro.plist", file: true)
        try FileManager.default.createDirectory(atPath: (home as NSString).appendingPathComponent("Documents/Widget"), withIntermediateDirectories: true)

        let finder = LeftoverFinder(home: home, systemAppNames: [])
        let found = Set(finder.leftovers(bundleID: id, name: "Widget", installed: []).map(\.path))
        let containerPath = (library as NSString).appendingPathComponent("Containers/\(id)")
        XCTAssertEqual(found, [support, byName, caches, prefs, byHost, state, webkit, group, containerPath])
    }

    /// A name another installed app (or macOS) also has is never matched by name; a container recorded for another app never.
    func testNamesSharedWithOtherAppsAreNotMatched() throws {
        let id = "com.example.Notes"
        try make("Application Support/Notes")
        try container(id, owner: "com.other.app")
        let installed = [InstalledApp(path: "/Applications/Other.app", bundleID: "com.other.Notes", name: "Notes", bytes: 0)]
        let viaInstalled = LeftoverFinder(home: home, systemAppNames: []).leftovers(bundleID: id, name: "Notes", installed: installed)
        XCTAssertTrue(viaInstalled.isEmpty)
        let viaSystem = LeftoverFinder(home: home, systemAppNames: ["Notes"]).leftovers(bundleID: id, name: "Notes", installed: [])
        XCTAssertTrue(viaSystem.isEmpty)
        XCTAssertTrue(LeftoverFinder(home: home, systemAppNames: []).leftovers(bundleID: "com.apple.Notes", name: "Notes", installed: []).isEmpty)
    }

    /// A sibling app of the same maker, or one whose name starts with this one's, may read the folder named after it (Firefox
    /// Developer Edition reads Firefox's profiles): no match by name then, by identifier still.
    func testNameMatchesStopWhenASiblingAppIsInstalled() throws {
        let id = "org.mozilla.firefox"
        try make("Application Support/Firefox")
        let caches = try make("Caches/\(id)")
        let finder = LeftoverFinder(home: home, systemAppNames: [])
        let sibling = [InstalledApp(path: "/Applications/Firefox Developer Edition.app", bundleID: "org.mozilla.firefoxdeveloperedition",
                                    name: "Firefox Developer Edition", bytes: 0)]
        XCTAssertEqual(finder.leftovers(bundleID: id, name: "Firefox", installed: sibling).map(\.path), [caches])
        let unrelated = [InstalledApp(path: "/Applications/Fire Tool.app", bundleID: "com.other.FireToolbox", name: "FireToolbox", bytes: 0)]
        XCTAssertEqual(finder.leftovers(bundleID: id, name: "Firefox", installed: unrelated).count, 2)
    }

    /// Two steps: the app goes first, alone; its leftovers are offered after, none checked, and go only when checked.
    func testUninstallIsTwoSteps() async throws {
        let id = "com.example.Widget"
        let support = try make("Application Support/\(id)")
        let caches = try make("Caches/\(id)")
        let appPath = (home as NSString).appendingPathComponent("Applications/Widget.app")
        try FileManager.default.createDirectory(atPath: appPath + "/Contents", withIntermediateDirectories: true)
        let app = InstalledApp(path: appPath, bundleID: id, name: "Widget", bytes: 1)
        let trash = (home as NSString).appendingPathComponent("Trash")
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let move: AppUninstaller.Mover = { url in
            let destination = URL(fileURLWithPath: trash).appendingPathComponent(UUID().uuidString + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        let apps = InstalledList([app])
        let uninstaller = AppUninstaller(journalURL: URL(fileURLWithPath: home).appendingPathComponent("removed.json"),
                                         finder: LeftoverFinder(home: home, systemAppNames: []), installed: { apps.value },
                                         recycle: { url in apps.value = []; return try move(url) }, move: move, isRunning: { _ in false },
                                         existsElsewhere: { _ in false })

        _ = try await uninstaller.trashApp(app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support), "leftovers stay until the user checks them")
        let pending = uninstaller.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(Set(pending[0].leftovers.map(\.path)), [support, caches])

        let row = AppsScreenBuilder.leftoverRow(AppsSnapshot.Pending(app: pending[0].app, leftovers: pending[0].leftovers))
        XCTAssertEqual(row.selection?.checked, [])

        let outcome = try uninstaller.trashLeftovers([caches, "/Users/someone/Documents/important"], of: id)
        XCTAssertEqual(Array(outcome.trashed.keys), [caches])
        XCTAssertNotNil(outcome.refused["/Users/someone/Documents/important"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: caches))
    }

    /// What apps no longer on the Mac left: offered only when no installed app, no bundle in one, no app Launch Services knows and
    /// no app of the same maker claims it.
    func testOrphansNeedTheWholeMakerGone() throws {
        let gone = try make("Application Support/com.gone.Tool")
        let goneUpdater = try make("Caches/com.gone.Updater")
        try make("Application Support/com.kept.Updater")       // com.kept still has an app installed
        try make("Caches/com.elsewhere.App")                   // Launch Services finds it outside /Applications
        try make("Caches/com.apple.Safari")                    // macOS's
        try make("Application Support/Some Folder")            // not an identifier
        let installed = [InstalledApp(path: "/Applications/Kept.app", bundleID: "com.kept.Main", name: "Kept", bytes: 0)]
        let finder = OrphanFinder(home: home, appExists: { $0 == "com.elsewhere.App" })
        let orphans = finder.orphans(installed: installed, installedIDs: ["com.kept.main"])
        XCTAssertEqual(Set(orphans.map(\.leftover.path)), [gone, goneUpdater])
        XCTAssertEqual(Set(orphans.map(\.owner)), ["com.gone.Tool", "com.gone.Updater"])
        let snapshot = AppsSnapshot(apps: installed, pending: [], orphans: orphans, agents: [], journaled: [])
        for group in snapshot.orphanGroups {
            XCTAssertEqual(AppsScreenBuilder.orphanRow(owner: group.owner, items: group.items).selection?.checked, [])
        }
    }

    func testOwnerNames() {
        XCTAssertEqual(OrphanFinder.owner(of: "com.vendor.App.plist", in: .preferences), "com.vendor.App")
        XCTAssertEqual(OrphanFinder.owner(of: "ABCDE12345.com.vendor.App", in: .groupContainers), "com.vendor.App")
        XCTAssertEqual(OrphanFinder.owner(of: "group.com.vendor.shared", in: .groupContainers), "com.vendor.shared")
        XCTAssertNil(OrphanFinder.owner(of: "com.apple.Safari", in: .caches))
        XCTAssertNil(OrphanFinder.owner(of: "Google", in: .applicationSupport))
        XCTAssertNil(OrphanFinder.owner(of: "com.vendor", in: .caches))
        // macOS's own data under other prefixes is never an orphan.
        XCTAssertNil(OrphanFinder.owner(of: "243LU875E5.groups.com.apple.podcasts", in: .groupContainers))
        XCTAssertNil(OrphanFinder.owner(of: "group.is.workflow.my.app", in: .groupContainers))
        XCTAssertNil(OrphanFinder.owner(of: "org.cups.PrintingPrefs.plist", in: .preferences))
        XCTAssertEqual(OrphanFinder.owner(of: "ABCDE12345.group.com.vendor.App", in: .groupContainers), "com.vendor.App")
    }

    func testLaunchAgentsAreReadAndSwitchedReversibly() throws {
        let folder = (library as NSString).appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": "com.vendor.agent", "ProgramArguments": ["/opt/vendor/agent", "--daemon"], "RunAtLoad": true]
        let path = (folder as NSString).appendingPathComponent("com.vendor.agent.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
        let apple: [String: Any] = ["Label": "com.apple.thing", "Program": "/usr/libexec/thing"]
        try PropertyListSerialization.data(fromPropertyList: apple, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("com.apple.thing.plist")))

        let agents = LaunchAgentInventory.agents(in: [(folder, .user)])
        XCTAssertEqual(agents.map(\.label), ["com.vendor.agent"], "macOS's own agents are not listed")
        let agent = agents[0]
        XCTAssertEqual(agent.program, "/opt/vendor/agent")
        XCTAssertTrue(agent.runAtLoad)
        XCTAssertTrue(agent.programMissing)

        let runner = RecordingRunner()
        let journal = DisabledAgentsJournal(url: URL(fileURLWithPath: home).appendingPathComponent("disabled.json"))
        let switcher = LaunchAgentSwitch(runner: runner, journal: journal, uid: 501)
        try switcher.disable(agent)
        XCTAssertEqual(runner.calls.first, ["disable", "gui/501/com.vendor.agent"])
        XCTAssertEqual(journal.entries().map(\.label), ["com.vendor.agent"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the property list stays")

        XCTAssertTrue(switcher.restoreAll().isEmpty)
        XCTAssertTrue(runner.calls.contains(["enable", "gui/501/com.vendor.agent"]))
        XCTAssertTrue(journal.entries().isEmpty)
    }

    func testPrintDisabledIsParsed() {
        let output = """
        disabled services = {
            "com.vendor.agent" => disabled
            "com.vendor.other" => enabled
            "com.old.style" => true
        }
        """
        XCTAssertEqual(LaunchAgentInventory.parseDisabled(output), ["com.vendor.agent", "com.old.style"])
    }

    func testNeverAutoCleans() async throws {
        let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/AppsAndLoginItems/Bundle/Manifest.json")
        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertNotEqual(manifest.autoClean, true)
        XCTAssertEqual(manifest.order, 50)
        XCTAssertEqual(manifest.sdkVersion, 7)
    }
}

final class InstalledList: @unchecked Sendable {
    private let lock = NSLock()
    private var apps: [InstalledApp]
    init(_ apps: [InstalledApp]) { self.apps = apps }
    var value: [InstalledApp] {
        get { lock.withLock { apps } }
        set { lock.withLock { apps = newValue } }
    }
}

final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        lock.withLock { recorded.append(arguments) }
        return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}
