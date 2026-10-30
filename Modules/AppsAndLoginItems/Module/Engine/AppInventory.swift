import Foundation
import MacSpacePlatform

/// An app in /Applications or ~/Applications.
public struct InstalledApp: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var bundleID: String
    /// The name the Finder shows, without ".app".
    public var name: String
    public var bytes: UInt64

    public init(path: String, bundleID: String, name: String, bytes: UInt64) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.bytes = bytes
    }

    /// Apps MacSpace never offers to move: macOS's own (macOS protects most of them anyway) and MacSpace itself.
    public var isProtected: Bool {
        bundleID.hasPrefix("com.apple.") || bundleID.hasPrefix("com.macspace.")
    }
}

public enum AppInventory {
    public static func folders(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        ["/Applications", (home as NSString).appendingPathComponent("Applications")]
    }

    /// Every app directly in the folders, and in their subfolders one level down ("/Applications/Utilities", a vendor's folder),
    /// by name. Links are not followed. An app without a bundle identifier is left out: its leftovers could not be told apart.
    public static func apps(in folders: [String] = folders(), sizes: Bool = true) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        let manager = FileManager.default
        for folder in folders {
            for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = (folder as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    if let app = read(path, sizes: sizes) { apps.append(app) }
                } else if isPlainFolder(path) {
                    for inner in (try? manager.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                        if let app = read((path as NSString).appendingPathComponent(inner), sizes: sizes) { apps.append(app) }
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isPlainFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && !path.hasSuffix(".app")
    }

    static func read(_ path: String, sizes: Bool) -> InstalledApp? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = values["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let bytes = sizes ? FileTreeSizer().size(at: URL(fileURLWithPath: path))?.bytes ?? 0 : 0
        return InstalledApp(path: path, bundleID: bundleID, name: name, bytes: bytes)
    }
}

/// A file or folder an app left in ~/Library, matched to it strictly.
public struct Leftover: Codable, Equatable, Hashable, Sendable {
    public enum Place: String, Codable, Sendable, CaseIterable {
        case applicationSupport, caches, preferences, containers, savedState, webKit, groupContainers
    }

    public var path: String
    public var place: Place
    public var bytes: UInt64

    public init(path: String, place: Place, bytes: UInt64) {
        self.path = path
        self.place = place
        self.bytes = bytes
    }
}

/// Finds what an app left behind, strictly: a name in one of seven places in ~/Library that is the app's bundle identifier, or the
/// app's exact name (in Application Support and Caches only, where apps name folders after themselves). Nowhere else: never
/// Documents, Desktop, Pictures or Music, never a shared framework, never a container another app owns, never through a link.
public struct LeftoverFinder: Sendable {
    /// Names that are a vendor's, shared by its apps, never one app's.
    static let sharedNames: Set<String> = ["apple", "google", "microsoft", "adobe", "mozilla", "jetbrains", "oracle", "caches",
                                           "crashreporter", "com.apple", "frameworks", "plugins", "shared"]

    public var library: String

    /// The names of macOS's own apps, which a third-party app's name match must never reach ("Mail", "Notes").
    public var systemAppNames: Set<String>

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                systemAppNames: Set<String> = LeftoverFinder.macOSAppNames()) {
        library = ((home as NSString).appendingPathComponent("Library") as NSString).resolvingSymlinksInPath
        self.systemAppNames = Set(systemAppNames.map { $0.lowercased() })
    }

    public static func macOSAppNames() -> Set<String> {
        Set(AppInventory.apps(in: ["/System/Applications"], sizes: false).map(\.name))
    }

    /// What `app` left. `installed` are the apps still on the Mac: a name or identifier one of them also has is never matched.
    public func leftovers(bundleID: String, name: String, installed: [InstalledApp]) -> [Leftover] {
        guard Self.isUsableIdentifier(bundleID) else { return [] }
        let others = installed.filter { $0.bundleID != bundleID }
        let otherIDs = Set(others.map { $0.bundleID.lowercased() })
        let otherNames = Set(others.map { $0.name.lowercased() })
        guard !otherIDs.contains(bundleID.lowercased()) else { return [] }
        // The name is the app's alone only when no installed app shares its vendor or starts with its name: Firefox Developer
        // Edition reads Firefox's profiles in "Application Support/Firefox", a vendor's apps often share a folder named after one.
        let vendor = OrphanFinder.vendor(bundleID)
        let lowerName = name.lowercased()
        let nameShared = others.contains { OrphanFinder.vendor($0.bundleID) == vendor || $0.name.lowercased().hasPrefix(lowerName) }
        let nameUsable = name.count >= 3 && !Self.sharedNames.contains(lowerName) && !otherNames.contains(lowerName)
            && !systemAppNames.contains(lowerName) && !name.contains("/") && !nameShared

        var found: [Leftover] = []
        func add(_ relative: String, _ place: Leftover.Place) {
            let path = (library as NSString).appendingPathComponent(relative)
            guard let bytes = Self.measure(path, inside: library) else { return }
            found.append(Leftover(path: path, place: place, bytes: bytes))
        }
        add("Application Support/\(bundleID)", .applicationSupport)
        add("Caches/\(bundleID)", .caches)
        if nameUsable {
            add("Application Support/\(name)", .applicationSupport)
            add("Caches/\(name)", .caches)
        }
        add("Preferences/\(bundleID).plist", .preferences)
        for file in contents("Preferences/ByHost") where Self.isByHost(file, of: bundleID) { add("Preferences/ByHost/\(file)", .preferences) }
        if containerOwner("Containers/\(bundleID)") == bundleID { add("Containers/\(bundleID)", .containers) }
        add("Saved Application State/\(bundleID).savedState", .savedState)
        add("WebKit/\(bundleID)", .webKit)
        // A group container is the app's only when it is named after the app itself ("<team>.<bundle id>"); one shared by a
        // vendor's apps carries another name and is left alone.
        for folder in contents("Group Containers") where folder == bundleID || Self.isTeamPrefixed(folder, of: bundleID) {
            add("Group Containers/\(folder)", .groupContainers)
        }
        // A folder can match twice when the name equals the identifier.
        var seen = Set<String>()
        return found.filter { seen.insert($0.path.lowercased()).inserted }.sorted { $0.bytes > $1.bytes }
    }

    static func isUsableIdentifier(_ id: String) -> Bool {
        id.count >= 3 && id.contains(".") && !id.contains("/") && !id.hasPrefix("com.apple.") && !id.hasPrefix(".")
    }

    /// "com.vendor.App.0A1B2C3D-….plist" and the older "com.vendor.App.001122334455.plist" in ByHost.
    static func isByHost(_ file: String, of bundleID: String) -> Bool {
        guard file.hasPrefix(bundleID + "."), file.hasSuffix(".plist") else { return false }
        let host = file.dropFirst(bundleID.count + 1).dropLast(".plist".count)
        return !host.isEmpty && host.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// "ABCDE12345.com.vendor.App": a ten-character team identifier, then the bundle identifier exactly.
    static func isTeamPrefixed(_ folder: String, of bundleID: String) -> Bool {
        guard folder.hasSuffix("." + bundleID) else { return false }
        let team = folder.dropLast(bundleID.count + 1)
        return team.count == 10 && team.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    private func contents(_ relative: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: (library as NSString).appendingPathComponent(relative))) ?? []
    }

    /// The identifier macOS recorded for a container (`.com.apple.containermanagerd.metadata.plist`), nil when unreadable.
    func containerOwner(_ relative: String) -> String? {
        let url = URL(fileURLWithPath: (library as NSString).appendingPathComponent(relative))
            .appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return values["MCMMetadataIdentifier"] as? String
    }

    /// The size of what is at `path`, nil when nothing is there, when it is a link, or when it is not right inside `library`.
    static func measure(_ path: String, inside library: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return nil }
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix(library + "/"), (standardized as NSString).resolvingSymlinksInPath == standardized else { return nil }
        if info.st_mode & S_IFMT == S_IFREG { return UInt64(max(0, info.st_blocks)) * 512 }
        return FileTreeSizer().size(at: URL(fileURLWithPath: path))?.bytes ?? 0
    }
}
