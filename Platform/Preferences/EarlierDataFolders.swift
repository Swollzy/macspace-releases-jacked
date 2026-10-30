import Foundation

/// Molt was MacSpace. Its folders kept MacSpace's name until the rename, and what is in them still matters: the settings Debloat and
/// Siri changed and how to put them back, the launch agents switched off, the cleanup history. At launch the app moves the user's
/// folders over and the helper moves the one for every user, once, and only where Molt has none of its own yet.
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
        guard !FileManager.default.fileExists(atPath: "/Applications/MacSpace.app") else { return [] }
        return move(in: library, only: ["Application Support/MacSpace"])
    }

    static func move(in library: URL, only: Set<String>? = nil) -> [String] {
        var moved: [String] = []
        let manager = FileManager.default
        for (earlier, current) in moves where only?.contains(earlier) ?? true {
            let from = library.appendingPathComponent(earlier), to = library.appendingPathComponent(current)
            var info = stat()
            // A real folder only, never a link, and never over a folder Molt already has.
            guard lstat(from.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, !manager.fileExists(atPath: to.path) else { continue }
            do {
                try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: from, to: to)
                moved.append("\(from.path) → \(to.path)")
            } catch {
                NSLog("Molt: could not move %@ to %@: %@", from.path, to.path, error.localizedDescription)
            }
        }
        return moved
    }
}
