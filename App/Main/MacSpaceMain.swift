import AppKit
import MacSpaceApp
import MacSpacePlatform
import SwiftUI

/// Closing the last window quits the app unless it keeps running (in the menu bar, or unseen in the background), where it goes on
/// with the modules' background tasks and automatic cleanup.
@MainActor
enum AppModel {
    static let host = ModuleHost()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Modules load as soon as the app starts, not when the window first appears: the window can open behind other apps or not at all
    /// (menu bar only), and nothing should wait for a click.
    func applicationDidFinishLaunching(_ notification: Notification) {
        GlyphCache.apply()
        // Before anything reads them: what MacSpace kept moves to Molt's folders, once MacSpace itself is gone.
        EarlierDataFolders.importEarlierDefaults()
        EarlierDataFolders.moveUserFolders()
        Self.askToUninstallMacSpace()
        // An app copied in by hand may be unknown to Launch Services, which makes the helper "not found" instead of "needs approval".
        if PrivilegedHelperInstaller.status == .notFound { PrivilegedHelperInstaller.registerAppWithLaunchServices() }
        // A copy with pieces missing (copied while it was being built) must not be given permissions: macOS would tie them to this
        // one build, and every update would lose them. Said once, plainly.
        if !CodeIntegrity.isIntact(Bundle.main.bundleURL) {
            let alert = AppAlert()
            alert.messageText = String(localized: "This copy of Molt is incomplete")
            alert.informativeText = String(localized: "Quit Molt and copy it again. Permissions given to this copy would be lost at the next update.")
            alert.alertStyle = .critical
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Continue"))
            ConfirmationAlert.standardize(alert)
            if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
        }
        #if MACSPACE_DEV
        ScreenshotLaunch.runIfRequested()
        #endif
        Task { @MainActor in await AppModel.host.start() }
        StatusItemController.shared.install(host: AppModel.host)
        AppNotifications.shared.install(host: AppModel.host)
        BackgroundPresence.shared.install()
        ClosedWindowRelease.shared.install()
        // Onboarding needs the window. SwiftUI leaves it closed when MacSpace is opened with arguments (`--onboarding`) or as a login
        // item, so it is opened here if it has not appeared by itself.
        if Onboarding.shared.isShowing {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if AppRouter.mainWindow == nil { AppRouter.shared.open() }
            }
        }
    }

    /// Molt was MacSpace. With both installed, two apps would switch the same settings and run two helpers, and MacSpace's own
    /// Uninstall is what puts back the settings it changed. So Molt asks for it, once per launch, and opens MacSpace to do it.
    @MainActor static func askToUninstallMacSpace() {
        guard let earlier = EarlierDataFolders.earlierAppPaths().first else { return }
        let alert = AppAlert()
        alert.messageText = String(localized: "Uninstall MacSpace first")
        alert.informativeText = String(localized: "Molt replaces MacSpace. Open MacSpace, choose About MacSpace, then Uninstall: it puts back the settings it changed. Then open Molt again.")
        alert.addButton(withTitle: String(localized: "Open MacSpace"))
        alert.addButton(withTitle: String(localized: "Later"))
        ConfirmationAlert.standardize(alert)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(fileURLWithPath: earlier)) }
    }

    /// Clicking the Dock icon with no window open opens it again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Task { @MainActor in AppRouter.shared.open() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !GeneralSettings.keepsRunning()
    }
}

@main
struct MacSpaceMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var host = AppModel.host
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        // The window opens at launch and is not restored.
        Window("Molt", id: MacSpaceWindow.glass) {
            ReleasableContent { MainView(host: host, updates: updates) }
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        // Opened by `molt://main` when no window has been open yet (`AppRouter.open`).
        .handlesExternalEvents(matching: [MacSpaceWindow.glass])
        .windowStyle(.plain)
        .windowBackgroundDragBehavior(.enabled)
        // The glass's default size (`Theme.defaultSize`); the glass is the window's frame.
        .defaultSize(width: 700, height: 490)
        .windowResizability(.contentMinSize)
        .commands {
            DesignCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About Molt") { AboutMolt.show(host: host) }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheck)
            }
        }

        // The design tools' windows (Design menu), in development builds only (`DesignTools`). SwiftUI lists every window scene in
        // the Window menu, open or not: each leaves out its item (`commandsRemoved()`), and the main window keeps it, with the app's
        // default menus.
        #if MACSPACE_DEV
        // Temporary: the Shader Studio (Design menu, ⌥⌘L).
        Window("Shader Studio", id: ColorLabView.windowID) {
            ColorLabView()
        }
        .commandsRemoved()
        .defaultSize(width: 520, height: 820)
        .handlesExternalEvents(matching: [])
        // Over the main window, so it stays in view while parts are picked there.
        .windowLevel(.floating)

        // Temporary: the tiles' type (Design menu, ⌥⌘T), over the main window so the dashboard shows each change.
        Window("Widget Type", id: WidgetTypeView.windowID) {
            WidgetTypeView()
        }
        .commandsRemoved()
        .defaultSize(width: 420, height: 640)
        .handlesExternalEvents(matching: [])
        .windowLevel(.floating)

        // Temporary: the charts' motion (Design menu, ⌥⌘G), over the main window so the charts show each change.
        Window("Chart Motion", id: ChartMotionView.windowID) {
            ChartMotionView()
        }
        .commandsRemoved()
        .defaultSize(width: 440, height: 760)
        .handlesExternalEvents(matching: [])
        .windowLevel(.floating)

        // The README's screenshots at full color (Design menu, ⌥⌘S).
        Window("Screenshots", id: ScreenshotToolView.windowID) {
            ScreenshotToolView()
        }
        .commandsRemoved()
        .defaultSize(width: 440, height: 560)
        .handlesExternalEvents(matching: [])
        .windowLevel(.floating)

        // Temporary: every text of the app, to propose better ones and export them (Design menu, ⌥⌘E).
        Window("Text Editor", id: TextEditorView.windowID) {
            TextEditorView()
        }
        .commandsRemoved()
        .defaultSize(width: 1000, height: 700)
        .handlesExternalEvents(matching: [])
        #endif
    }
}
