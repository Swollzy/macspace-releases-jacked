import Foundation
import MacSpaceSdk

/// What the page shows: the apps, the apps moved to the Trash with what they left, and the launch agents.
public struct AppsSnapshot: Equatable, Sendable {
    public struct Pending: Equatable, Sendable {
        public var app: AppUninstaller.Removed
        public var leftovers: [Leftover]
    }

    public var apps: [InstalledApp]
    public var pending: [Pending]
    /// What apps no longer on the Mac left, MacSpace's own removals aside (they are in `pending`).
    public var orphans: [OrphanFinder.Orphan]
    public var agents: [LaunchAgent]
    /// Agents MacSpace switched off that are no longer in their folder: listed so they can still be switched back on.
    public var journaled: [DisabledAgentsJournal.Entry]
    public var taken: Date

    public init(apps: [InstalledApp], pending: [Pending], orphans: [OrphanFinder.Orphan] = [], agents: [LaunchAgent],
                journaled: [DisabledAgentsJournal.Entry], taken: Date = Date()) {
        self.apps = apps
        self.pending = pending
        self.orphans = orphans
        self.agents = agents
        self.journaled = journaled
        self.taken = taken
    }

    public var appBytes: UInt64 { apps.reduce(0) { $0 + $1.bytes } }

    /// Orphans grouped by the identifier they are named by, largest group first.
    public var orphanGroups: [(owner: String, items: [Leftover])] {
        Dictionary(grouping: orphans, by: \.owner).map { ($0.key, $0.value.map(\.leftover)) }
            .sorted { a, b in
                let x = a.items.reduce(0) { $0 + $1.bytes }, y = b.items.reduce(0) { $0 + $1.bytes }
                return x != y ? x > y : a.owner < b.owner
            }
    }

    static func read(uninstaller: AppUninstaller, switcher: LaunchAgentSwitch, orphans finder: OrphanFinder, progress: LoadProgressSink) -> AppsSnapshot {
        progress(0.05)
        let apps = AppInventory.apps()
        progress(0.7)
        let pending = uninstaller.pending().map { Pending(app: $0.app, leftovers: $0.leftovers) }
        let pendingPaths = Set(pending.flatMap { $0.leftovers.map(\.path) })
        let orphans = finder.orphans(installed: apps).filter { !pendingPaths.contains($0.leftover.path) }
        progress(0.9)
        let agents = LaunchAgentInventory.agents(disabled: switcher.disabledLabels())
        let listed = Set(agents.map(\.label))
        let journaled = switcher.journal.entries().filter { !listed.contains($0.label) }
        progress(1)
        return AppsSnapshot(apps: apps, pending: pending, orphans: orphans, agents: agents, journaled: journaled)
    }
}

/// The last reading, shared by the tile and the page.
actor AppsStore {
    typealias Read = @Sendable (_ progress: @escaping LoadProgressSink) -> AppsSnapshot

    private let read: Read
    private var snapshot: AppsSnapshot?
    private var running: Task<AppsSnapshot, Never>?
    /// Bumped by `invalidate()`: a read that started before is thrown away when it ends, so an action never shows the page from
    /// before it.
    private var generation = 0

    init(read: @escaping Read) { self.read = read }

    func snapshot(maxAge: TimeInterval, progress: LoadProgressSink? = nil) async -> AppsSnapshot {
        if let snapshot, Date().timeIntervalSince(snapshot.taken) < maxAge { return snapshot }
        if let running { return await running.value }
        let read = self.read
        let sink: LoadProgressSink = progress ?? { _ in }
        let started = generation
        let task = Task.detached(priority: .utility) { read(sink) }
        running = task
        let result = await task.value
        guard started == generation else { return await snapshot(maxAge: maxAge, progress: progress) }
        snapshot = result
        running = nil
        return result
    }

    var last: AppsSnapshot? { snapshot }

    func invalidate() {
        snapshot = nil
        running = nil
        generation += 1
    }
}
