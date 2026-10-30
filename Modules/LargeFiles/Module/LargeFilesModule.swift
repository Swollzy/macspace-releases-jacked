import Foundation
import MacSpacePlatform
import MacSpaceSdk

@objc(MacSpaceLargeFilesEntry)
public final class LargeFilesEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { LargeFilesModule() }
}

/// Large Files: files over 100 MB and duplicate files in the user's own folders, and moving the ones the user checks to the Trash.
///
/// Never part of automatic cleanup: the manifest does not declare `autoClean` and `autoClean(context:)` is left at the protocol's
/// default, which frees nothing. Nothing is ever deleted; files go to the Trash, which the user empties.
public struct LargeFilesModule: MacSpaceModule {
    /// A scan reads every file in the user's folders and hashes possible duplicates: kept for ten minutes unless the user refreshes.
    static let maxAge: TimeInterval = 600

    private let store: LargeFilesStore
    private let trasher: @Sendable () -> FileTrasher

    public init() {
        self.init(store: LargeFilesStore(), trasher: { FileTrasher(roots: .current()) })
    }

    init(store: LargeFilesStore, trasher: @escaping @Sendable () -> FileTrasher) {
        self.store = store
        self.trasher = trasher
    }

    public func invalidate() async { await store.invalidate() }

    public func tile(context: ModuleContext) async -> Tile {
        LargeFilesScreenBuilder.tile(await store.snapshot(maxAge: Self.maxAge))
    }

    public func tile(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Tile {
        LargeFilesScreenBuilder.tile(await store.snapshot(maxAge: Self.maxAge, progress: progress))
    }

    public func status(context: ModuleContext) async -> (tile: Tile, screen: Screen)? {
        guard let last = await store.last else { return nil }
        return (LargeFilesScreenBuilder.tile(last), LargeFilesScreenBuilder.screen(last))
    }

    public func screen(context: ModuleContext) async -> Screen {
        LargeFilesScreenBuilder.screen(await store.snapshot(maxAge: Self.maxAge))
    }

    public func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen {
        LargeFilesScreenBuilder.screen(await store.snapshot(maxAge: Self.maxAge, progress: progress))
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        guard let snapshot = await store.last else { return .failed(loc("Scan again first")) }
        let paths = Selection.ids(request.parameters["ids"]).compactMap(LargeFilesScreenBuilder.path(of:))
        guard !paths.isEmpty else { return .failed(loc("Check the files to move first")) }
        progress(ActionProgress(message: loc("Moving to Trash")))
        let outcome: FileTrasher.Outcome
        switch request.actionID {
        case "trashLarge":
            outcome = trasher().trashLarge(paths, snapshot: snapshot)
        case "trashDuplicates":
            guard let group = snapshot.duplicates.first(where: { $0.hash == request.parameters["group"] }) else { return .failed(loc("Scan again first")) }
            outcome = trasher().trashDuplicates(paths, group: group)
        default:
            return .failed(loc("Unknown action \(request.actionID)."))
        }
        await store.remove(Set(outcome.trashed.keys))
        var result = Self.result(outcome)
        if let last = await store.last {
            result.presentation = ModulePresentation(tile: LargeFilesScreenBuilder.tile(last), screen: LargeFilesScreenBuilder.screen(last))
        }
        return result
    }

    /// What a Move to Trash did. The space is freed only when the user empties the Trash, so it is not reported as freed
    /// (`freedBytes` stays nil) and nothing goes to the cleanup history.
    static func result(_ outcome: FileTrasher.Outcome) -> ActionResult {
        var details = outcome.trashed.keys.sorted().map { "Moved to the Trash: \($0)" }
        details += outcome.refused.sorted { $0.key < $1.key }.map { "Kept \($0.key): \($0.value)" }
        let count = outcome.trashed.count
        if count == 0 { return ActionResult(outcome: .failed, message: loc("Nothing was moved"), details: details, refresh: true) }
        let message = count == 1 ? loc("Moved 1 file to the Trash") : loc("Moved \(count) files to the Trash")
        return ActionResult(outcome: outcome.refused.isEmpty ? .succeeded : .needsAttention, message: message, details: details, refresh: true)
    }
}
