import Foundation
import MacSpacePlatform

/// Moves what the user checked to the Trash, and nothing else: each path is found again by a fresh scan right before it goes, and one
/// the scan no longer offers for that app is refused. Never a permanent delete, never a kept path, never an open copy.
public struct OldVersionCleaner: Sendable {
    /// Moves one item to the Trash and says where it went. The live one is Finder's Trash (`FileManager.trashItem`); tests pass one
    /// that moves into a folder of their own.
    public typealias Mover = @Sendable (_ url: URL) throws -> URL?

    public static let liveMover: Mover = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    public struct Outcome: Equatable, Sendable {
        /// Path → where it is in the Trash now.
        public var trashed: [String: String] = [:]
        /// Path → why it stayed.
        public var refused: [String: String] = [:]
        public var bytes: UInt64 = 0
    }

    public var scanner: OldVersionScanner
    public var move: Mover
    public var runner: any CommandRunning
    public var uid: uid_t

    public init(scanner: OldVersionScanner, move: @escaping Mover = OldVersionCleaner.liveMover,
                runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 20), uid: uid_t = getuid()) {
        self.scanner = scanner
        self.move = move
        self.runner = runner
        self.uid = uid
    }

    /// Trashes the checked items of one app (`bundleID`), by path.
    public func trash(_ paths: [String], of bundleID: String) -> Outcome {
        var outcome = Outcome()
        guard let report = scanner.scan().first(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }) else {
            for path in paths { outcome.refused[path] = "Scan again first." }
            return outcome
        }
        let (runningPaths, _) = scanner.running()
        let current = Dictionary(report.findings.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for path in Set(paths).sorted() {
            guard let finding = current[path] else { outcome.refused[path] = "Not one of \(report.name)'s leftovers any more."; continue }
            if let reason = refusal(finding, report: report, runningPaths: runningPaths) { outcome.refused[path] = reason; continue }
            if finding.kind == .launchAgent, let label = finding.label {
                // Stopped first so launchd lets go of it; it may not be loaded at all.
                _ = try? runner.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
            }
            do {
                outcome.trashed[path] = try move(URL(fileURLWithPath: path))?.path ?? ""
                outcome.bytes += finding.bytes
            } catch {
                outcome.refused[path] = error.localizedDescription
            }
        }
        return outcome
    }

    func refusal(_ finding: Finding, report: AppReport, runningPaths: Set<String>) -> String? {
        if let current = report.current, OldVersionScanner.isSame(finding.path, current.path) { return "The copy that is kept." }
        switch finding.kind {
        case .oldCopy:
            if runningPaths.contains(finding.path) { return "That copy is open. Quit it first." }
            if report.isRunning && !runningPaths.contains(where: { path in report.current.map { OldVersionScanner.isSame($0.path, path) } ?? false }) {
                return "\(report.name) is open from another place. Quit it first."
            }
        case .cache, .savedState, .logs, .clearable:
            if report.isRunning { return "\(report.name) is open. Quit it first." }
        case .crashReport, .launchAgent:
            break
        }
        return nil
    }
}
