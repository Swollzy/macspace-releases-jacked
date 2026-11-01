import Foundation
import MacSpacePlatform
import MacSpaceSdk

/// Turns a reading into the tile and the page. Pure, so it can be tested without a Mac.
///
/// One section per app: the copy kept, what can go (each with a checkbox; what is safe is checked, what is slow to get back or in use
/// is not), and what is kept for the user, listed without a checkbox so it is clear it stays.
enum OldVersionsScreenBuilder {
    static let moduleID = "com.macspace.old-versions"

    static func tile(_ snapshot: OldVersionsSnapshot) -> Tile {
        let status: String
        switch snapshot.count {
        case 0: status = snapshot.apps.isEmpty ? loc("No Swollzy apps on this Mac") : loc("Nothing left behind")
        case 1: status = loc("1 item left behind")
        default: status = loc("\(snapshot.count) items left behind")
        }
        // No `reclaimableBytes`: these go to the Trash only as the user checks them, never on their own.
        return Tile(title: loc("old versions"), figure: snapshot.bytes > 0 ? ByteFormat.string(snapshot.bytes) : nil, status: status,
                    needsAttention: snapshot.count > 0, graphic: .blocks(segments(snapshot)))
    }

    static func segments(_ snapshot: OldVersionsSnapshot) -> [UsageSegment] {
        snapshot.apps.sorted { $0.bytes > $1.bytes }.enumerated().map { index, app in
            UsageSegment(id: "app:\(app.bundleID)", label: app.name, bytes: app.bytes, tone: .series(index))
        }.filter { $0.bytes > 0 }
    }

    static func screen(_ snapshot: OldVersionsSnapshot) -> Screen {
        var widgets: [ScreenWidget] = snapshot.apps.map(section)
        if snapshot.apps.isEmpty {
            widgets.append(.section(SectionWidget(id: "none", title: loc("Swollzy apps"), widgets: [.list(ListWidget(id: "none-list",
                emptyMessage: loc("No Wallflower, Burrow, Swivel or other Swollzy app or its files on this Mac."), rows: []))])))
        }
        let hero = UsageBar(id: "old-versions", title: loc("Left by old versions"), totalBytes: snapshot.bytes, segments: segments(snapshot))
        return Screen(title: loc("Old Versions"), hero: hero, primary: nil, widgets: widgets)
    }

    static func section(_ app: AppReport) -> ScreenWidget {
        var rows: [Row] = []
        if !app.findings.isEmpty { rows.append(findingsRow(app)) }
        if !app.kept.isEmpty { rows.append(keptRow(app)) }
        let subtitle: String
        if let current = app.current {
            subtitle = app.isRunning ? loc("Version \(current.versionText), open") : loc("Version \(current.versionText)")
        } else {
            subtitle = loc("Not installed")
        }
        return .section(SectionWidget(id: "app:\(app.bundleID)", title: app.name, subtitle: subtitle, widgets: [
            .list(ListWidget(id: "list:\(app.bundleID)", emptyMessage: loc("Nothing left behind."), rows: rows)),
        ]))
    }

    /// What can go, each with a checkbox. Checked: what the app makes again by itself and old copies. Not checked: downloads, and
    /// anything of an open app.
    static func findingsRow(_ app: AppReport) -> Row {
        let rows = app.findings.map { finding in
            var row = Row(id: finding.id, title: title(finding), subtitle: kindName(finding.kind), trailing: ByteFormat.string(finding.bytes),
                          symbol: symbol(finding.kind), detail: finding.note.isEmpty ? nil : finding.note, paths: [finding.path])
            if app.isRunning && finding.kind != .crashReport && finding.kind != .launchAgent && finding.kind != .oldCopy {
                row.badges = [Badge(loc("In use"), .action, help: loc("Quit \(app.name) to move this."))]
            }
            return row
        }
        var choices: [String: UInt64] = [:]
        for finding in app.findings { choices[finding.id] = finding.bytes }
        var row = Row.group(id: "findings:\(app.bundleID)", title: loc("Left behind"), symbol: "shippingbox", totalBytes: app.bytes, rows: rows,
                            detail: loc("Made by earlier versions or by \(app.name) itself, and safe to move: it makes again what it needs."))
        row.selection = Selection(action: Action(id: "trash", title: loc("Move to Trash"), symbol: "trash", role: .destructive,
                                                 parameters: ["app": app.bundleID, DryRunReport.dispositionKey: DryRunReport.Disposition.trash.rawValue],
                                                 confirmation: Confirmation(title: loc("Move the checked items to the Trash?"),
                                                                            message: loc("Your \(app.name) settings and library stay. The items stay in the Trash until you empty it."),
                                                                            confirmTitle: loc("Move to Trash")),
                                                 workingTitle: loc("Moving to Trash")),
                                  choices: choices, checked: app.findings.filter(\.checked).map(\.id))
        return row
    }

    /// What stays: settings and libraries, no checkbox.
    static func keptRow(_ app: AppReport) -> Row {
        let rows = app.kept.sorted { $0.key < $1.key }.map { path, bytes in
            Row(id: "kept:\(path)", title: (path as NSString).lastPathComponent, subtitle: (((path as NSString).deletingLastPathComponent) as NSString).lastPathComponent,
                trailing: ByteFormat.string(bytes), symbol: "lock", paths: [path])
        }
        var row = Row.group(id: "kept:\(app.bundleID)", title: loc("Kept"), symbol: "lock.shield", totalBytes: app.kept.values.reduce(0, +), rows: rows,
                            detail: loc("Your settings and library. Never moved."))
        row.badges = [Badge(loc("Stays"), .info)]
        return row
    }

    static func title(_ finding: Finding) -> String {
        switch finding.kind {
        case .oldCopy: return (finding.path as NSString).lastPathComponent + " · " + OldVersionScanner.folderName(of: finding.path)
        case .launchAgent: return finding.label ?? (finding.path as NSString).lastPathComponent
        default: return (finding.path as NSString).lastPathComponent
        }
    }

    static func kindName(_ kind: Finding.Kind) -> String {
        switch kind {
        case .oldCopy: return loc("Older copy of the app")
        case .cache: return loc("Cache")
        case .savedState: return loc("Saved windows")
        case .logs: return loc("Logs")
        case .crashReport: return loc("Crash report")
        case .clearable: return loc("Support file")
        case .launchAgent: return loc("Launch agent")
        }
    }

    static func symbol(_ kind: Finding.Kind) -> String {
        switch kind {
        case .oldCopy: return "app.dashed"
        case .cache: return "internaldrive"
        case .savedState: return "macwindow"
        case .logs: return "doc.text"
        case .crashReport: return "exclamationmark.triangle"
        case .clearable: return "folder"
        case .launchAgent: return "power"
        }
    }
}
