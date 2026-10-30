import Foundation
import MacSpacePlatform

/// What apps no longer on the Mac left in ~/Library, including what they brought with them (a vendor's updater, its helpers): items
/// named by a bundle identifier, in the same seven places as `LeftoverFinder`, whose owner is gone.
///
/// Strict, so that nothing still in use is offered. An item counts only when its name is a bundle identifier (reverse DNS, at least
/// three parts) that is not macOS's, that no installed app or any bundle inside one (helpers, extensions, frameworks) has, that Launch
/// Services cannot find an app for anywhere on the Mac, and whose vendor (its first two parts, "com.google") has no installed app
/// at all: a vendor's shared updater stays while one of its apps is installed. Names alone are never matched.
public struct OrphanFinder: Sendable {
    public struct Orphan: Codable, Equatable, Hashable, Sendable {
        /// The bundle identifier the item is named by: the app or component it belonged to.
        public var owner: String
        public var leftover: Leftover
    }

    public var library: String
    /// Whether Launch Services knows an app with this identifier anywhere on the Mac.
    public var appExists: @Sendable (String) -> Bool

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                appExists: @escaping @Sendable (String) -> Bool = { AppNames.Lookup.live.appURL($0) != nil }) {
        library = ((home as NSString).appendingPathComponent("Library") as NSString).resolvingSymlinksInPath
        self.appExists = appExists
    }

    /// Every bundle identifier of the installed apps and of the bundles inside them, lowercased.
    public static func installedIdentifiers(_ apps: [InstalledApp]) -> Set<String> {
        var ids = Set(apps.map { $0.bundleID.lowercased() })
        let manager = FileManager.default
        for app in apps {
            let contents = URL(fileURLWithPath: app.path).appendingPathComponent("Contents")
            guard let walk = manager.enumerator(at: contents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk {
                if walk.level > 6 { walk.skipDescendants(); continue }
                guard url.lastPathComponent == "Info.plist",
                      let data = try? Data(contentsOf: url),
                      let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let id = values["CFBundleIdentifier"] as? String else { continue }
                ids.insert(id.lowercased())
            }
        }
        return ids
    }

    /// The vendor part of an identifier: "com.google" for "com.google.Keystone.Agent".
    static func vendor(_ id: String) -> String {
        id.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
    }

    /// The bundle identifier an item in `place` is named by, or nil when its name is not one.
    static func owner(of name: String, in place: Leftover.Place) -> String? {
        var id = name
        switch place {
        case .preferences:
            guard id.hasSuffix(".plist") else { return nil }
            id = String(id.dropLast(".plist".count))
        case .savedState:
            guard id.hasSuffix(".savedState") else { return nil }
            id = String(id.dropLast(".savedState".count))
        case .groupContainers:
            // "<team>.group.com.vendor.App", "group.com.vendor.App" or "<team>.com.vendor.App": the identifier after both prefixes.
            if let dot = id.firstIndex(of: "."), id.distance(from: id.startIndex, to: dot) == 10,
               id[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) { id = String(id[id.index(after: dot)...]) }
            for prefix in ["group.", "groups."] where id.lowercased().hasPrefix(prefix) { id = String(id.dropFirst(prefix.count)) }
        default:
            break
        }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }), parts.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              parts[0].count >= 2, parts[0].allSatisfy(\.isLetter) else { return nil }
        let lower = id.lowercased()
        // macOS's own data is never an orphan, under any prefix ("243LU875E5.groups.com.apple.podcasts"), nor that of the parts of
        // macOS not named com.apple (Shortcuts' library is "group.is.workflow.my.app", printing is "org.cups").
        guard !lower.contains("com.apple."), !lower.hasPrefix("com.macspace."),
              !Self.systemPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return id
    }

    /// Identifiers of parts of macOS that are not named com.apple.
    static let systemPrefixes = ["is.workflow.", "org.cups.", "com.openssh."]

    /// Where macOS keeps its own apps: their identifiers count as installed, so nothing named after them is an orphan.
    static let systemAppFolders = ["/System/Applications", "/System/Library/CoreServices", "/System/Applications/Utilities"]

    static let places: [(String, Leftover.Place)] = [
        ("Application Support", .applicationSupport), ("Caches", .caches), ("Preferences", .preferences), ("Containers", .containers),
        ("Saved Application State", .savedState), ("WebKit", .webKit), ("Group Containers", .groupContainers),
    ]

    public func orphans(installed apps: [InstalledApp], installedIDs: Set<String>? = nil) -> [Orphan] {
        var ids = installedIDs ?? Self.installedIdentifiers(apps)
        // Only their own identifiers: walking inside every system app on each scan is slow, and com.apple is refused by name anyway.
        if installedIDs == nil { ids.formUnion(AppInventory.apps(in: Self.systemAppFolders, sizes: false).map { $0.bundleID.lowercased() }) }
        let vendors = Set(ids.map(Self.vendor))
        var orphans: [Orphan] = []
        var verdicts: [String: Bool] = [:]
        for (folder, place) in Self.places {
            let directory = (library as NSString).appendingPathComponent(folder)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
                guard var owner = Self.owner(of: name, in: place) else { continue }
                if place == .containers {
                    // A container is the app macOS recorded for it, whatever its folder is called.
                    guard let recorded = LeftoverFinder(home: (library as NSString).deletingLastPathComponent, systemAppNames: [])
                        .containerOwner("Containers/\(name)"), recorded.lowercased() == owner.lowercased() else { continue }
                    owner = recorded
                }
                let key = owner.lowercased()
                let gone: Bool
                if let known = verdicts[key] { gone = known } else {
                    gone = !ids.contains(key) && !vendors.contains(Self.vendor(owner)) && !appExists(owner)
                    verdicts[key] = gone
                }
                guard gone else { continue }
                let path = (directory as NSString).appendingPathComponent(name)
                guard let bytes = LeftoverFinder.measure(path, inside: library) else { continue }
                orphans.append(Orphan(owner: owner, leftover: Leftover(path: path, place: place, bytes: bytes)))
            }
        }
        return orphans.sorted { $0.leftover.bytes != $1.leftover.bytes ? $0.leftover.bytes > $1.leftover.bytes : $0.leftover.path < $1.leftover.path }
    }

    /// Moves the checked orphans of `owner` to the Trash, each only if a new search still finds it as that owner's.
    public func trash(_ paths: [String], owner: String, installed apps: [InstalledApp], move: AppUninstaller.Mover) -> (trashed: [String: String], refused: [String: String]) {
        let current = Dictionary(orphans(installed: apps).filter { $0.owner == owner }.map { ($0.leftover.path, $0) }, uniquingKeysWith: { a, _ in a })
        var trashed: [String: String] = [:], refused: [String: String] = [:]
        for path in Set(paths).sorted() {
            guard current[path] != nil else { refused[path] = "Not left by an app that is gone."; continue }
            do { trashed[path] = try move(URL(fileURLWithPath: path))?.path ?? "" } catch { refused[path] = error.localizedDescription }
        }
        return (trashed, refused)
    }
}

extension LaunchAgent {
    /// The program the agent starts is no longer on the Mac: what an app removed without its agent leaves.
    public var programMissing: Bool {
        guard let program, program.hasPrefix("/") else { return false }
        return !FileManager.default.fileExists(atPath: program)
    }
}
