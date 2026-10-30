import Foundation

/// Where Large Files looks, and where it never looks unless the user names that place as a root of its own.
///
/// By default only the user's own folders: Documents, Downloads, Desktop, Movies, Music and Pictures. Never /System, /Library,
/// ~/Library or a Time Machine volume, unless the user adds that very root (`extraRootsURL`); a root the user adds that holds one of
/// them still skips it. Links are never followed, and packages (a Photos library, an app) are never opened: a file inside one is
/// not the user's to trash on its own.
public struct ScanRoots: Equatable, Sendable {
    public static let defaultFolders = ["Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures"]

    /// Roots the user added, one absolute path per line, in a file they edit by hand. There is no text option in Settings.
    public static let extraRootsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSpace/large-files-roots.txt")

    public var home: String
    public var roots: [String]

    public init(home: String, roots: [String]) {
        self.home = (home as NSString).standardizingPath
        self.roots = roots.map { ($0 as NSString).standardizingPath }
    }

    /// The default roots under `home`, then those the user added in `extraRootsURL` that exist.
    public static func current(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                               extraRootsURL: URL = ScanRoots.extraRootsURL) -> ScanRoots {
        var roots = defaultFolders.map { (home as NSString).appendingPathComponent($0) }
        if let text = try? String(contentsOf: extraRootsURL, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let path = (String(line).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                guard path.hasPrefix("/"), !path.isEmpty, !roots.contains(path) else { continue }
                roots.append(path)
            }
        }
        return ScanRoots(home: home, roots: roots.filter { FileManager.default.fileExists(atPath: $0) })
    }

    /// Whether `path` is one of the places Large Files never enters on its own: /System, /Library, ~/Library, a Time Machine volume.
    public func isProtected(_ path: String) -> Bool {
        let path = (path as NSString).standardizingPath
        let library = (home as NSString).appendingPathComponent("Library")
        for place in ["/System", "/Library", library] where Self.isInside(path, place) { return true }
        return Self.isTimeMachine(path)
    }

    /// Whether the walk may enter `path` under `root`: a protected place is entered only when the user named it as the root itself.
    public func mayEnter(_ path: String, under root: String) -> Bool {
        guard isProtected(path) else { return true }
        return (path as NSString).standardizingPath == (root as NSString).standardizingPath
    }

    /// Whether `path` lies in one of the roots, and may be entered from it: what a Move to Trash checks again before it acts.
    public func covers(_ path: String) -> Bool {
        let path = (path as NSString).standardizingPath
        guard let root = roots.filter({ Self.isInside(path, $0) }).max(by: { $0.count < $1.count }) else { return false }
        // Every folder between the root and the file must be one the walk could have entered.
        var current = (path as NSString).deletingLastPathComponent
        while current.count > root.count {
            if !mayEnter(current, under: root) { return false }
            current = (current as NSString).deletingLastPathComponent
        }
        return !isProtected(path) || isProtected(root)
    }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// A Time Machine backup disk or a backup inside one: under /Volumes, a volume whose root holds `Backups.backupdb` or a
    /// `.timemachine` marker, or a backup folder of an APFS backup disk (`<date>.backup`, `.previous`, `.inprogress`).
    static func isTimeMachine(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        if components.contains("Backups.backupdb") || components.contains(".timemachine") { return true }
        guard components.count >= 3, components[1] == "Volumes" else { return false }
        // Only on another volume: a user's own folder named "Old.backup" in Documents is not a backup disk.
        if components.dropFirst(3).contains(where: { $0.hasSuffix(".backup") || $0.hasSuffix(".previous") || $0.hasSuffix(".inprogress") }) { return true }
        let volume = "/Volumes/\(components[2])"
        let manager = FileManager.default
        return manager.fileExists(atPath: volume + "/Backups.backupdb") || manager.fileExists(atPath: volume + "/.timemachine")
            || manager.fileExists(atPath: volume + "/.com.apple.timemachine.supported") && manager.fileExists(atPath: volume + "/.com.apple.TMCheckpoint")
    }
}
