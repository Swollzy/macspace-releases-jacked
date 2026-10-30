import XCTest
import MacSpaceSdk
@testable import MacSpacePlatform

final class DryRunReportTests: XCTestCase {
    /// Low: under 15 GB or 10% of the disk, whichever is larger, never a threshold under 5 GB.
    func testLowDiskPolicy() {
        XCTAssertEqual(LowDiskPolicy.threshold(capacity: 100_000_000_000), 15_000_000_000)
        XCTAssertEqual(LowDiskPolicy.threshold(capacity: 1_000_000_000_000), 100_000_000_000)
        XCTAssertGreaterThanOrEqual(LowDiskPolicy.threshold(capacity: 0), LowDiskPolicy.floor)
        XCTAssertTrue(LowDiskPolicy.isLow(available: 14_999_999_999, capacity: 100_000_000_000))
        XCTAssertFalse(LowDiskPolicy.isLow(available: 15_000_000_000, capacity: 100_000_000_000))
    }

    /// The report takes every offered row, checked or not, with what its action does to it, and writes JSON and Markdown locally.
    func testItemsAndFiles() throws {
        let trash = Action(id: "trashLarge", title: "Move to Trash", parameters: [DryRunReport.dispositionKey: DryRunReport.Disposition.trash.rawValue])
        var group = Row.group(id: "large-files", title: "Large files", totalBytes: 300,
                              rows: [Row(id: "a", title: "a.mov", paths: ["/Users/x/Movies/a.mov"]), Row(id: "b", title: "b.mov", paths: ["/Users/x/Movies/b.mov"]),
                                     Row(id: "kept", title: "kept.mov")])
        group.selection = Selection(action: trash, choices: ["a": 100, "b": 200], checked: [])
        let screen = Screen(title: "Large Files", widgets: [.section(SectionWidget(id: "s", title: "Over 100 MB", widgets: [.list(ListWidget(id: "l", rows: [group]))]))])

        let items = DryRunReport.items(in: screen, checked: { _ in ["b"] })
        XCTAssertEqual(items.map(\.title), ["a.mov", "b.mov"], "a row with no checkbox is never offered")
        XCTAssertEqual(items.filter(\.checked).map(\.title), ["b.mov"])
        XCTAssertTrue(items.allSatisfy { $0.disposition == .trash })

        let report = DryRunReport(created: Date(timeIntervalSince1970: 0), macSpaceVersion: "1.2.0", freeBytes: 10_000_000_000, capacityBytes: 100_000_000_000,
                                  modules: [DryRunReport.Module(id: "lf", name: "Large Files", reclaimableBytes: nil, autoClean: false, items: items),
                                            DryRunReport.Module(id: "osf", name: "Other System Files", reclaimableBytes: 5_000, autoClean: true, items: [])])
        XCTAssertTrue(report.lowDisk)
        XCTAssertEqual(report.wouldTrashBytes, 200)
        XCTAssertEqual(report.wouldFreeBytes, 5_000)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try report.write(to: folder)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(DryRunReport.self, from: Data(contentsOf: files.json)), report)
        let markdown = try String(contentsOf: files.markdown, encoding: .utf8)
        XCTAssertTrue(markdown.contains("/Users/x/Movies/b.mov"))
        XCTAssertFalse(markdown.contains("/Users/x/Movies/a.mov"), "unchecked rows are counted, not listed")
        XCTAssertTrue(markdown.contains("Nothing was deleted"))
    }
    /// A group drawn twice on one page (System Data's caches, under Free now and in the bar's "Can be freed" block) is reported once,
    /// and a row already emptied (0 bytes until the next scan) is not reported at all.
    func testGroupDrawnTwiceAndEmptyRows() {
        let free = Action(id: "freeCaches", title: "Free selected")
        var group = Row.group(id: "caches", title: "Caches you can free", totalBytes: 300,
                              rows: [Row(id: "dev:gradle", title: "Gradle", paths: ["/Users/x/.gradle/caches"]),
                                     Row(id: "dev:pub", title: "Dart packages", paths: ["/Users/x/.pub-cache/hosted"])])
        group.selection = Selection(action: free, choices: ["dev:gradle": 300, "dev:pub": 0], checked: ["dev:gradle", "dev:pub"])
        let hero = UsageBar(id: "usage", title: "What fills System Data", segments: [UsageSegment(id: "freeable", label: "Can be freed", bytes: 300, tone: .caution)])
        var screen = Screen(title: "System Data", hero: hero, widgets: [.section(SectionWidget(id: "free", title: "Free now", widgets: [.list(ListWidget(id: "l", rows: [group]))]))])
        screen.hero?.segments[0].items = [group]

        let items = DryRunReport.items(in: screen)
        XCTAssertEqual(items.map(\.title), ["Gradle"])
        XCTAssertEqual(items.first?.bytes, 300)
        XCTAssertEqual(items.first?.checked, true)
    }

    /// A row that would go to the Trash is reported even when its size reads as 0 (a folder privacy settings keep MacSpace from
    /// sizing): it still moves if checked.
    func testZeroByteTrashRowsAreReported() {
        let trash = Action(id: "trash", title: "Move to Trash", parameters: [DryRunReport.dispositionKey: DryRunReport.Disposition.trash.rawValue])
        var group = Row.group(id: "left", title: "Leftovers", totalBytes: 0, rows: [Row(id: "x", title: "Container", paths: ["/Users/x/Library/Containers/x"])])
        group.selection = Selection(action: trash, choices: ["x": 0], checked: ["x"])
        let screen = Screen(title: "Apps", widgets: [.list(ListWidget(id: "l", rows: [group]))])
        XCTAssertEqual(DryRunReport.items(in: screen).map(\.title), ["Container"])
    }
}

/// MacSpace's folders move to Molt's once, never over Molt's own, never through a link.
final class EarlierDataFoldersTests: XCTestCase {
    func testFoldersMoveOnceAndNeverOverMolts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("molt-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appendingPathComponent("Library/Application Support/MacSpace")
        let earlierApp = home.appendingPathComponent("Applications/MacSpace.app")
        try FileManager.default.createDirectory(at: earlierApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        XCTAssertTrue(EarlierDataFolders.moveUserFolders(home: home, applications: home.appendingPathComponent("Applications").path).isEmpty, "not while MacSpace, which needs them to uninstall, is there")
        try FileManager.default.removeItem(at: earlierApp)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: old.appendingPathComponent("debloat-watch.json"))
        XCTAssertEqual(EarlierDataFolders.moveUserFolders(home: home, applications: home.appendingPathComponent("Applications").path).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Molt/debloat-watch.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))

        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        XCTAssertTrue(EarlierDataFolders.moveUserFolders(home: home, applications: home.appendingPathComponent("Applications").path).isEmpty, "Molt's own folder is never replaced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }
}
