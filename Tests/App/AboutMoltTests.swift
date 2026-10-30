import AppKit
import XCTest
@testable import MacSpaceApp

@MainActor
final class AboutMoltTests: XCTestCase {
    func testAboutMatchesMacBatContentAndKeepsAllAuthorLines() {
        _ = NSApplication.shared
        let alert = AboutMolt.makeAlert()
        alert.layout()
        XCTAssertEqual(alert.messageText, "Molt")
        XCTAssertTrue(alert.informativeText.contains("\n\n"))
        XCTAssertTrue(alert.informativeText.contains("Gio Mantovani/1architect"))
        XCTAssertTrue(alert.informativeText.contains("Swollzy"), "Molt is credited to its maker, the original after it")
        XCTAssertTrue(alert.informativeText.contains("MIT License"), "the license the original came under is named")
        XCTAssertEqual(alert.buttons.count, 3)
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
        let description = alert.window.contentView!.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == alert.informativeText }!
        XCTAssertEqual(description.maximumNumberOfLines, 0, "the author must not be truncated to two lines")
        XCTAssertEqual(description.alignment, .left)
    }
}
