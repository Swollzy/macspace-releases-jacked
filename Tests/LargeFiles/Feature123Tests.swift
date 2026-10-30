import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceLargeFiles

/// Large Files on a temporary folder with known duplicates: scan, dry-run report, move one checked copy to a stand-in Trash, scan
/// again, and check one copy stays and the other is in the Trash. Nothing outside the temporary folder is touched.
final class Feature123Tests: XCTestCase {
    private var root: URL!
    private var trash: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-feature123-\(UUID().uuidString)")
        // One spelling of the path throughout, so the scan's paths and the test's compare equal.
        let resolved = URL(fileURLWithPath: (base.path as NSString).resolvingSymlinksInPath)
        root = resolved.appendingPathComponent("Documents")
        trash = resolved.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ name: String, _ data: Data, modified: Date? = nil) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified { try FileManager.default.setAttributes([.creationDate: modified, .modificationDate: modified], ofItemAtPath: url.path) }
        return url.path
    }

    private func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private var scanRoots: ScanRoots { ScanRoots(home: root.deletingLastPathComponent().path, roots: [root.path]) }

    private func scanner() -> LargeFileScanner {
        LargeFileScanner(roots: scanRoots, largeThreshold: 3_000_000, duplicateMinimum: 1_000)
    }

    /// A stand-in for the Trash: moves into the test's own folder and says where.
    private func trasher() -> FileTrasher {
        let trash = self.trash!
        return FileTrasher(roots: scanRoots, move: { url in
            let destination = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
    }

    func testScanReportTrashOneCopyAndScanAgain() throws {
        let content = random(2_000_000)
        let original = try write("original.bin", content, modified: Date(timeIntervalSince1970: 1_000_000))
        let copy = try write("Sub/copy.bin", content, modified: Date(timeIntervalSince1970: 2_000_000))
        // Same length, different bytes: never a duplicate.
        _ = try write("other.bin", random(2_000_000))
        // Same length, same first and last 64 KB, a different middle: the partial hash matches, the full one does not.
        var lookalike = content
        lookalike[1_000_000] ^= 0xFF
        _ = try write("lookalike.bin", lookalike)
        let large = try write("large.mov", random(3_500_000))

        // Scan.
        let first = scanner().scan()
        XCTAssertEqual(first.duplicates.count, 1, "only the two identical files are duplicates")
        let group = try XCTUnwrap(first.duplicates.first)
        XCTAssertEqual(group.keeper.path, original, "the oldest copy is kept")
        XCTAssertEqual(group.copies.map(\.path), [copy])
        XCTAssertEqual(group.hash, LargeFileScanner.fullHash(original))
        XCTAssertEqual(first.largeFiles.map(\.path), [large])

        // The page: nothing checked, and the kept copy has no checkbox.
        let screen = LargeFilesScreenBuilder.screen(first)
        let row = LargeFilesScreenBuilder.duplicateRow(group)
        XCTAssertEqual(row.selection?.checked, [])
        XCTAssertNil(row.selection?.choices["keep:\(original)"])
        XCTAssertNil(row.selection?.choices[LargeFilesScreenBuilder.copyID(original)])
        XCTAssertNotNil(row.selection?.choices[LargeFilesScreenBuilder.copyID(copy)])
        XCTAssertNil(screen.primary, "no main button: nothing goes without being checked")

        // Dry-run report: lists what would go, deletes nothing.
        let items = DryRunReport.items(in: screen, checked: { $0.id == row.id ? [LargeFilesScreenBuilder.copyID(copy)] : [] })
        let report = DryRunReport(macSpaceVersion: "test", freeBytes: nil, capacityBytes: nil,
                                  modules: [DryRunReport.Module(id: LargeFilesScreenBuilder.moduleID, name: "Large Files", reclaimableBytes: nil, autoClean: false, items: items)])
        let folder = root.deletingLastPathComponent().appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try report.write(to: folder)
        XCTAssertTrue(try String(contentsOf: files.markdown, encoding: .utf8).contains(copy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy), "making the report deleted nothing")
        XCTAssertEqual(report.wouldTrashBytes, group.copies[0].allocatedBytes)

        // Move the one checked copy to the Trash.
        let outcome = trasher().trashDuplicates([copy], group: group)
        XCTAssertEqual(Array(outcome.trashed.keys), [copy])
        XCTAssertTrue(outcome.refused.isEmpty)
        let inTrash = try XCTUnwrap(outcome.trashed[copy])
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTrash))
        XCTAssertEqual(LargeFileScanner.fullHash(inTrash), group.hash)

        // Scan again: one copy remains, and it is no longer a duplicate.
        let second = scanner().scan()
        XCTAssertTrue(second.duplicates.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
    }

    /// N - 1 at most: the kept copy is refused even when asked for, and the large-files list will not take it either.
    func testTheKeptCopyNeverGoes() throws {
        let content = random(4_000_000)
        let a = try write("a.bin", content, modified: Date(timeIntervalSince1970: 1_000_000))
        let b = try write("b.bin", content, modified: Date(timeIntervalSince1970: 2_000_000))
        let c = try write("c.bin", content, modified: Date(timeIntervalSince1970: 3_000_000))
        let snapshot = scanner().scan()
        let group = try XCTUnwrap(snapshot.duplicates.first)
        XCTAssertEqual(group.keeper.path, a)

        let outcome = trasher().trashDuplicates([a, b, c], group: group)
        XCTAssertEqual(Set(outcome.trashed.keys), [b, c])
        XCTAssertNotNil(outcome.refused[a])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))

        let large = trasher().trashLarge([a], snapshot: snapshot)
        XCTAssertTrue(large.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
    }

    /// If the kept copy changed since the scan, no copy of the group is moved.
    func testNothingMovesWhenTheKeptCopyChanged() throws {
        let content = random(1_500_000)
        let a = try write("a.bin", content, modified: Date(timeIntervalSince1970: 1_000_000))
        let b = try write("b.bin", content, modified: Date(timeIntervalSince1970: 2_000_000))
        let group = try XCTUnwrap(scanner().scan().duplicates.first)
        var changed = content
        changed[10] ^= 0xFF
        try changed.write(to: URL(fileURLWithPath: a))
        let outcome = trasher().trashDuplicates([b], group: group)
        XCTAssertTrue(outcome.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b))
    }

    /// Hard links are one file: never offered as duplicates of each other.
    func testHardLinksAreNotDuplicates() throws {
        let a = try write("a.bin", random(1_500_000))
        try FileManager.default.linkItem(atPath: a, toPath: root.appendingPathComponent("link.bin").path)
        XCTAssertTrue(scanner().scan().duplicates.isEmpty)
    }

    /// The default roots are the user's six folders; /System, /Library, ~/Library and Time Machine are protected, and entered only
    /// when the user names that very root.
    func testRootsStayOutOfProtectedPlaces() {
        let roots = ScanRoots(home: "/Users/someone", roots: ScanRoots.defaultFolders.map { "/Users/someone/\($0)" })
        XCTAssertEqual(ScanRoots.defaultFolders, ["Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures"])
        for path in ["/System", "/Library/Caches", "/Users/someone/Library", "/Users/someone/Library/Caches/x", "/Volumes/Backup/Backups.backupdb/x"] {
            XCTAssertTrue(roots.isProtected(path), path)
        }
        XCTAssertFalse(roots.isProtected("/Users/someone/Documents/Library"), "a folder named Library inside Documents is the user's")
        XCTAssertFalse(roots.isProtected("/Users/someone/Documents/Old.backup"))
        XCTAssertFalse(roots.covers("/Users/someone/Library/big.bin"))
        XCTAssertTrue(roots.covers("/Users/someone/Movies/big.mov"))
        let added = ScanRoots(home: "/Users/someone", roots: ["/Users/someone/Library/Mobile Documents"])
        XCTAssertTrue(added.mayEnter("/Users/someone/Library/Mobile Documents", under: "/Users/someone/Library/Mobile Documents"))
    }

    /// Never in automatic cleanup.
    func testNeverAutoCleans() async throws {
        let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/LargeFiles/Bundle/Manifest.json")
        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertNotEqual(manifest.autoClean, true)
        XCTAssertEqual(manifest.order, 40)
        XCTAssertEqual(manifest.sdkVersion, 7)
        XCTAssertEqual(manifest.minimumMacOS, "27.0")
        let context = ModuleContext(manifest: manifest, options: NoOptions(), permissions: NoPermissions())
        let report = await LargeFilesModule().autoClean(context: context)
        XCTAssertNil(report)
    }
}

struct NoOptions: OptionStore {
    func bool(_ id: String) -> Bool { false }
    func string(_ id: String) -> String { "" }
    func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
}

struct NoPermissions: PermissionChecker {
    func status(of permission: Permission) -> PermissionStatus { .unknown }
}
