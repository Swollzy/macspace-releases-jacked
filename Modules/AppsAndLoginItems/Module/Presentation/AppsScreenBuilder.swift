import Foundation
import MacSpacePlatform
import MacSpaceSdk

/// Turns a reading into the tile and the page. Pure, so it can be tested without a Mac.
///
/// Uninstalling is two steps: an app's row moves only the app to the Trash; its leftovers are then offered in a section of their own,
/// none checked. Launch agents are switches that keep their file. Nothing here runs automatically.
enum AppsScreenBuilder {
    static let moduleID = "com.macspace.apps-and-login-items"
    static let loginItemsPane = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    /// Apps drawn as blocks of their own on the bar; the rest share one.
    static let shownApps = 8

    static func tile(_ snapshot: AppsSnapshot) -> Tile {
        let off = snapshot.agents.filter(\.disabled).count + snapshot.journaled.count
        let waiting = snapshot.pending.filter { !$0.leftovers.isEmpty }.count
        let status: String
        if waiting > 0 { status = waiting == 1 ? loc("1 removed app left files") : loc("\(waiting) removed apps left files") }
        else if !snapshot.orphans.isEmpty {
            status = loc("\(ByteFormat.string(snapshot.orphans.reduce(0) { $0 + $1.leftover.bytes })) left by removed apps")
        }
        else if off > 0 { status = loc("\(snapshot.apps.count) apps, \(off) agents off") }
        else { status = loc("\(snapshot.apps.count) apps") }
        // No `reclaimableBytes`: removing an app is the user's decision, never something MacSpace frees on its own.
        return Tile(title: loc("apps"), figure: snapshot.appBytes > 0 ? ByteFormat.string(snapshot.appBytes) : nil, status: status,
                    needsAttention: waiting > 0, graphic: .blocks(segments(snapshot)))
    }

    static func segments(_ snapshot: AppsSnapshot) -> [UsageSegment] {
        let sorted = snapshot.apps.sorted { $0.bytes > $1.bytes }
        var segments = sorted.prefix(shownApps).enumerated().map { index, app in
            UsageSegment(id: "app:\(app.path)", label: app.name, bytes: app.bytes, tone: .series(index))
        }
        let rest = sorted.dropFirst(shownApps).reduce(0) { $0 + $1.bytes }
        if rest > 0 { segments.append(UsageSegment(id: "other-apps", label: loc("Other apps"), bytes: rest, tone: .neutral)) }
        return segments.filter { $0.bytes > 0 }
    }

    static func screen(_ snapshot: AppsSnapshot) -> Screen {
        var widgets: [ScreenWidget] = []
        let pending = snapshot.pending.filter { !$0.leftovers.isEmpty }
        if !pending.isEmpty {
            widgets.append(.section(SectionWidget(id: "leftovers", title: loc("Left by apps in the Trash"),
                                                  widgets: [.list(ListWidget(id: "leftover-list", rows: pending.map(leftoverRow)))])))
        }
        let groups = snapshot.orphanGroups
        if !groups.isEmpty {
            widgets.append(.section(SectionWidget(id: "orphans", title: loc("Left by apps no longer installed"),
                widgets: [.list(ListWidget(id: "orphan-list", rows: groups.map { orphanRow(owner: $0.owner, items: $0.items) }))],
                isCollapsible: true)))
        }
        widgets.append(.section(SectionWidget(id: "apps", title: loc("Applications"), widgets: [.list(ListWidget(id: "app-list",
            emptyMessage: loc("No apps in Applications."), rows: snapshot.apps.sorted { $0.bytes > $1.bytes }.map(appRow)))])))
        widgets.append(.section(SectionWidget(id: "agents", title: loc("Launch agents"), widgets: [
            .toggles(ToggleList(id: "agent-list", footnote: loc("Switching an agent off stops it starting at login and keeps its file. Switch it on to put it back."),
                                rows: snapshot.agents.map(agentToggle) + snapshot.journaled.map(journaledToggle))),
            .button(ButtonWidget(id: "login-items", action: .openSettings(title: loc("Open Login Items"), url: loginItemsPane),
                                 footnote: loc("Apps that open at login and background items are listed in System Settings."))),
        ])))
        let hero = UsageBar(id: "apps", title: loc("Applications"), totalBytes: snapshot.appBytes, segments: segments(snapshot))
        return Screen(title: loc("Apps & Login Items"), hero: hero, primary: nil, widgets: widgets)
    }

    static func appRow(_ app: InstalledApp) -> Row {
        var row = Row(id: "app:\(app.path)", title: app.name, subtitle: app.bundleID, trailing: app.bytes > 0 ? ByteFormat.string(app.bytes) : nil,
                      symbol: "app", paths: [app.path])
        if app.isProtected {
            row.badges = [Badge(loc("Part of macOS"), .info)]
        } else {
            row.actions = [Action(id: "trashApp", title: loc("Move to Trash"), symbol: "trash", role: .destructive, parameters: ["path": app.path],
                                  confirmation: Confirmation(title: loc("Move \(app.name) to the Trash?"),
                                                             message: loc("Only the app moves now. MacSpace then shows what it left, for you to choose."),
                                                             confirmTitle: loc("Move to Trash")),
                                  workingTitle: loc("Moving to Trash"))]
        }
        return row
    }

    /// An app in the Trash and what it left, each with a checkbox, none checked.
    static func leftoverRow(_ pending: AppsSnapshot.Pending) -> Row {
        let rows = pending.leftovers.map { leftover in
            Row(id: "leftover:\(leftover.path)", title: (leftover.path as NSString).lastPathComponent, subtitle: placeName(leftover.place),
                trailing: ByteFormat.string(leftover.bytes), symbol: "folder", paths: [leftover.path])
        }
        var choices: [String: UInt64] = [:]
        for leftover in pending.leftovers { choices["leftover:\(leftover.path)"] = leftover.bytes }
        let total = pending.leftovers.reduce(0) { $0 + $1.bytes }
        var row = Row.group(id: "pending:\(pending.app.bundleID)", title: pending.app.name, symbol: "app.dashed", totalBytes: total, rows: rows,
                            detail: loc("Files in your Library named after this app or its identifier. They go to the Trash only if you check them."))
        row.actions = [Action(id: "keepLeftovers", title: loc("Keep"), parameters: ["app": pending.app.bundleID])]
        row.selection = Selection(action: Action(id: "trashLeftovers", title: loc("Move to Trash"), symbol: "trash", role: .destructive,
                                                 parameters: ["app": pending.app.bundleID, DryRunReport.dispositionKey: DryRunReport.Disposition.trash.rawValue],
                                                 confirmation: Confirmation(title: loc("Move the checked files to the Trash?"),
                                                                            message: loc("They stay in the Trash until you empty it."), confirmTitle: loc("Move to Trash")),
                                                 workingTitle: loc("Moving to Trash")),
                                  choices: choices, checked: [])
        return row
    }

    /// What one app or component no longer on the Mac left, by the identifier it is named by, each with a checkbox, none checked.
    static func orphanRow(owner: String, items: [Leftover]) -> Row {
        let rows = items.map { leftover in
            Row(id: "orphan:\(leftover.path)", title: (leftover.path as NSString).lastPathComponent, subtitle: placeName(leftover.place),
                trailing: ByteFormat.string(leftover.bytes), symbol: "folder", paths: [leftover.path])
        }
        var choices: [String: UInt64] = [:]
        for leftover in items { choices["orphan:\(leftover.path)"] = leftover.bytes }
        var row = Row.group(id: "orphans:\(owner)", title: AppNames.prettified(owner), symbol: "questionmark.app.dashed",
                            totalBytes: items.reduce(0) { $0 + $1.bytes }, rows: rows,
                            detail: loc("Named after an app or helper that is not on this Mac, from a maker with no app installed. Check what you recognize."))
        row.badges = [Badge(owner, .info)]
        row.selection = Selection(action: Action(id: "trashOrphans", title: loc("Move to Trash"), symbol: "trash", role: .destructive,
                                                 parameters: ["owner": owner, DryRunReport.dispositionKey: DryRunReport.Disposition.trash.rawValue],
                                                 confirmation: Confirmation(title: loc("Move the checked files to the Trash?"),
                                                                            message: loc("They stay in the Trash until you empty it."), confirmTitle: loc("Move to Trash")),
                                                 workingTitle: loc("Moving to Trash")),
                                  choices: choices, checked: [])
        return row
    }

    static func placeName(_ place: Leftover.Place) -> String {
        switch place {
        case .applicationSupport: return loc("Application Support")
        case .caches: return loc("Caches")
        case .preferences: return loc("Preferences")
        case .containers: return loc("Containers")
        case .savedState: return loc("Saved Application State")
        case .webKit: return loc("WebKit")
        case .groupContainers: return loc("Group Containers")
        }
    }

    static func agentToggle(_ agent: LaunchAgent) -> ToggleRow {
        var badge: Badge?
        if agent.programMissing { badge = Badge(loc("Program missing"), .action, help: loc("The app that installed it is gone. Switch it off.")) }
        else if agent.runAtLoad { badge = Badge(loc("Runs at login"), .info) }
        else if agent.keepAlive { badge = Badge(loc("Kept running"), .info) }
        let program = agent.program.map { ($0 as NSString).lastPathComponent }
        return ToggleRow(id: "agent:\(agent.label)", title: agent.label, subtitle: program, isOn: !agent.disabled, badge: badge,
                         detail: agent.scope == .system ? loc("Installed for every user in /Library/LaunchAgents. Switched off for you only.")
                                                        : loc("Installed for you in ~/Library/LaunchAgents."),
                         action: Action(id: "setAgent", title: agent.label, parameters: ["label": agent.label, "plist": agent.plistPath]))
    }

    /// An agent MacSpace switched off whose file is gone: still listed, off, so it can be switched back on.
    static func journaledToggle(_ entry: DisabledAgentsJournal.Entry) -> ToggleRow {
        ToggleRow(id: "agent:\(entry.label)", title: entry.label, subtitle: entry.program.map { ($0 as NSString).lastPathComponent }, isOn: false,
                  badge: Badge(loc("File gone"), .info), action: Action(id: "setAgent", title: entry.label, parameters: ["label": entry.label, "plist": entry.plistPath]))
    }
}
