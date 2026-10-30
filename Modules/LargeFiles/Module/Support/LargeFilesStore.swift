import Foundation
import MacSpaceSdk

/// The last scan, shared by the tile and the page: one scan at a time, and readers that arrive while it runs wait for it.
actor LargeFilesStore {
    typealias Scan = @Sendable (_ progress: @escaping LoadProgressSink) -> LargeFilesSnapshot

    private let scan: Scan
    private var snapshot: LargeFilesSnapshot?
    private var running: Task<LargeFilesSnapshot, Never>?
    private var relay: LoadProgressRelay?

    init(scan: @escaping Scan = { progress in LargeFileScanner(roots: .current()).scan(progress: progress) }) {
        self.scan = scan
    }

    /// The last scan if it is younger than `maxAge`, else a new one.
    func snapshot(maxAge: TimeInterval, progress: LoadProgressSink? = nil) async -> LargeFilesSnapshot {
        if let snapshot, Date().timeIntervalSince(snapshot.scanned) < maxAge { return snapshot }
        if let running {
            if let progress { relay?.attach(progress) }
            return await running.value
        }
        let relay = LoadProgressRelay()
        if let progress { relay.attach(progress) }
        self.relay = relay
        let scan = self.scan
        let task = Task.detached(priority: .utility) { scan { relay.report($0) } }
        running = task
        let result = await task.value
        snapshot = result
        running = nil
        self.relay = nil
        return result
    }

    /// The last scan, without scanning: nil before the first.
    var last: LargeFilesSnapshot? { snapshot }

    func invalidate() { snapshot = nil }

    /// Takes trashed files out of the last scan, so the page shows them gone without reading every folder again. A duplicate group
    /// left with one copy is no longer a group.
    func remove(_ paths: Set<String>) {
        guard var current = snapshot, !paths.isEmpty else { return }
        current.largeFiles.removeAll { paths.contains($0.path) }
        current.duplicates = current.duplicates.compactMap { group in
            var group = group
            // A kept copy is never trashed here; if it went some other way, the group waits for a new scan.
            guard !paths.contains(group.keeper.path) else { return nil }
            group.copies.removeAll { paths.contains($0.path) }
            return group.copies.isEmpty ? nil : group
        }
        snapshot = current
    }
}
