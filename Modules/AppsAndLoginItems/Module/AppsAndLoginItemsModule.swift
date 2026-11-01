import Foundation
import MacSpacePlatform
import MacSpaceSdk

@objc(MacSpaceAppsAndLoginItemsEntry)
public final class AppsAndLoginItemsEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { AppsAndLoginItemsModule() }
}

/// Apps & Login Items: the apps in /Applications and ~/Applications with their identifier and size, uninstalling one in two steps
/// (the app to the Trash, then the leftovers the user checks), and switching launch agents off and on again without touching their
/// files.
///
/// Never part of automatic cleanup: the manifest does not declare `autoClean`, and `autoClean(context:)` is left at the protocol's
/// default, which does nothing.
public struct AppsAndLoginItemsModule: MacSpaceModule {
    static let maxAge: TimeInterval = 120

    private let store: AppsStore
    private let uninstaller: AppUninstaller
    private let switcher: LaunchAgentSwitch
    private let orphans: OrphanFinder

    public init() {
        self.init(uninstaller: AppUninstaller(), switcher: LaunchAgentSwitch(), orphans: OrphanFinder())
    }

    init(uninstaller: AppUninstaller, switcher: LaunchAgentSwitch, orphans: OrphanFinder, store: AppsStore? = nil) {
        self.uninstaller = uninstaller
        self.switcher = switcher
        self.orphans = orphans
        self.store = store ?? AppsStore(read: { progress in
            AppsSnapshot.read(uninstaller: uninstaller, switcher: switcher, orphans: orphans, progress: progress)
        })
    }

    public func invalidate() async { await store.invalidate() }

    public func tile(context: ModuleContext) async -> Tile {
        AppsScreenBuilder.tile(await store.snapshot(maxAge: Self.maxAge))
    }

    public func tile(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Tile {
        AppsScreenBuilder.tile(await store.snapshot(maxAge: Self.maxAge, progress: progress))
    }

    public func status(context: ModuleContext) async -> (tile: Tile, screen: Screen)? {
        guard let last = await store.last else { return nil }
        return (AppsScreenBuilder.tile(last), AppsScreenBuilder.screen(last))
    }

    public func screen(context: ModuleContext) async -> Screen {
        AppsScreenBuilder.screen(await store.snapshot(maxAge: Self.maxAge))
    }

    public func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen {
        AppsScreenBuilder.screen(await store.snapshot(maxAge: Self.maxAge, progress: progress))
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        var result = await handle(request, progress: progress)
        if result.refresh {
            await store.invalidate()
            let snapshot = await store.snapshot(maxAge: .infinity)
            result.presentation = ModulePresentation(tile: AppsScreenBuilder.tile(snapshot), screen: AppsScreenBuilder.screen(snapshot))
        }
        return result
    }

    private func handle(_ request: ActionRequest, progress: @escaping ProgressSink) async -> ActionResult {
        switch request.actionID {
        case "trashApp":
            guard let path = request.parameters["path"], let app = await store.last?.apps.first(where: { $0.path == path }) else {
                return .failed(loc("That app is no longer there"))
            }
            progress(ActionProgress(message: loc("Moving to Trash")))
            do {
                _ = try await uninstaller.trashApp(app)
            } catch let failure as AppUninstaller.Failure {
                switch failure {
                case .running: return .failed(loc("Quit \(app.name) first"))
                case .protected: return .failed(loc("Molt doesn't move this app"))
                case .notInstalled: return ActionResult(outcome: .failed, message: loc("That app is no longer there"), refresh: true)
                case .stillInstalled, .trash: return .failed(loc("Couldn't move it to the Trash"), details: [failure.description])
                }
            } catch {
                return .failed(loc("Couldn't move it to the Trash"), details: [error.localizedDescription])
            }
            // Space is freed when the Trash is emptied: not counted as freed here.
            return ActionResult(outcome: .succeeded, message: loc("Moved \(app.name) to the Trash"),
                                details: ["Moved \(app.path) to the Trash. Its leftovers are offered on the page, none checked."], refresh: true)
        case "trashLeftovers":
            guard let bundleID = request.parameters["app"] else { return .failed(loc("Scan again first")) }
            let paths = Selection.ids(request.parameters["ids"]).compactMap { $0.hasPrefix("leftover:") ? String($0.dropFirst("leftover:".count)) : nil }
            guard !paths.isEmpty else { return .failed(loc("Check the files to move first")) }
            progress(ActionProgress(message: loc("Moving to Trash")))
            do {
                let outcome = try uninstaller.trashLeftovers(paths, of: bundleID)
                var details = outcome.trashed.keys.sorted().map { "Moved to the Trash: \($0)" }
                details += outcome.refused.sorted { $0.key < $1.key }.map { "Kept \($0.key): \($0.value)" }
                guard !outcome.trashed.isEmpty else { return ActionResult(outcome: .failed, message: loc("Nothing was moved"), details: details, refresh: true) }
                let count = outcome.trashed.count
                return ActionResult(outcome: outcome.refused.isEmpty ? .succeeded : .needsAttention,
                                    message: count == 1 ? loc("Moved 1 item to the Trash") : loc("Moved \(count) items to the Trash"), details: details, refresh: true)
            } catch {
                return ActionResult(outcome: .failed, message: loc("Couldn't move them to the Trash"), details: ["\(error)"], refresh: true)
            }
        case "trashOrphans":
            guard let owner = request.parameters["owner"] else { return .failed(loc("Scan again first")) }
            let paths = Selection.ids(request.parameters["ids"]).compactMap { $0.hasPrefix("orphan:") ? String($0.dropFirst("orphan:".count)) : nil }
            guard !paths.isEmpty else { return .failed(loc("Check the files to move first")) }
            progress(ActionProgress(message: loc("Moving to Trash")))
            let outcome = orphans.trash(paths, owner: owner, installed: AppInventory.apps(sizes: false), move: uninstaller.move)
            var details = outcome.trashed.keys.sorted().map { "Moved to the Trash: \($0)" }
            details += outcome.refused.sorted { $0.key < $1.key }.map { "Kept \($0.key): \($0.value)" }
            guard !outcome.trashed.isEmpty else { return ActionResult(outcome: .failed, message: loc("Nothing was moved"), details: details, refresh: true) }
            let count = outcome.trashed.count
            return ActionResult(outcome: outcome.refused.isEmpty ? .succeeded : .needsAttention,
                                message: count == 1 ? loc("Moved 1 item to the Trash") : loc("Moved \(count) items to the Trash"), details: details, refresh: true)
        case "keepLeftovers":
            guard let bundleID = request.parameters["app"] else { return .failed(loc("Scan again first")) }
            try? uninstaller.forget(bundleID)
            return ActionResult(outcome: .succeeded, message: "", refresh: true)
        case "setAgent":
            guard let label = request.parameters["label"] else { return .failed(loc("Scan again first")) }
            let on = request.parameters["value"] == "true"
            do {
                if on {
                    try switcher.enable(label: label, plistPath: request.parameters["plist"])
                } else {
                    guard let agent = await store.last?.agents.first(where: { $0.label == label }) else { return .failed(loc("Scan again first")) }
                    try switcher.disable(agent)
                }
            } catch {
                return ActionResult(outcome: .failed, message: on ? loc("Couldn't switch it on") : loc("Couldn't switch it off"), details: ["\(error)"], refresh: true)
            }
            return ActionResult(outcome: .succeeded, message: "", refresh: true)
        default:
            return .failed(loc("Unknown action \(request.actionID)."))
        }
    }

    /// Before MacSpace is uninstalled: every launch agent it switched off is switched back on. Apps and files it moved to the Trash
    /// are in the Trash, where the user can put them back with the Finder.
    public func prepareForUninstall(context: ModuleContext) async -> ActionResult {
        let failures = switcher.restoreAll()
        guard failures.isEmpty else {
            return .failed(loc("Couldn't switch some launch agents back on"), details: failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
        }
        return .succeeded("")
    }
}
