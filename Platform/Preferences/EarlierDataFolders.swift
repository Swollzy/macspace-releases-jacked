import Foundation

/// Molt was MacSpace. Its folders kept MacSpace's name until the rename, and what is in them still matters: the settings Debloat and
/// Siri changed and how to put them back, the launch agents switched off, the cleanup history. At launch the app moves the user's
/// folders over and the helper moves the one for every user, once, and only where Molt has none of its own yet.
///
/// Settings kept in MacSpace's defaults (com.macspace.app) are copied over once too, when Molt has none of its own yet
/// (`importEarlierDefaults`).
///
/// Not while MacSpace itself is still installed: its own Uninstall reads those folders to put back what it changed, so it must find
/// them where it left them. Molt asks the user to uninstall it first (`earlierAppPaths`), and moves the folders on the next launch.
public enum EarlierDataFolders {
    /// Where MacSpace may still be installed.
    public static func earlierAppPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                       applications: String = "/Applications") -> [String] {
        [(applications as NSString).appendingPathComponent("MacSpace.app"), home.appendingPathComponent("Applications/MacSpace.app").path]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Earlier name → current name, relative to a Library folder.
    public static let moves = [("Application Support/MacSpace", "Application Support/Molt"), ("Logs/MacSpace", "Logs/Molt")]

    /// The user's folders in ~/Library. Returns what was moved, for the log.
    @discardableResult
    public static func moveUserFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                       applications: String = "/Applications") -> [String] {
        guard earlierAppPaths(home: home, applications: applications).isEmpty else { return [] }
        return move(in: home.appendingPathComponent("Library"))
    }

    /// The folder for every user in /Library: the helper's, which runs as root.
    @discardableResult
    public static func moveSystemFolder(library: URL = URL(fileURLWithPath: "/Library")) -> [String] {
        // The helper runs as root for every user: MacSpace in any user's Applications folder still needs the folder to uninstall.
        let users = (try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? []
        let places = ["/Applications/MacSpace.app"] + users.map { "/Users/\($0)/Applications/MacSpace.app" }
        guard !places.contains(where: { FileManager.default.fileExists(atPath: $0) }) else { return [] }
        return move(in: library, only: ["Application Support/MacSpace"])
    }

    static func move(in library: URL, only: Set<String>? = nil) -> [String] {
        var moved: [String] = []
        let manager = FileManager.default
        for (earlier, current) in moves where only?.contains(earlier) ?? true {
            let from = library.appendingPathComponent(earlier), to = library.appendingPathComponent(current)
            var info = stat()
            // A real folder only, never a link.
            guard lstat(from.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            do {
                if !manager.fileExists(atPath: to.path) {
                    try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.moveItem(at: from, to: to)
                    moved.append("\(from.path) → \(to.path)")
                    continue
                }
                // Molt already has the folder (it ran before MacSpace was gone): what it lacks comes over item by item, and nothing
                // of Molt's own is replaced. What both have stays in the earlier folder.
                for name in try manager.contentsOfDirectory(atPath: from.path) where !manager.fileExists(atPath: to.appendingPathComponent(name).path) {
                    try manager.moveItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name))
                    moved.append("\(from.appendingPathComponent(name).path) → \(to.appendingPathComponent(name).path)")
                }
                if (try? manager.contentsOfDirectory(atPath: from.path))?.isEmpty == true { try? manager.removeItem(at: from) }
            } catch {
                NSLog("Molt: could not move %@ to %@: %@", from.path, to.path, error.localizedDescription)
            }
        }
        return moved
    }

    public static let earlierDefaultsDomain = "com.macspace.app"

    static let importedKey = "molt.importedMacSpaceDefaults"

    /// Copies MacSpace's settings into Molt's defaults, once, never over a key Molt already has. Copied, not moved, so MacSpace keeps
    /// working until it is uninstalled. Returns how many keys came over.
    @discardableResult
    public static func importEarlierDefaults(into defaults: UserDefaults = .standard, earlierDomain: String = earlierDefaultsDomain) -> Int {
        guard !defaults.bool(forKey: importedKey) else { return 0 }
        defaults.set(true, forKey: importedKey)
        guard let keys = CFPreferencesCopyKeyList(earlierDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        else { return 0 }
        var count = 0
        for key in keys where defaults.object(forKey: key) == nil {
            guard let value = CFPreferencesCopyAppValue(key as CFString, earlierDomain as CFString) else { continue }
            defaults.set(value, forKey: key)
            count += 1
        }
        return count
    }
}
