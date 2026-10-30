import AppKit
import MacSpacePlatform
import MacSpaceSdk

/// Settings' Export dry-run report: what MacSpace would free and what it would move to the Trash, written as JSON and Markdown into a
/// folder the user picks. It reads the modules' pages and nothing else: no module acts, nothing is deleted, and the files are never
/// sent anywhere.
@MainActor
enum DryRunExport {
    static let folderKey = "dryRunReport.folder"

    /// Asks for the folder, writes the report there and shows it in the Finder. nil when the user cancelled; the error when writing
    /// failed.
    static func run(host: ModuleHost, defaults: UserDefaults = .standard) async -> Result<URL, Error>? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Export Here")
        panel.message = String(localized: "Choose where to save the dry-run report. It stays on this Mac.")
        if let saved = defaults.string(forKey: folderKey) { panel.directoryURL = URL(fileURLWithPath: saved, isDirectory: true) }
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        defaults.set(folder.path, forKey: folderKey)
        do {
            let files = try await report(host: host).write(to: folder)
            NSWorkspace.shared.activateFileViewerSelecting([files.markdown, files.json])
            return .success(files.markdown)
        } catch {
            return .failure(error)
        }
    }

    static func report(host: ModuleHost) async -> DryRunReport {
        var modules: [DryRunReport.Module] = []
        for handle in host.activeHandles {
            let screen = await handle.screenForReport()
            let items = screen.map { DryRunReport.items(in: $0, checked: { handle.checked($0) }) } ?? []
            modules.append(DryRunReport.Module(id: handle.id, name: handle.manifest.name, reclaimableBytes: handle.tile?.reclaimableBytes,
                                               autoClean: AutoCleaner.takesPart(handle.manifest), items: items))
        }
        let values = try? URL(fileURLWithPath: DataVolume.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return DryRunReport(macSpaceVersion: version, freeBytes: values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) },
                            capacityBytes: values?.volumeTotalCapacity.map { UInt64(max(0, $0)) }, modules: modules)
    }
}
