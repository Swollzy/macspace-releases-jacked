import Foundation
import MacSpaceSdk

/// What the page shows: each known app on this Mac, what it left and what it keeps.
public struct OldVersionsSnapshot: Equatable, Sendable {
    public var apps: [AppReport]
    public var taken: Date

    public init(apps: [AppReport], taken: Date = Date()) {
        self.apps = apps
        self.taken = taken
    }

    public var bytes: UInt64 { apps.reduce(0) { $0 + $1.bytes } }
    public var count: Int { apps.reduce(0) { $0 + $1.findings.count } }
}

/// The last reading, shared by the tile and the page: one scan at a time, and readers that arrive while it runs wait for it.
actor OldVersionsStore {
    typealias Read = @Sendable () -> OldVersionsSnapshot

    private let read: Read
    private var snapshot: OldVersionsSnapshot?
    private var running: Task<OldVersionsSnapshot, Never>?
    /// Bumped by `invalidate()`: a read that started before is thrown away when it ends, so an action never shows the page from
    /// before it.
    private var generation = 0

    init(read: @escaping Read) { self.read = read }

    func snapshot(maxAge: TimeInterval) async -> OldVersionsSnapshot {
        if let snapshot, Date().timeIntervalSince(snapshot.taken) < maxAge { return snapshot }
        if let running { return await running.value }
        let read = self.read
        let started = generation
        let task = Task.detached(priority: .utility) { read() }
        running = task
        let result = await task.value
        guard started == generation else { return await snapshot(maxAge: maxAge) }
        snapshot = result
        running = nil
        return result
    }

    var last: OldVersionsSnapshot? { snapshot }

    func invalidate() {
        snapshot = nil
        running = nil
        generation += 1
    }
}
