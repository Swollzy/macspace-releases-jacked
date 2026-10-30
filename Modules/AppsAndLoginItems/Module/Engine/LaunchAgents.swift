import Foundation
import MacSpacePlatform

/// A launch agent: a property list in ~/Library/LaunchAgents or /Library/LaunchAgents that launchd runs in the user's session.
public struct LaunchAgent: Codable, Equatable, Hashable, Sendable {
    public enum Scope: String, Codable, Sendable {
        /// ~/Library/LaunchAgents: this user's.
        case user
        /// /Library/LaunchAgents: installed for every user.
        case system
    }

    public var label: String
    public var plistPath: String
    public var program: String?
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var scope: Scope
    /// launchd's own switch for this label in the user's session (`launchctl print-disabled`).
    public var disabled: Bool

    public init(label: String, plistPath: String, program: String?, runAtLoad: Bool, keepAlive: Bool, scope: Scope, disabled: Bool = false) {
        self.label = label
        self.plistPath = plistPath
        self.program = program
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.scope = scope
        self.disabled = disabled
    }

    /// macOS's own agents are listed nowhere and never switched.
    public var isApple: Bool { label.hasPrefix("com.apple.") }
}

public enum LaunchAgentInventory {
    public static func folders(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [(String, LaunchAgent.Scope)] {
        [((home as NSString).appendingPathComponent("Library/LaunchAgents"), .user), ("/Library/LaunchAgents", .system)]
    }

    /// Every agent in the folders but macOS's own, by label. `disabled` is launchd's list of switched-off labels.
    public static func agents(in folders: [(String, LaunchAgent.Scope)] = folders(), disabled: Set<String> = []) -> [LaunchAgent] {
        var agents: [LaunchAgent] = []
        for (folder, scope) in folders {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() where name.hasSuffix(".plist") {
                let path = (folder as NSString).appendingPathComponent(name)
                guard var agent = parse(path, scope: scope), !agent.isApple else { continue }
                agent.disabled = disabled.contains(agent.label)
                agents.append(agent)
            }
        }
        return agents.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    public static func parse(_ path: String, scope: LaunchAgent.Scope) -> LaunchAgent? {
        guard let data = FileManager.default.contents(atPath: path),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = values["Label"] as? String, !label.isEmpty else { return nil }
        let program = (values["Program"] as? String) ?? (values["ProgramArguments"] as? [String])?.first
        let keepAlive: Bool
        let keep: Any = values["KeepAlive"] ?? false
        switch keep {
        case let flag as Bool: keepAlive = flag
        case is [String: Any]: keepAlive = true
        default: keepAlive = false
        }
        return LaunchAgent(label: label, plistPath: path, program: program, runAtLoad: values["RunAtLoad"] as? Bool ?? false,
                           keepAlive: keepAlive, scope: scope)
    }

    /// The labels launchd has switched off in `gui/<uid>`, from `launchctl print-disabled`: lines like `"com.vendor.agent" => disabled`
    /// (or `=> true` on older systems).
    public static func parseDisabled(_ output: String) -> Set<String> {
        var labels = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard state == "disabled" || state == "true" else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !label.isEmpty { labels.insert(label) }
        }
        return labels
    }
}

/// Switches launch agents off and back on through launchd's own per-user switch (`launchctl disable` / `enable` in `gui/<uid>`).
/// The property list is never moved, edited or deleted, so turning an agent back on puts everything back. What MacSpace switched
/// off is written to a journal (`DisabledAgentsJournal`), so it can be listed and restored, also before MacSpace is uninstalled.
public struct LaunchAgentSwitch: Sendable {
    public var runner: any CommandRunning
    public var journal: DisabledAgentsJournal
    public var uid: uid_t

    public init(runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 20), journal: DisabledAgentsJournal = DisabledAgentsJournal(),
                uid: uid_t = getuid()) {
        self.runner = runner
        self.journal = journal
        self.uid = uid
    }

    var domain: String { "gui/\(uid)" }

    public func disabledLabels() -> Set<String> {
        guard let result = try? runner.run("/bin/launchctl", ["print-disabled", domain]), result.exitCode == 0 else { return [] }
        return LaunchAgentInventory.parseDisabled(String(decoding: result.stdout, as: UTF8.self))
    }

    /// Switches the agent off so it no longer starts at login, and stops it now. Journaled first, so a failure halfway is still undone.
    public func disable(_ agent: LaunchAgent) throws {
        guard !agent.isApple else { throw SwitchError.apple }
        try journal.add(DisabledAgentsJournal.Entry(label: agent.label, plistPath: agent.plistPath, program: agent.program, date: Date()))
        let result = try runner.run("/bin/launchctl", ["disable", "\(domain)/\(agent.label)"])
        guard result.exitCode == 0 else {
            try? journal.remove(agent.label)
            throw SwitchError.launchctl(String(decoding: result.stderr, as: UTF8.self))
        }
        // Stopping it may fail when it was not running; it stays switched off either way.
        _ = try? runner.run("/bin/launchctl", ["bootout", "\(domain)/\(agent.label)"])
    }

    /// Switches it back on and loads it again from its untouched property list.
    public func enable(label: String, plistPath: String?) throws {
        guard !label.hasPrefix("com.apple.") else { throw SwitchError.apple }
        let result = try runner.run("/bin/launchctl", ["enable", "\(domain)/\(label)"])
        guard result.exitCode == 0 else { throw SwitchError.launchctl(String(decoding: result.stderr, as: UTF8.self)) }
        // Loaded again only from one of the two LaunchAgents folders, never from a path a request names elsewhere.
        if let plistPath, FileManager.default.fileExists(atPath: plistPath),
           LaunchAgentInventory.folders().contains(where: { (plistPath as NSString).standardizingPath.hasPrefix($0.0 + "/") }) {
            _ = try? runner.run("/bin/launchctl", ["bootstrap", domain, plistPath])
        }
        try journal.remove(label)
    }

    /// Turns every agent MacSpace switched off back on. The labels that could not be, with why.
    public func restoreAll() -> [String: String] {
        var failures: [String: String] = [:]
        for entry in journal.entries() {
            do { try enable(label: entry.label, plistPath: entry.plistPath) } catch { failures[entry.label] = "\(error)" }
        }
        return failures
    }

    public enum SwitchError: Error, CustomStringConvertible {
        case apple
        case launchctl(String)

        public var description: String {
            switch self {
            case .apple: return "macOS's own agents are not switched."
            case let .launchctl(message): return "launchctl: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}

/// The agents MacSpace switched off: label, property list and when, in Application Support, so each can be put back.
public struct DisabledAgentsJournal: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var label: String
        public var plistPath: String
        public var program: String?
        public var date: Date
    }

    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSpace/disabled-launch-agents.json")

    public var url: URL

    public init(url: URL = DisabledAgentsJournal.defaultURL) { self.url = url }

    public func entries() -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode([Entry].self, from: $0) } ?? []
    }

    public func add(_ entry: Entry) throws {
        try save(entries().filter { $0.label != entry.label } + [entry])
    }

    public func remove(_ label: String) throws {
        try save(entries().filter { $0.label != label })
    }

    private func save(_ entries: [Entry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}
