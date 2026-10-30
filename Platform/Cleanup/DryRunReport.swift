import Foundation
import MacSpaceSdk

/// What MacSpace would free and what it would move to the Trash, written before anything is deleted. Making it deletes nothing and
/// changes nothing: it only reads the modules' pages. It is written as JSON and Markdown to a folder the user picks, and stays there:
/// MacSpace never sends a report, a file list or a path anywhere.
public struct DryRunReport: Codable, Equatable, Sendable {
    /// The selection action parameter that says what an action does to its checked rows (`Disposition`). Absent: it frees space.
    public static let dispositionKey = "macspace.disposition"

    public enum Disposition: String, Codable, Sendable {
        /// macOS or MacSpace frees the space (purge, caches).
        case free
        /// The files go to the Trash, which the user empties.
        case trash
    }

    public struct Item: Codable, Equatable, Sendable {
        public var title: String
        public var bytes: UInt64
        public var paths: [String]
        public var disposition: Disposition
        /// Checked by the user (or by the module's own suggestion): the module's button would act on it now.
        public var checked: Bool

        public init(title: String, bytes: UInt64, paths: [String], disposition: Disposition, checked: Bool) {
            self.title = title
            self.bytes = bytes
            self.paths = paths
            self.disposition = disposition
            self.checked = checked
        }
    }

    public struct Module: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// What the module's own Free would free, as its tile says; nil when it frees nothing by itself.
        public var reclaimableBytes: UInt64?
        /// Whether automatic cleanup may run it.
        public var autoClean: Bool
        public var items: [Item]

        public init(id: String, name: String, reclaimableBytes: UInt64?, autoClean: Bool, items: [Item]) {
            self.id = id
            self.name = name
            self.reclaimableBytes = reclaimableBytes
            self.autoClean = autoClean
            self.items = items
        }

        public var checkedTrashBytes: UInt64 { items.filter { $0.checked && $0.disposition == .trash }.reduce(0) { $0 + $1.bytes } }
        public var checkedFreeBytes: UInt64 { items.filter { $0.checked && $0.disposition == .free }.reduce(0) { $0 + $1.bytes } }
    }

    public var created: Date
    public var macSpaceVersion: String
    public var freeBytes: UInt64?
    public var capacityBytes: UInt64?
    public var lowDisk: Bool
    public var modules: [Module]

    public init(created: Date = Date(), macSpaceVersion: String, freeBytes: UInt64?, capacityBytes: UInt64?, modules: [Module]) {
        self.created = created
        self.macSpaceVersion = macSpaceVersion
        self.freeBytes = freeBytes
        self.capacityBytes = capacityBytes
        if let freeBytes, let capacityBytes { lowDisk = LowDiskPolicy.isLow(available: freeBytes, capacity: capacityBytes) } else { lowDisk = false }
        self.modules = modules
    }

    /// What would be freed: each module's own Free, plus the checked rows it would free.
    public var wouldFreeBytes: UInt64 { modules.reduce(0) { $0 + ($1.reclaimableBytes ?? 0) } }
    /// What would go to the Trash: the rows the user checked on Large Files and Apps & Login Items.
    public var wouldTrashBytes: UInt64 { modules.reduce(0) { $0 + $1.checkedTrashBytes } }

    /// The rows a page offers to act on (`Row.selection`), checked or not, with what its action does to them. `checked` gives the
    /// boxes as the user left them, by group id; nil uses the page's own `Selection.checked`.
    ///
    /// A page can draw one group twice (System Data's caches are under Free now and again in the bar's "Can be freed" block), so each
    /// row is taken once. A row with nothing left in it (a cache already freed, listed until the next scan) frees nothing and is left
    /// out.
    public static func items(in screen: Screen, checked: (Row) -> Set<String>? = { _ in nil }) -> [Item] {
        var items: [Item] = []
        var seen: Set<String> = []
        func visitRow(_ row: Row) {
            if let selection = row.selection {
                let disposition = Disposition(rawValue: selection.action.parameters[dispositionKey] ?? "") ?? .free
                let boxes = checked(row) ?? Set(selection.checked)
                for child in row.children where (selection.choices[child.id] ?? 0) > 0 && seen.insert(child.id).inserted {
                    items.append(Item(title: child.title, bytes: selection.choices[child.id] ?? 0, paths: child.paths,
                                      disposition: disposition, checked: boxes.contains(child.id)))
                }
            }
            row.children.forEach(visitRow)
        }
        func visit(_ widget: ScreenWidget) {
            switch widget {
            case let .list(list): list.rows.forEach(visitRow)
            case let .section(section): section.widgets.forEach(visit)
            case let .usage(bar): bar.segments.flatMap(\.items).forEach(visitRow)
            default: break
            }
        }
        if let hero = screen.hero { visit(.usage(hero)) }
        screen.widgets.forEach(visit)
        return items
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func markdown() -> String {
        let date = ISO8601DateFormatter().string(from: created)
        var lines = ["# MacSpace dry-run report", "", "Made \(date) by MacSpace \(macSpaceVersion). Nothing was deleted to make this report.", ""]
        if let freeBytes, let capacityBytes {
            lines.append("Disk: \(ByteFormat.string(freeBytes)) free of \(ByteFormat.string(capacityBytes))\(lowDisk ? " (low)" : "").")
            lines.append("")
        }
        lines += ["## Summary", "",
                  "- Would be freed by MacSpace's Free buttons: \(ByteFormat.string(wouldFreeBytes))",
                  "- Would be moved to the Trash (checked files only): \(ByteFormat.string(wouldTrashBytes))", ""]
        for module in modules {
            lines.append("## \(module.name)")
            lines.append("")
            if let bytes = module.reclaimableBytes { lines.append("Free would free: \(ByteFormat.string(bytes))") }
            lines.append(module.autoClean ? "Automatic cleanup: may run it." : "Automatic cleanup: never runs it.")
            let checked = module.items.filter(\.checked)
            let unchecked = module.items.count - checked.count
            if checked.isEmpty {
                lines.append("Checked: nothing.")
            } else {
                lines.append("")
                lines.append("| Would | Item | Size | Path |")
                lines.append("| --- | --- | --- | --- |")
                for item in checked {
                    let verb = item.disposition == .trash ? "Trash" : "Free"
                    lines.append("| \(verb) | \(Self.cell(item.title)) | \(ByteFormat.string(item.bytes)) | \(Self.cell(item.paths.joined(separator: ", "))) |")
                }
            }
            if unchecked > 0 { lines.append(""); lines.append("\(unchecked) more offered, not checked: they would stay.") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    /// Writes `MacSpace Dry Run <date>.json` and `.md` into `folder`, and returns both. Local files only.
    public func write(to folder: URL) throws -> (json: URL, markdown: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "MacSpace Dry Run \(formatter.string(from: created))"
        let json = folder.appendingPathComponent(base + ".json")
        let markdown = folder.appendingPathComponent(base + ".md")
        try self.json().write(to: json, options: .atomic)
        try Data(self.markdown().utf8).write(to: markdown, options: .atomic)
        return (json, markdown)
    }
}

/// When the disk counts as nearly full: under 15 GB free or under 10% of the disk, whichever is larger, and never a threshold under
/// 5 GB. The same rule for the low-space notification and the emergency purge.
public enum LowDiskPolicy {
    public static let bytes: UInt64 = 15_000_000_000
    public static let fraction = 0.10
    public static let floor: UInt64 = 5_000_000_000

    public static func threshold(capacity: UInt64) -> UInt64 {
        max(floor, max(bytes, UInt64(Double(capacity) * fraction)))
    }

    public static func isLow(available: UInt64, capacity: UInt64) -> Bool {
        available < threshold(capacity: capacity)
    }
}
