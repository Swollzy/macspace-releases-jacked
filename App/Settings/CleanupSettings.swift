import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

/// Cleanup in one section: automatic cleanup (on or off, how often), then what has been freed so far and a
/// row that opens the page of every cleanup (`CleanupHistoryPage`).
struct CleanupSection: View {
    @ObservedObject var cleaner: AutoCleaner
    @ObservedObject var host: ModuleHost
    @State private var lifetime = CleanupHistory.shared.lifetimeBytes
    @AppStorage(AppNotifications.emergencyPurgeKey) private var emergencyPurge = true
    @State private var exporting = false
    @State private var exportNote: String?

    var body: some View {
        PageSection("Cleanup") {
            Toggle(isOn: $cleaner.isEnabled.animation(Theme.layout)) {
                InfoTitle(title: String(localized: "Clean automatically"), info: String(localized: "Frees caches, old reports and other files that are safe to delete."))
            }
            if cleaner.isEnabled {
                PagePicker("How often", selection: $cleaner.frequency) {
                    ForEach(AutoCleaner.Frequency.allCases) { Text($0.title).tag($0) }
                }
                .rowCascade()
            }
            LabeledContent("Freed in total") {
                ChangingText(text: ByteFormat.string(lifetime), alignment: .trailing).monospacedDigit()
            }
            SettingsLinkRow(title: String(localized: "Recent cleanups"), note: nil) { host.settingsPage = .cleanupHistory }
            // Only macOS's own purge of purgeable files, and only while MacSpace is open: nothing watches the disk with the app closed.
            Toggle(isOn: $emergencyPurge) {
                InfoTitle(title: String(localized: "Free purgeable files when the disk is almost full"),
                          info: String(localized: "Under 15 GB or 10% free, Molt asks macOS to free the files apps marked purgeable, and tells you. It never moves your files, apps, snapshots or backups. Only while Molt is open."))
            }
            SettingsLinkRow(title: exporting ? String(localized: "Exporting…") : String(localized: "Export dry-run report…"), note: exportNote) {
                guard !exporting else { return }
                exporting = true
                Task {
                    switch await DryRunExport.run(host: host) {
                    case .success?: exportNote = String(localized: "Saved. Nothing was deleted.")
                    case let .failure(error)?: exportNote = error.localizedDescription
                    case nil: break
                    }
                    exporting = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: CleanupHistory.didChange)) { _ in
            withAnimation(Theme.value) { lifetime = CleanupHistory.shared.lifetimeBytes }
        }
    }
}

/// A row that opens a page over Settings, with a chevron.
struct SettingsLinkRow: View {
    let title: String
    let note: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                TitleLine(title: title, note: note)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Every cleanup, newest first: the module, when, how it started as a pill, and the space freed.
struct CleanupHistoryPage: View {
    @State private var entries = CleanupHistory.shared.entries
    @Environment(\.design) private var design

    var body: some View {
        // Only the cleanups: Settings' Cleanup section, which opens this page, already says what has been freed in total.
        PageForm {
            PageSection {
                if entries.isEmpty {
                    Text("Nothing cleaned yet.").foregroundStyle(.secondary).rowCascade()
                }
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        TitleLine(title: entry.moduleName, note: entry.date.formatted(date: .abbreviated, time: .shortened))
                        // How it started is a fact about the row: a pill.
                        BadgeView(badge: Badge(Self.trigger(entry.trigger), .info))
                        Spacer(minLength: 8)
                        ChangingText(text: ByteFormat.string(entry.freedBytes), alignment: .trailing).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .rowCascade()
                }
            }
        }
        .modifier(PageScrollArea(hasFooter: false))
        .environment(\.colorScheme, design.colorScheme)
        // Settings is drawn on the slate tile's color.
        .environment(\.pageGround, design.palette(.slate).base)
        .onReceive(NotificationCenter.default.publisher(for: CleanupHistory.didChange)) { _ in
            withAnimation(Theme.layout) { entries = CleanupHistory.shared.entries }
        }
    }

    static func trigger(_ trigger: CleanupHistory.Trigger) -> String {
        switch trigger {
        case .manual: return String(localized: "By you")
        case .automatic: return String(localized: "Automatic")
        case .background: return String(localized: "By Molt")
        }
    }
}
