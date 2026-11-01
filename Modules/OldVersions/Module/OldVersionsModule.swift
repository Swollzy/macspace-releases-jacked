import AppKit
import Foundation
import MacSpacePlatform
import MacSpaceSdk

@objc(MacSpaceOldVersionsEntry)
public final class OldVersionsEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { OldVersionsModule() }
}

/// Old Versions: what earlier versions of Swollzy's apps (Wallflower, Burrow, Swivel and any other `com.swollzy.` app) left on this
/// Mac. Older second copies of an app, caches, saved windows, logs, crash reports, launch agents whose program is gone, and paths an
/// app's entry lists as safe (`KnownApps`). Settings and libraries are kept and shown as kept. Everything goes to the Trash, only
/// what the user leaves checked, after a confirmation.
///
/// Never part of automatic cleanup (`AutoCleaner.neverAutomatic`).
public struct OldVersionsModule: MacSpaceModule {
    static let maxAge: TimeInterval = 60

    /// The open apps' bundles and identifiers, from NSWorkspace.
    static let liveRunning: OldVersionScanner.RunningApps = {
        let apps = NSWorkspace.shared.runningApplications
        return (Set(apps.compactMap { $0.bundleURL?.standardizedFileURL.path }), Set(apps.compactMap(\.bundleIdentifier)))
    }

    private let store: OldVersionsStore
    private let cleaner: OldVersionCleaner

    public init() {
        self.init(cleaner: OldVersionCleaner(scanner: OldVersionScanner(running: OldVersionsModule.liveRunning)))
    }

    init(cleaner: OldVersionCleaner) {
        self.cleaner = cleaner
        let scanner = cleaner.scanner
        store = OldVersionsStore(read: { OldVersionsSnapshot(apps: scanner.scan()) })
    }

    public func invalidate() async { await store.invalidate() }

    public func tile(context: ModuleContext) async -> Tile {
        OldVersionsScreenBuilder.tile(await store.snapshot(maxAge: Self.maxAge))
    }

    public func status(context: ModuleContext) async -> (tile: Tile, screen: Screen)? {
        guard let last = await store.last else { return nil }
        return (OldVersionsScreenBuilder.tile(last), OldVersionsScreenBuilder.screen(last))
    }

    public func screen(context: ModuleContext) async -> Screen {
        OldVersionsScreenBuilder.screen(await store.snapshot(maxAge: Self.maxAge))
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        var result = handle(request, progress: progress)
        if result.refresh {
            await store.invalidate()
            let snapshot = await store.snapshot(maxAge: .infinity)
            result.presentation = ModulePresentation(tile: OldVersionsScreenBuilder.tile(snapshot), screen: OldVersionsScreenBuilder.screen(snapshot))
        }
        return result
    }

    private func handle(_ request: ActionRequest, progress: @escaping ProgressSink) -> ActionResult {
        switch request.actionID {
        case "trash":
            guard let bundleID = request.parameters["app"] else { return .failed(loc("Scan again first")) }
            let paths = Selection.ids(request.parameters["ids"]).compactMap { $0.hasPrefix("item:") ? String($0.dropFirst("item:".count)) : nil }
            guard !paths.isEmpty else { return .failed(loc("Check the items to move first")) }
            progress(ActionProgress(message: loc("Moving to Trash")))
            let outcome = cleaner.trash(paths, of: bundleID)
            var details = outcome.trashed.keys.sorted().map { "Moved to the Trash: \($0)" }
            details += outcome.refused.sorted { $0.key < $1.key }.map { "Kept \($0.key): \($0.value)" }
            guard !outcome.trashed.isEmpty else { return ActionResult(outcome: .failed, message: loc("Nothing was moved"), details: details, refresh: true) }
            let count = outcome.trashed.count
            // Space is freed when the Trash is emptied: not counted as freed here.
            return ActionResult(outcome: outcome.refused.isEmpty ? .succeeded : .needsAttention,
                                message: count == 1 ? loc("Moved 1 item to the Trash") : loc("Moved \(count) items to the Trash"), details: details, refresh: true)
        default:
            return .failed(loc("Unknown action \(request.actionID)."))
        }
    }
}
