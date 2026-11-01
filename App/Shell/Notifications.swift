import AppKit
import Foundation
import MacSpacePlatform
@preconcurrency import UserNotifications

/// MacSpace's own notifications in Notification Center, only for what happens while the user is not looking: automatic cleanup that
/// freed something, an action that finished while MacSpace was in the background, and the disk running low. Clicking one opens
/// MacSpace on the page it is about. The modules' own notifications (Debloat, Siri) are posted here too (`ModuleServices.notify`),
/// with their module's id, and open its page.
///
/// macOS asks once whether MacSpace may notify, the first time it has something to say.
@MainActor
public final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = AppNotifications()

    /// What MacSpace notifies about, each one switched on or off in Settings.
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case automaticCleanup
        case actionFinished
        case lowSpace

        public var id: String { rawValue }
        var key: String { "notify.\(rawValue)" }

        public var title: String {
            switch self {
            case .automaticCleanup: return String(localized: "When automatic cleanup frees space")
            case .actionFinished: return String(localized: "When a cleanup finishes in the background")
            case .lowSpace: return String(localized: "When the disk is almost full")
            }
        }
    }

    /// Automatic cleanup that freed less is not worth a notification.
    static let cleanupThreshold: UInt64 = 100_000_000
    /// An action shorter than this ends before anyone has switched away: no notification.
    static let actionThreshold: TimeInterval = 8
    static let lowSpaceInterval: TimeInterval = 24 * 3600
    static let lowSpaceLastKey = "notify.lowSpace.last"
    /// The emergency purge runs at most this often while the disk stays low.
    static let emergencyInterval: TimeInterval = 3600
    static let emergencyLastKey = "lowDisk.emergency.last"
    /// Settings' switch for the emergency purge; on unless the user turns it off.
    public nonisolated static let emergencyPurgeKey = "lowDisk.emergencyPurge"
    /// The one module the emergency purge runs: Other System Files, whose cleanup is macOS's own purge of purgeable files.
    nonisolated static let emergencyModuleID = "com.macspace.other-system-files"

    private let defaults: UserDefaults
    private var lowSpaceWatch: Task<Void, Never>?
    private weak var host: ModuleHost?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isOn(_ kind: Kind) -> Bool { defaults.object(forKey: kind.key) as? Bool ?? true }
    public func set(_ kind: Kind, on: Bool) { defaults.set(on, forKey: kind.key) }

    /// Takes the clicks on MacSpace's notifications, and starts watching the disk.
    public func install(host: ModuleHost) {
        self.host = host
        guard Self.canNotify else { return }
        UNUserNotificationCenter.current().delegate = self
        guard lowSpaceWatch == nil else { return }
        lowSpaceWatch = Task { [weak self] in
            // A while after launch, so the modules have their figures.
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                await self?.checkLowSpace()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    /// Only the app posts: the CLI and the tests have no bundle to notify from.
    nonisolated static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: What MacSpace says

    /// After automatic cleanup: what it freed, and which modules took part.
    func automaticCleanupFinished(freed: UInt64, modules: [String]) {
        guard freed >= Self.cleanupThreshold, isOn(.automaticCleanup) else { return }
        let names = ListFormatter.localizedString(byJoining: modules)
        post(.automaticCleanup, title: String(localized: "Molt freed \(ByteFormat.string(freed))"),
             body: modules.isEmpty ? String(localized: "Automatic cleanup") : String(localized: "Automatic cleanup: \(names)"), destination: "storage")
    }

    /// After an action the user started, when it took a while and MacSpace is no longer in front.
    func actionFinished(module: ModuleHandle, message: String, took: TimeInterval) {
        guard took >= Self.actionThreshold, !NSApp.isActive, isOn(.actionFinished), !message.isEmpty else { return }
        post(.actionFinished, title: module.manifest.name, body: message, destination: "module:\(module.id)")
    }

    public var emergencyPurgeEnabled: Bool { defaults.object(forKey: Self.emergencyPurgeKey) as? Bool ?? true }

    /// The disk is low (`LowDiskPolicy`): the emergency purge first, then, at most once a day, a notification saying what MacSpace
    /// can free and offering the dry-run report. Only while MacSpace is open: with the app closed nothing watches the disk.
    ///
    /// The emergency purge is the only thing done without the user, and it is only macOS's own purge of the files apps marked
    /// purgeable (Other System Files' cleanup). Never the user's files, snapshots, backups, duplicates, large files or app leftovers.
    func checkLowSpace(now: Date = Date()) async {
        let reading = await Task.detached(priority: .utility) { () -> (available: UInt64, capacity: UInt64)? in
            let values = try? URL(fileURLWithPath: DataVolume.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            guard let capacity = values?.volumeTotalCapacity, let available = values?.volumeAvailableCapacityForImportantUsage, available >= 0 else { return nil }
            return (UInt64(available), UInt64(capacity))
        }.value
        guard let reading, Self.isLow(available: reading.available, capacity: reading.capacity) else { return }
        let purged = await emergencyPurge(now: now)
        guard isOn(.lowSpace) else { return }
        if let last = defaults.object(forKey: Self.lowSpaceLastKey) as? Date, now.timeIntervalSince(last) < Self.lowSpaceInterval, purged == 0 { return }
        defaults.set(now, forKey: Self.lowSpaceLastKey)
        let freeable = host?.reclaimable.values.reduce(0, +) ?? 0
        var body = freeable >= Self.cleanupThreshold
            ? String(localized: "\(ByteFormat.string(reading.available)) left. Molt can free \(ByteFormat.string(freeable)).")
            : String(localized: "\(ByteFormat.string(reading.available)) left.")
        if purged > 0 { body = String(localized: "Molt freed \(ByteFormat.string(purged)) of purgeable files.") + " " + body }
        body += " " + String(localized: "Export a dry-run report in Settings to see what else could go.")
        post(.lowSpace, title: String(localized: "Your disk is almost full"), body: body, destination: "settings")
    }

    /// macOS's purge of purgeable files, through Other System Files' own cleanup, at most once an hour. What it freed; 0 when it
    /// did not run. The cleanup history records it as automatic.
    func emergencyPurge(now: Date = Date()) async -> UInt64 {
        guard emergencyPurgeEnabled, let handle = host?.handle(for: Self.emergencyModuleID), handle.state == .ready else { return 0 }
        if let last = defaults.object(forKey: Self.emergencyLastKey) as? Date, now.timeIntervalSince(last) < Self.emergencyInterval { return 0 }
        defaults.set(now, forKey: Self.emergencyLastKey)
        return await handle.autoClean()?.freedBytes ?? 0
    }

    nonisolated static func isLow(available: UInt64, capacity: UInt64) -> Bool {
        LowDiskPolicy.isLow(available: available, capacity: capacity)
    }

    private func post(_ kind: Kind, title: String, body: String, destination: String) {
        // One of each kind at a time: a newer one replaces the one before it.
        Self.deliver(identifier: "com.macspace.\(kind.rawValue)",
                     content: Self.content(title: title, body: body, thread: kind.rawValue, userInfo: ["destination": destination]))
    }

    /// A module's notification (`ModuleServices.notify`), from any thread: each one stays, grouped under its module, and opens the
    /// module's page. Debloat and Siri each posted theirs with code of their own (2026-10-20).
    nonisolated static func post(module: String, title: String, body: String) {
        deliver(identifier: UUID().uuidString, content: moduleContent(module: module, title: title, body: body))
    }

    nonisolated static func moduleContent(module: String, title: String, body: String) -> UNMutableNotificationContent {
        content(title: title, body: body, thread: module, userInfo: ["module": module])
    }

    private nonisolated static func content(title: String, body: String, thread: String, userInfo: [String: String]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        content.userInfo = userInfo
        return content
    }

    private nonisolated static func deliver(identifier: String, content: UNMutableNotificationContent) {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    // MARK: Clicks

    /// Where a notification leads: "home", "storage", "settings", "module:<id>", or a module's own notification, which carries
    /// "module" = its id.
    nonisolated static func destination(_ userInfo: [AnyHashable: Any]) -> Destination? {
        if let module = userInfo["module"] as? String { return .module(module) }
        guard let value = userInfo["destination"] as? String else { return nil }
        if value.hasPrefix("module:") { return .module(String(value.dropFirst("module:".count))) }
        switch value {
        case "storage": return .storage
        case "settings": return .settings
        default: return nil
        }
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let destination = Self.destination(response.notification.request.content.userInfo)
        await MainActor.run { AppRouter.shared.open(destination) }
    }

    /// With MacSpace in front, a notification still shows: the watches post while the window is open too.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
