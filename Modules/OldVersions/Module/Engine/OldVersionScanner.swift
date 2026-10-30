import Foundation
import MacSpacePlatform

/// A copy of an app in an Applications folder.
public struct AppCopy: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var bundleID: String
    /// `CFBundleShortVersionString`, "" when the copy has none.
    public var version: String
    /// `CFBundleVersion`, "" when the copy has none.
    public var build: String
    /// When its Info.plist last changed: the newest of two copies with the same version is the one installed last.
    public var modified: Date
    /// A copy found by its name only: an AppleScript app made with osacompile carries Script Editor's identifier, not the app's.
    public var matchedByName: Bool

    public init(path: String, bundleID: String, version: String, build: String, modified: Date, matchedByName: Bool = false) {
        self.path = path
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.modified = modified
        self.matchedByName = matchedByName
    }

    /// "0.3.0", "0.3.0 (12)", or "no version".
    public var versionText: String {
        if version.isEmpty { return build.isEmpty ? "no version" : build }
        return build.isEmpty || build == version ? version : "\(version) (\(build))"
    }
}

/// One thing an earlier version left that the page offers, checked or not.
public struct Finding: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A second copy of the app, older than the one kept.
        case oldCopy
        /// A folder named after the app in Caches or HTTPStorages.
        case cache
        /// The windows macOS remembers for the app (Saved Application State).
        case savedState
        /// Its folder in ~/Library/Logs.
        case logs
        /// A crash, hang or spin report in ~/Library/Logs/DiagnosticReports.
        case crashReport
        /// A path the app's entry says is safe to clear (`KnownApp.Clearable`), or left by an earlier version only.
        case clearable
        /// A launch agent of the app whose program is gone.
        case launchAgent
    }

    public var kind: Kind
    public var path: String
    public var bytes: UInt64
    public var note: String
    public var checked: Bool
    /// For a launch agent, its label.
    public var label: String?

    public init(kind: Kind, path: String, bytes: UInt64, note: String, checked: Bool = true, label: String? = nil) {
        self.kind = kind
        self.path = path
        self.bytes = bytes
        self.note = note
        self.checked = checked
        self.label = label
    }

    /// The row's id on the page and in a request.
    public var id: String { "item:\(path)" }
}

/// What one app has on this Mac: the copy kept, what can go, and what is kept for the user.
public struct AppReport: Codable, Equatable, Sendable {
    public var name: String
    public var bundleID: String
    /// The copy that stays: the open one, otherwise the newest version. Nil when the app is not installed, only its files are left.
    public var current: AppCopy?
    public var isRunning: Bool
    public var findings: [Finding]
    /// Settings and data that are there and stay, relative paths resolved, with their size.
    public var kept: [String: UInt64]

    public var bytes: UInt64 { findings.reduce(0) { $0 + $1.bytes } }
}

/// Finds what earlier versions of the known apps (`KnownApps`) left, strictly: only paths built from an app's own name and identifier
/// in a fixed set of places, never through a link, never a kept path or anything that holds one. Reads only; `OldVersionCleaner`
/// moves things, after finding them again.
public struct OldVersionScanner: Sendable {
    public typealias RunningApps = @Sendable () -> (paths: Set<String>, bundleIDs: Set<String>)

    public var home: String
    public var appFolders: [String]
    public var running: RunningApps
    /// Whether to add up folder sizes (off in tests that only look at paths).
    public var sizes: Bool

    public var library: String { (home as NSString).appendingPathComponent("Library") }

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, appFolders: [String]? = nil,
                running: @escaping RunningApps = { ([], []) }, sizes: Bool = true) {
        let resolved = (home as NSString).resolvingSymlinksInPath
        self.home = resolved
        self.appFolders = appFolders ?? ["/Applications", (resolved as NSString).appendingPathComponent("Applications")]
        self.running = running
        self.sizes = sizes
    }

    /// Crash reports are named "<process>-<date>.ips" (or "_" on older systems); these are the kinds macOS writes.
    static let reportExtensions: Set<String> = ["ips", "crash", "diag", "hang", "spin"]

    public func scan() -> [AppReport] {
        let copies = self.copies()
        let (runningPaths, runningIDs) = running()
        // The known apps, plus any app of the family on this Mac that has no entry of its own.
        var apps = KnownApps.all
        for copy in copies where KnownApps.isFamily(copy.bundleID) && !copy.matchedByName && !apps.contains(where: { $0.bundleID.caseInsensitiveCompare(copy.bundleID) == .orderedSame }) {
            apps.append(.generic(name: ((copy.path as NSString).lastPathComponent as NSString).deletingPathExtension, bundleID: copy.bundleID))
        }
        return apps.compactMap { app in
            let mine = copies.filter { copy in
                if copy.matchedByName { return app.scriptStandIn && Self.nameMatches(copy.path, app) }
                return copy.bundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame
            }
            let isRunning = runningIDs.contains { $0.caseInsensitiveCompare(app.bundleID) == .orderedSame }
            let report = self.report(app, copies: mine, runningPaths: runningPaths, isRunning: isRunning)
            return report.current == nil && report.findings.isEmpty && report.kept.isEmpty ? nil : report
        }
    }

    func report(_ app: KnownApp, copies: [AppCopy], runningPaths: Set<String>, isRunning: Bool) -> AppReport {
        let keeper = Self.keeper(copies, runningPaths: runningPaths)
        var findings: [Finding] = []
        // Open from somewhere MacSpace cannot see (a disk image, or a copy macOS moved aside to open it): which copy is in use is
        // unknown, so none is checked, and the cleaner refuses them all until the app is quit.
        let openElsewhere = isRunning && !copies.contains { runningPaths.contains($0.path) }
        for copy in copies where copy.path != keeper?.path && !runningPaths.contains(copy.path) {
            guard let bytes = measure(copy.path, inside: appFolders) else { continue }
            var note = keeper.map { "Version \(copy.versionText). Keeping \($0.versionText) in \(Self.folderName(of: $0.path))." } ?? ""
            // Newer than the copy that is open: the user opened an old build, and the newer one is most likely the one to keep.
            let newer = keeper.map { Self.compareVersions(copy.version, $0.version) == .orderedDescending } ?? false
            if newer { note = "Newer than the copy that is open. Quit \(app.name), open this one, and scan again to clear the older one instead." }
            if copy.matchedByName { note = "An AppleScript app named \(app.name), like \(app.name)'s old simple menu app. Check it only if it is that." }
            findings.append(Finding(kind: .oldCopy, path: copy.path, bytes: bytes, note: note,
                                    checked: !openElsewhere && !newer && !copy.matchedByName))
        }

        // Names are shared: another maker's "Swivel" may keep ~/Library/Logs/Swivel. Paths named after the app's name, not its
        // identifier, count only when the app is known to be here: a copy, or a file named by its identifier.
        let byID = ["Preferences/\(app.bundleID).plist", "Caches/\(app.bundleID)", "Application Support/\(app.bundleID)",
                    "Saved Application State/\(app.bundleID).savedState", "HTTPStorages/\(app.bundleID)", "Containers/\(app.bundleID)"]
        let present = copies.contains { !$0.matchedByName }
            || byID.contains { FileManager.default.fileExists(atPath: (library as NSString).appendingPathComponent($0)) }
        // Every kept path is protected; the ones named after the app's name are shown as its own only when it is here.
        let kept = app.allKept.map { (library as NSString).appendingPathComponent($0) }
        let shownKept = app.allKept.filter { present || !$0.lowercased().hasPrefix("application support/\(app.name.lowercased())") }
            .map { (library as NSString).appendingPathComponent($0) }
        func add(_ kind: Finding.Kind, _ relative: String, note: String, checked: Bool = true, label: String? = nil) {
            let path = (library as NSString).appendingPathComponent(relative)
            guard !Self.touchesKept(path, kept: kept), let bytes = measure(path, inside: [library]) else { return }
            // An open app is still using its caches and logs: listed, not checked, and refused until it is quit.
            findings.append(Finding(kind: kind, path: path, bytes: bytes, note: note, checked: checked && !isRunning, label: label))
        }

        add(.cache, "Caches/\(app.bundleID)", note: "Cache. \(app.name) makes a new one when it needs it.")
        if present { add(.cache, "Caches/\(app.name)", note: "Cache. \(app.name) makes a new one when it needs it.") }
        // Cookies and web storage: clearing them signs the app out of websites, so never checked.
        add(.cache, "HTTPStorages/\(app.bundleID)", note: "Cookies and web data. \(app.name) is signed out of websites without them.", checked: false)
        add(.savedState, "Saved Application State/\(app.bundleID).savedState", note: "The windows macOS reopens for \(app.name).")
        if present { add(.logs, "Logs/\(app.name)", note: "Logs.") }
        add(.logs, "Logs/\(app.bundleID)", note: "Logs.")
        if present {
            for file in contents("Logs/DiagnosticReports") where Self.isReport(file, of: app.name) {
                add(.crashReport, "Logs/DiagnosticReports/\(file)", note: "Crash report.")
            }
        }
        // Inside a kept folder only by name: the entry lists it on purpose.
        for clearable in app.clearable where present {
            let path = (library as NSString).appendingPathComponent(clearable.path)
            let keptElsewhere = kept.filter { !Self.isSame($0, (library as NSString).appendingPathComponent("Application Support/\(app.name)")) }
            guard !Self.touchesKept(path, kept: keptElsewhere), !Self.isAncestorOrSame(path, of: kept),
                  let bytes = measure(path, inside: [library]) else { continue }
            let note = clearable.staleSince.map { "Left by versions before \($0). " + clearable.note } ?? clearable.note
            findings.append(Finding(kind: .clearable, path: path, bytes: bytes, note: note, checked: clearable.checked && !isRunning))
        }
        for agent in launchAgents(of: app) {
            guard let bytes = measure(agent.path, inside: [library]) else { continue }
            findings.append(Finding(kind: .launchAgent, path: agent.path, bytes: bytes,
                                    note: "Starts \((agent.program as NSString).lastPathComponent) at login, which is no longer there.", label: agent.label))
        }

        var seen = Set<String>()
        findings = findings.filter { seen.insert($0.path.lowercased()).inserted }
        var keptSizes: [String: UInt64] = [:]
        for path in shownKept { if let bytes = measure(path, inside: [library]) { keptSizes[path] = bytes } }
        return AppReport(name: app.name, bundleID: app.bundleID, current: keeper, isRunning: isRunning, findings: findings, kept: keptSizes)
    }

    // MARK: Copies

    /// Every app directly in the Applications folders or one folder down, with its version. Links are not followed.
    func copies() -> [AppCopy] {
        var found: [AppCopy] = []
        for folder in appFolders {
            for name in contents(absolute: folder) {
                let path = (folder as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    if let copy = Self.read(path, topLevel: true) { found.append(copy) }
                } else if Self.isPlainFolder(path) {
                    for inner in contents(absolute: path) where inner.hasSuffix(".app") {
                        if let copy = Self.read((path as NSString).appendingPathComponent(inner), topLevel: false) { found.append(copy) }
                    }
                }
            }
        }
        return found
    }

    /// The app's copy, if `path` is one: family identifiers only, or an AppleScript app named exactly after a known app at the top of
    /// an Applications folder (Burrow's simple menu app).
    static func read(_ path: String, topLevel: Bool) -> AppCopy? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let bundleID = values["CFBundleIdentifier"] as? String ?? ""
        let modified = (try? FileManager.default.attributesOfItem(atPath: plist)[.modificationDate] as? Date) ?? .distantPast
        let version = values["CFBundleShortVersionString"] as? String ?? ""
        let build = values["CFBundleVersion"] as? String ?? ""
        if KnownApps.isFamily(bundleID) {
            return AppCopy(path: path, bundleID: bundleID, version: version, build: build, modified: modified)
        }
        guard topLevel, isScriptApp(bundleID), KnownApps.all.contains(where: { $0.scriptStandIn && nameMatches(path, $0) }) else { return nil }
        return AppCopy(path: path, bundleID: bundleID, version: version, build: build, modified: modified, matchedByName: true)
    }

    /// osacompile gives an app Script Editor's identifier, or none.
    static func isScriptApp(_ bundleID: String) -> Bool {
        bundleID.isEmpty || bundleID.hasPrefix("com.apple.ScriptEditor.id.")
    }

    static func nameMatches(_ path: String, _ app: KnownApp) -> Bool {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return ([app.name] + app.formerNames).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The copy that stays: an open one first, then a real build over an AppleScript stand-in, then the newest version, then the one in
    /// /Applications, then the one installed last. Nil when there is no copy.
    static func keeper(_ copies: [AppCopy], runningPaths: Set<String>) -> AppCopy? {
        copies.max { a, b in
            let ra = runningPaths.contains(a.path), rb = runningPaths.contains(b.path)
            if ra != rb { return rb }
            if a.matchedByName != b.matchedByName { return a.matchedByName }
            let byVersion = compareVersions(a.version, b.version)
            if byVersion != .orderedSame { return byVersion == .orderedAscending }
            let byBuild = compareVersions(a.build, b.build)
            if byBuild != .orderedSame { return byBuild == .orderedAscending }
            let sa = a.path.hasPrefix("/Applications/"), sb = b.path.hasPrefix("/Applications/")
            if sa != sb { return sb }
            if a.modified != b.modified { return a.modified < b.modified }
            return a.path > b.path
        }
    }

    /// "0.10.0" after "0.9.2"; a missing version before any.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        if a.isEmpty || b.isEmpty { return a.isEmpty == b.isEmpty ? .orderedSame : (a.isEmpty ? .orderedAscending : .orderedDescending) }
        return a.compare(b, options: .numeric)
    }

    static func folderName(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }

    static func isPlainFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && !path.hasSuffix(".app")
    }

    // MARK: Library

    static func isReport(_ file: String, of name: String) -> Bool {
        guard reportExtensions.contains((file as NSString).pathExtension.lowercased()) else { return false }
        let lower = file.lowercased(), prefix = name.lowercased()
        return lower.hasPrefix(prefix + "-") || lower.hasPrefix(prefix + "_") || lower.hasPrefix(prefix + ".")
    }

    struct Agent { var path: String; var label: String; var program: String }

    /// The app's launch agents in ~/Library/LaunchAgents whose program is gone: label under the app's identifier, program missing.
    func launchAgents(of app: KnownApp) -> [Agent] {
        let folder = (library as NSString).appendingPathComponent("LaunchAgents")
        return contents(absolute: folder).sorted().compactMap { name in
            guard name.hasSuffix(".plist") else { return nil }
            let path = (folder as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = values["Label"] as? String,
                  label.caseInsensitiveCompare(app.bundleID) == .orderedSame || label.lowercased().hasPrefix(app.bundleID.lowercased() + "."),
                  let program = (values["Program"] as? String) ?? (values["ProgramArguments"] as? [String])?.first,
                  program.hasPrefix("/"), !FileManager.default.fileExists(atPath: program) else { return nil }
            return Agent(path: path, label: label, program: program)
        }
    }

    // MARK: Paths

    /// Whether `path` is a kept path, inside one, or holds one.
    static func touchesKept(_ path: String, kept: [String]) -> Bool {
        kept.contains { isSame(path, $0) || isInside(path, $0) || isInside($0, path) }
    }

    static func isAncestorOrSame(_ path: String, of kept: [String]) -> Bool {
        kept.contains { isSame(path, $0) || isInside($0, path) }
    }

    /// Case-insensitive, as APFS is by default.
    static func isSame(_ a: String, _ b: String) -> Bool {
        (a as NSString).standardizingPath.lowercased() == (b as NSString).standardizingPath.lowercased()
    }

    /// Whether `path` is strictly inside `folder`: "/A/Foo/x" is in "/A/Foo", "/A/FooBar" is not.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let p = (path as NSString).standardizingPath.lowercased(), f = (folder as NSString).standardizingPath.lowercased()
        return p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    /// The size of what is at `path`, nil when nothing is there, when it or a folder above it inside the root is a link, or when it is
    /// not inside one of `roots`.
    func measure(_ path: String, inside roots: [String]) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return nil }
        let standardized = (path as NSString).standardizingPath
        guard roots.contains(where: { Self.isInside(standardized, $0) }),
              (standardized as NSString).resolvingSymlinksInPath == standardized else { return nil }
        guard sizes else { return 0 }
        if info.st_mode & S_IFMT == S_IFREG { return UInt64(max(0, info.st_blocks)) * 512 }
        return FileTreeSizer().size(at: URL(fileURLWithPath: path))?.bytes ?? 0
    }

    private func contents(_ relative: String) -> [String] {
        contents(absolute: (library as NSString).appendingPathComponent(relative))
    }

    private func contents(absolute: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: absolute)) ?? []
    }
}
