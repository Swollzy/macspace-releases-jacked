import Foundation
import MacSpacePlatform
import MacSpaceSdk

/// Turns a scan into the tile and the page. Pure, so it can be tested without a Mac.
///
/// Nothing is checked when a page opens, there is no main button and nothing runs automatically: a file goes to the Trash only when
/// the user checks it and presses Move to Trash. A duplicate group's kept copy has no checkbox, anywhere.
enum LargeFilesScreenBuilder {
    static let moduleID = "com.macspace.large-files"
    /// Marks the selection actions that move files to the Trash, for the dry-run report (`DryRunReport`).
    static let trashParameters = [DryRunReport.dispositionKey: DryRunReport.Disposition.trash.rawValue]

    static func largeID(_ path: String) -> String { "large:\(path)" }
    static func copyID(_ path: String) -> String { "copy:\(path)" }
    static func path(of id: String) -> String? {
        for prefix in ["large:", "copy:"] where id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return nil
    }

    static func tile(_ snapshot: LargeFilesSnapshot?) -> Tile {
        guard let snapshot else { return Tile(title: loc("large files"), status: loc("not scanned yet")) }
        let status: String
        if snapshot.largeFiles.isEmpty && snapshot.duplicates.isEmpty { status = loc("nothing large or duplicated") }
        else if snapshot.duplicates.isEmpty { status = loc("\(snapshot.largeFiles.count) large files") }
        else { status = loc("\(ByteFormat.string(snapshot.duplicateReclaimableBytes)) in duplicates") }
        let total = snapshot.largeBytes
        // Never `reclaimableBytes`: nothing here is freed without the user choosing it file by file, so it must not count toward what
        // the dashboard or the low-space notification say MacSpace can free.
        return Tile(title: loc("large files"), figure: total > 0 ? ByteFormat.string(total) : nil, status: status,
                    needsAttention: !snapshot.unreadableRoots.isEmpty, graphic: .blocks(segments(snapshot)))
    }

    static func segments(_ snapshot: LargeFilesSnapshot) -> [UsageSegment] {
        var segments: [UsageSegment] = []
        let duplicatePaths = Set(snapshot.duplicates.flatMap { $0.copies.map(\.path) })
        let largeOnly = snapshot.largeFiles.filter { !duplicatePaths.contains($0.path) }.reduce(0) { $0 + $1.allocatedBytes }
        if largeOnly > 0 { segments.append(UsageSegment(id: "large", label: loc("Large files"), bytes: largeOnly, tone: .series(0))) }
        if snapshot.duplicateReclaimableBytes > 0 {
            segments.append(UsageSegment(id: "duplicates", label: loc("Extra copies"), bytes: snapshot.duplicateReclaimableBytes, tone: .caution))
        }
        return segments.sorted { $0.bytes > $1.bytes }
    }

    static func screen(_ snapshot: LargeFilesSnapshot) -> Screen {
        var widgets: [ScreenWidget] = []
        if !snapshot.unreadableRoots.isEmpty {
            let names = snapshot.unreadableRoots.map { ($0 as NSString).lastPathComponent }
            widgets.append(.banner(Banner(id: "unreadable", severity: .warning, title: loc("MacSpace can't read some of your folders"),
                                          message: loc("Allow MacSpace to read \(ListFormatter.localizedString(byJoining: names)), or give it Full Disk Access."),
                                          action: .allowFullDiskAccess(title: loc("Allow")))))
        }
        widgets.append(.section(SectionWidget(id: "large", title: loc("Over 100 MB"), widgets: [.list(ListWidget(id: "large-list",
            emptyMessage: loc("No file over 100 MB in these folders."), rows: largeGroup(snapshot).map { [$0] } ?? []))])))
        widgets.append(.section(SectionWidget(id: "duplicates", title: loc("Duplicates"), widgets: [.list(ListWidget(id: "duplicate-list",
            emptyMessage: loc("No duplicates in these folders."), rows: snapshot.duplicates.map(duplicateRow)))])))
        let roots = snapshot.roots.map { ($0 as NSString).abbreviatingWithTildeInPath }
        widgets.append(.text(TextWidget(id: "roots", text: loc("Looks in \(ListFormatter.localizedString(byJoining: roots)). Files you check go to the Trash, which you empty yourself."), style: .caption)))
        let hero = UsageBar(id: "found", title: loc("In your folders"), segments: segments(snapshot),
                            footnote: loc("Large files and extra copies of the same file. Nothing is moved until you check it."))
        return Screen(title: loc("Large Files"), hero: hero, primary: nil, widgets: widgets)
    }

    /// Every file over 100 MB as one group, largest first, each with a checkbox, none checked. A file that is the kept copy of a
    /// duplicate set is listed without one.
    static func largeGroup(_ snapshot: LargeFilesSnapshot) -> Row? {
        guard !snapshot.largeFiles.isEmpty else { return nil }
        let keepers = Set(snapshot.duplicates.map(\.keeper.path))
        let rows = snapshot.largeFiles.map { file in
            fileRow(id: largeID(file.path), file, badges: keepers.contains(file.path) ? [Badge(loc("Kept copy"), .info, help: loc("Another copy of this file is in Duplicates. This one stays."))] : [])
        }
        var choices: [String: UInt64] = [:]
        for file in snapshot.largeFiles where !keepers.contains(file.path) { choices[largeID(file.path)] = file.allocatedBytes }
        var group = Row.group(id: "large-files", title: loc("Large files"), symbol: "doc", totalBytes: snapshot.largeBytes, rows: rows,
                              detail: loc("Files of 100 MB or more in the folders listed below, largest first."))
        group.selection = Selection(action: trashAction(id: "trashLarge", parameters: [:]), choices: choices, checked: [])
        return group
    }

    /// One set of identical files: the kept copy first, without a checkbox, then the others, none checked.
    static func duplicateRow(_ group: DuplicateGroup) -> Row {
        let keeper = fileRow(id: "keep:\(group.keeper.path)", group.keeper,
                             badges: [Badge(loc("Kept"), .info, help: loc("One copy always stays. This is the oldest."))])
        let copies = group.copies.map { fileRow(id: copyID($0.path), $0) }
        var choices: [String: UInt64] = [:]
        for copy in group.copies { choices[copyID(copy.path)] = copy.allocatedBytes }
        var row = Row(id: "dup:\(group.hash)", title: group.keeper.name,
                      subtitle: loc("\(group.all.count) copies"), trailing: ByteFormat.string(group.reclaimableBytes), symbol: "doc.on.doc",
                      detail: loc("Files with the same size and the same content, compared byte for byte by their SHA-256."),
                      children: [keeper] + copies)
        row.selection = Selection(action: trashAction(id: "trashDuplicates", parameters: ["group": group.hash]), choices: choices, checked: [])
        return row
    }

    static func fileRow(id: String, _ file: FoundFile, badges: [Badge] = []) -> Row {
        let folder = ((file.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return Row(id: id, title: file.name, subtitle: folder, trailing: ByteFormat.string(file.allocatedBytes), badges: badges,
                   symbol: "doc", paths: [file.path])
    }

    static func trashAction(id: String, parameters: [String: String]) -> Action {
        Action(id: id, title: loc("Move to Trash"), symbol: "trash", role: .destructive, parameters: parameters.merging(trashParameters) { a, _ in a },
               confirmation: Confirmation(title: loc("Move the checked files to the Trash?"),
                                          message: loc("They stay in the Trash until you empty it."), confirmTitle: loc("Move to Trash")),
               workingTitle: loc("Moving to Trash"))
    }
}
