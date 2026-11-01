import XCTest
@testable import MacSpaceApp

@MainActor
final class UninstallTests: XCTestCase {
    func testRestorationFailureKeepsHelperAndApp() async {
        var calls: [String] = []
        do {
            try await AppUninstaller.run([
                { calls.append("restore"); throw AppUninstaller.Failure(message: "restore failed") },
                { calls.append("unregister") },
                { calls.append("trash") }
            ])
            XCTFail("must propagate restoration failure")
        } catch { XCTAssertEqual(error.localizedDescription, "restore failed") }
        XCTAssertEqual(calls, ["restore"])
    }

    func testRemovalRunsOnlyAfterRestorationAndHelperRemoval() async throws {
        var calls: [String] = []
        try await AppUninstaller.run([
            { calls.append("restore") },
            { calls.append("unregister") },
            { calls.append("trash") }
        ])
        XCTAssertEqual(calls, ["restore", "unregister", "trash"])
    }

    func testLeftoversKeepSettingsUnlessAskedAndNeverFollowLinks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let library = home.appendingPathComponent("Library")
        for path in ["Caches/com.swollzy.molt", "Logs/Molt", "Application Support/Molt"] {
            try FileManager.default.createDirectory(at: library.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Preferences"), withIntermediateDirectories: true)
        try Data().write(to: library.appendingPathComponent("Preferences/com.swollzy.molt.plist"))
        let elsewhere = home.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("HTTPStorages"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("HTTPStorages/com.swollzy.molt"), withDestinationURL: elsewhere)

        let kept = AppUninstaller.leftovers(keepData: true, home: home).map(\.lastPathComponent)
        XCTAssertEqual(Set(kept), ["com.swollzy.molt", "Molt"])
        XCTAssertTrue(AppUninstaller.leftovers(keepData: true, home: home).allSatisfy { !$0.path.contains("Application Support") })

        let all = AppUninstaller.leftovers(keepData: false, home: home).map { $0.path.replacingOccurrences(of: library.path + "/", with: "") }
        XCTAssertEqual(Set(all), ["Caches/com.swollzy.molt", "Logs/Molt", "Application Support/Molt", "Preferences/com.swollzy.molt.plist"])
    }
}
