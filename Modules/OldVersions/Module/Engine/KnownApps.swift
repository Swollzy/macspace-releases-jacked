import Foundation

/// An app this module knows the files of: where it keeps the user's things, which are never offered, and what its earlier versions
/// left that the current one no longer uses. Adding an app is one entry in `KnownApps.all`; an app that is not listed but carries an
/// identifier with `KnownApps.familyPrefix` still gets the rules every app shares (old copies, caches, saved window state, logs, crash
/// reports), with its Application Support folder kept.
public struct KnownApp: Equatable, Sendable {
    /// A path in ~/Library that is safe to move to the Trash, and why.
    public struct Clearable: Equatable, Sendable {
        /// Relative to ~/Library ("Application Support/Burrow/logs").
        public var path: String
        public var note: String
        /// Checked when the page opens. Off for what is slow to get back (a download), even though the app gets it back itself.
        public var checked: Bool
        /// Left only by versions before this one: the current version no longer reads it.
        public var staleSince: String?

        public init(_ path: String, note: String, checked: Bool = true, staleSince: String? = nil) {
            self.path = path
            self.note = note
            self.checked = checked
            self.staleSince = staleSince
        }
    }

    /// The name the Finder shows, without ".app".
    public var name: String
    public var bundleID: String
    /// Names earlier versions were installed under ("Wallflower Beta"). Copies under them count as old copies of this app.
    public var formerNames: [String]
    /// Relative to ~/Library: the user's settings and data. Never offered, nothing inside them either, unless listed in `clearable`.
    public var kept: [String]
    public var clearable: [Clearable]

    public init(name: String, bundleID: String, formerNames: [String] = [], kept: [String] = [], clearable: [Clearable] = []) {
        self.name = name
        self.bundleID = bundleID
        self.formerNames = formerNames
        self.kept = kept
        self.clearable = clearable
    }

    /// What every app keeps whatever it is: its preferences and its Application Support folders, by name and by identifier, and its
    /// sandbox containers.
    public var allKept: [String] {
        var paths = kept
        paths += ["Preferences/\(bundleID).plist", "Application Support/\(name)", "Application Support/\(bundleID)",
                  "Containers/\(bundleID)", "Group Containers/\(bundleID)"]
        var seen = Set<String>()
        return paths.filter { seen.insert($0.lowercased()).inserted }
    }

    /// The same rules for an app found by its identifier only.
    public static func generic(name: String, bundleID: String) -> KnownApp {
        KnownApp(name: name, bundleID: bundleID)
    }
}

public enum KnownApps {
    /// Identifiers of Swollzy's apps. Any installed app under it is looked after, listed below or not.
    public static let familyPrefix = "com.swollzy."

    /// What each app keeps and leaves, read from its own source: Wallflower's library and Swivel's custom slices live in
    /// Application Support and are kept; Burrow's bottles, engines, runtimes, library and snapshots are kept, its logs and download
    /// cache are not.
    public static let all: [KnownApp] = [
        KnownApp(name: "Wallflower", bundleID: "com.swollzy.wallflower"),
        KnownApp(name: "Swivel", bundleID: "com.swollzy.swivel"),
        KnownApp(name: "Burrow", bundleID: "com.swollzy.burrow",
                 kept: ["Application Support/Burrow/bottles", "Application Support/Burrow/engines", "Application Support/Burrow/runtimes",
                        "Application Support/Burrow/library", "Application Support/Burrow/snapshots"],
                 clearable: [
                    .init("Application Support/Burrow/logs", note: "Install and launch logs. Burrow writes new ones."),
                    .init("Application Support/Burrow/cache/turbo", note: "Where Burrow before 0.3.1 tried to build its faster engine. It never built there.",
                          staleSince: "0.3.1"),
                    .init("Application Support/Burrow/cache/downloads", note: "Installers Burrow downloaded. It downloads them again if needed.",
                          checked: false),
                 ]),
    ]

    public static func known(_ bundleID: String) -> KnownApp? {
        all.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    public static func isFamily(_ bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix(familyPrefix)
    }
}
