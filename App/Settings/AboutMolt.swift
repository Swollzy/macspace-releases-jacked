import AppKit
import MacSpacePlatform
import MacSpaceSdk
import ServiceManagement
import SwiftUI

/// The application menu's About command, matching MacBat's native alert layout.
@MainActor
public enum AboutMolt {
    private static var uninstalling = false
    /// Molt is Swollzy's app, built on 1architect's MacSpace (MIT). The MIT license asks that the original copyright stays with the
    /// code, so the original author is credited here and in LICENSE and NOTICE.
    static let author = "Swollzy"
    static let basedOn = "MacSpace by Gio Mantovani/1architect (MIT License)"
    static let repository = "https://github.com/Swollzy/macspace-releases-jacked"

    static func makeAlert(bundle: Bundle = .main) -> AppAlert {
        let alert = AppAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Molt"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        alert.informativeText = [String(format: String(localized: "Version %@"), version), "",
                                 String(format: String(localized: "Made by\n%@"), author), "",
                                 String(format: String(localized: "Based on\n%@"), basedOn)].joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Uninstall…")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "GitHub"))
        return alert
    }

    public static func show(host: ModuleHost) {
        guard !uninstalling else { return }
        switch makeAlert().runModal() {
        case .alertSecondButtonReturn: confirmUninstall(host: host)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(URL(string: repository)!)
        default: break
        }
    }

    /// From About and from Settings › Uninstall. Asks first; "Keep my settings and history" is ticked, so only an explicit choice
    /// takes them.
    static func confirmUninstall(host: ModuleHost) {
        guard !uninstalling else { return }
        let alert = AppAlert()
        alert.messageText = String(localized: "Uninstall Molt?")
        alert.informativeText = String(localized: "Restores settings changed by Molt, removes its helper and login item, moves its caches and logs and the app to the Trash, and quits. Freed files cannot be restored.")
        alert.alertStyle = .warning
        let keep = NSButton(checkboxWithTitle: String(localized: "Keep my settings and history"), target: nil, action: nil)
        keep.state = .on
        alert.accessoryView = keep
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Uninstall")).hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let keepData = keep.state == .on
        uninstalling = true
        Task {
            defer { uninstalling = false }
            do { try await AppUninstaller.uninstall(host: host, keepData: keepData) }
            catch {
                let failure = AppAlert()
                failure.messageText = String(localized: "Couldn’t uninstall Molt")
                failure.informativeText = error.localizedDescription
                failure.addButton(withTitle: String(localized: "OK"))
                failure.runModal()
            }
        }
    }
}

/// An ordered pipeline: a failed restoration must prevent removal of the helper or app.
@MainActor
enum AppUninstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ steps: [@MainActor () async throws -> Void]) async throws {
        for step in steps { try await step() }
    }

    /// What Molt leaves in ~/Library besides the app. The caches, logs and saved windows always go; settings and history only
    /// when the user unticks "Keep my settings and history". All of it goes to the Trash.
    static func leftovers(keepData: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let id = "com.swollzy.molt"
        var paths = ["Caches/\(id)", "HTTPStorages/\(id)", "Saved Application State/\(id).savedState", "Logs/Molt"]
        if !keepData { paths += ["Application Support/Molt", "Preferences/\(id).plist"] }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return paths.map { library.appendingPathComponent($0) }.filter {
            // Never through a link: only Molt's own folders.
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    static func recycle(_ urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    static func uninstall(host: ModuleHost, keepData: Bool = true) async throws {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard app.pathExtension == "app" else { throw Failure(message: String(localized: "Move Molt to the Trash from Applications.")) }
        guard !host.isCleaning, !host.autoCleaner.isRunning, !host.handles.contains(where: \.isBusy) else {
            throw Failure(message: String(localized: "Wait for the current task to finish, then try again."))
        }
        for handle in host.handles { handle.beginUninstall() }
        await host.scheduler.stopAndWait()
        await host.autoCleaner.stopAndWait()
        for handle in host.handles { handle.setWatched(false) }
        do {
            try await run([
                {
                    // Include disabled modules: disabling a module does not undo its changes.
                    for handle in host.handles {
                        let result = await handle.prepareForUninstall()
                        guard result.outcome == .succeeded else {
                            throw Failure(message: ([handle.manifest.name + ": " + result.message] + result.details).joined(separator: "\n"))
                        }
                    }
                },
                {
                    if SMAppService.mainApp.status == .enabled { try await SMAppService.mainApp.unregister() }
                    if PrivilegedHelperInstaller.status != .notRegistered && PrivilegedHelperInstaller.status != .notFound {
                        try await PrivilegedHelperInstaller.unregister()
                    }
                },
                {
                    if !keepData, let id = Bundle.main.bundleIdentifier {
                        UserDefaults.standard.removePersistentDomain(forName: id)
                        CFPreferencesAppSynchronize(id as CFString)
                    }
                    // Leftovers that won't move are not worth stopping for: the app still goes.
                    try? await recycle(leftovers(keepData: keepData))
                    try await recycle([app])
                }
            ])
            NSApp.terminate(nil)
        } catch {
            for handle in host.handles {
                handle.cancelUninstall()
                handle.setWatched(true)
            }
            host.applySchedule()
            host.autoCleaner.resume()
            throw error
        }
    }
}
