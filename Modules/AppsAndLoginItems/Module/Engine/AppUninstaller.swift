import AppKit
import Foundation

/// Uninstalling in two steps, both to the Trash: first the app itself, then, offered afterwards, what it left in ~/Library
/// (`LeftoverFinder`). Nothing is ever deleted permanently. The apps moved and their leftovers not yet dealt with are kept in a
/// journal, so the second step is still offered after a restart of MacSpace.
public struct AppUninstaller: Sendable {
    public struct Removed: Codable, Equatable, Sendable {
        public var bundleID: String
        public var name: String
        /// Where the app was.
        public var path: String
        public var date: Date
        /// Where the Trash put it, when known.
        public var trashedPath: String?
    }

    public typealias Recycler = @Sendable (_ url: URL) async throws -> URL?
    public typealias Mover = @Sendable (_ url: URL) throws -> URL?
    public typealias IsRunning = @Sendable (_ bundleID: String) -> Bool

    /// Finder's own Move to Trash, which asks for an administrator's password when the app belongs to another user (an installer's).
    public static let liveRecycler: Recycler = { url in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            NSWorkspace.shared.recycle([url]) { moved, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: moved[url]) }
            }
        }
    }

    public static let liveMover: Mover = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    public static let liveIsRunning: IsRunning = { bundleID in
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public static let journalURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSpace/removed-apps.json")

    public var journalURL: URL
    public var finder: LeftoverFinder
    public var installed: @Sendable () -> [InstalledApp]
    public var recycle: Recycler
    public var move: Mover
    public var isRunning: IsRunning

    public init(journalURL: URL = AppUninstaller.journalURL, finder: LeftoverFinder = LeftoverFinder(),
                installed: @escaping @Sendable () -> [InstalledApp] = { AppInventory.apps(sizes: false) },
                recycle: @escaping Recycler = AppUninstaller.liveRecycler, move: @escaping Mover = AppUninstaller.liveMover,
                isRunning: @escaping IsRunning = AppUninstaller.liveIsRunning) {
        self.journalURL = journalURL
        self.finder = finder
        self.installed = installed
        self.recycle = recycle
        self.move = move
        self.isRunning = isRunning
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case protected
        case running
        case notInstalled
        case stillInstalled
        case trash(String)

        public var description: String {
            switch self {
            case .protected: return "macOS's own apps and MacSpace are not moved."
            case .running: return "The app is open."
            case .notInstalled: return "The app is no longer there."
            case .stillInstalled: return "The app is installed again, so its files are in use."
            case let .trash(message): return message
            }
        }
    }

    /// Step one: the app, and only the app, to the Trash. Its leftovers are offered afterwards, never moved with it.
    public func trashApp(_ app: InstalledApp) async throws -> Removed {
        guard !app.isProtected else { throw Failure.protected }
        guard let current = installed().first(where: { $0.path == app.path }), current.bundleID == app.bundleID else { throw Failure.notInstalled }
        guard !isRunning(app.bundleID) else { throw Failure.running }
        let trashed: URL?
        do { trashed = try await recycle(URL(fileURLWithPath: app.path)) } catch { throw Failure.trash(error.localizedDescription) }
        let removed = Removed(bundleID: app.bundleID, name: app.name, path: app.path, date: Date(), trashedPath: trashed?.path)
        try? save(removed: self.removed().filter { $0.bundleID != app.bundleID } + [removed])
        return removed
    }

    /// The apps moved to the Trash whose leftovers have not been dealt with, with what is still there of them. An app installed
    /// again is dropped: its files are its own again.
    public func pending() -> [(app: Removed, leftovers: [Leftover])] {
        let apps = installed()
        return self.removed().compactMap { removed in
            guard !apps.contains(where: { $0.bundleID == removed.bundleID }) else { return nil }
            return (removed, finder.leftovers(bundleID: removed.bundleID, name: removed.name, installed: apps))
        }
    }

    /// Step two: the leftovers the user checked, to the Trash. Each is found again first, by the same strict rules: a path the
    /// finder no longer returns for that app is refused.
    public func trashLeftovers(_ paths: [String], of bundleID: String) throws -> (trashed: [String: String], refused: [String: String], bytes: UInt64) {
        guard let removed = self.removed().first(where: { $0.bundleID == bundleID }) else { throw Failure.notInstalled }
        let apps = installed()
        guard !apps.contains(where: { $0.bundleID == bundleID }) else { throw Failure.stillInstalled }
        let current = Dictionary(finder.leftovers(bundleID: bundleID, name: removed.name, installed: apps).map { ($0.path, $0) },
                                 uniquingKeysWith: { a, _ in a })
        var trashed: [String: String] = [:], refused: [String: String] = [:]
        var bytes: UInt64 = 0
        for path in Set(paths).sorted() {
            guard let leftover = current[path] else { refused[path] = "Not one of this app's files."; continue }
            do {
                trashed[path] = try move(URL(fileURLWithPath: path))?.path ?? ""
                bytes += leftover.bytes
            } catch {
                refused[path] = error.localizedDescription
            }
        }
        // Done with the app once nothing of it is left.
        if finder.leftovers(bundleID: bundleID, name: removed.name, installed: apps).isEmpty { try? forget(bundleID) }
        return (trashed, refused, bytes)
    }

    /// Stops offering an app's leftovers (the user chose to keep them, or none are left).
    public func forget(_ bundleID: String) throws {
        try save(removed: removed().filter { $0.bundleID != bundleID })
    }

    public func removed() -> [Removed] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: journalURL)).flatMap { try? decoder.decode([Removed].self, from: $0) } ?? []
    }

    private func save(removed: [Removed]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(removed).write(to: journalURL, options: .atomic)
    }
}
