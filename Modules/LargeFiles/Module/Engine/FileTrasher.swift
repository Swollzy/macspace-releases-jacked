import Foundation

/// Moves files the user checked to the Trash, and nothing else: never a permanent delete, never a file the last scan did not list,
/// never a group's last copy. Every file is checked again on disk right before it goes.
public struct FileTrasher: Sendable {
    /// Moves one file to the Trash and says where it went. The live one is Finder's Trash (`FileManager.trashItem`); tests pass
    /// one that moves into a folder of their own.
    public typealias Mover = @Sendable (_ url: URL) throws -> URL?

    public static let live: Mover = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    public struct Outcome: Equatable, Sendable {
        /// Path → where it is in the Trash now.
        public var trashed: [String: String] = [:]
        /// Path → why it stayed.
        public var refused: [String: String] = [:]
        /// What the trashed files took on the disk; the volume frees it once the Trash is emptied.
        public var bytes: UInt64 = 0
    }

    public var roots: ScanRoots
    public var move: Mover

    public init(roots: ScanRoots, move: @escaping Mover = FileTrasher.live) {
        self.roots = roots
        self.move = move
    }

    /// Trashes the checked large files, each only if it is still the file the scan listed (same length) and still in a root. The
    /// kept copy of a duplicate group is refused here too: it is what makes trashing the group's other copies safe.
    public func trashLarge(_ paths: [String], snapshot: LargeFilesSnapshot) -> Outcome {
        var outcome = Outcome()
        let listed = Dictionary(snapshot.largeFiles.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let keepers = Set(snapshot.duplicates.map(\.keeper.path))
        for path in Set(paths).sorted() {
            guard let file = listed[path] else { outcome.refused[path] = "Not in the last scan."; continue }
            if keepers.contains(path) { outcome.refused[path] = "The kept copy of a duplicate set."; continue }
            if let reason = stillTheSame(file) { outcome.refused[path] = reason; continue }
            trash(file, into: &outcome)
        }
        return outcome
    }

    /// Trashes checked copies of one duplicate group, keeping at least one copy, always. The keeper is refused even if asked for.
    /// Before anything goes, the keeper is hashed again: if it changed or is gone, nothing in the group is touched. Each copy is
    /// hashed again too, and goes only if it still matches.
    public func trashDuplicates(_ paths: [String], group: DuplicateGroup) -> Outcome {
        var outcome = Outcome()
        let copies = Dictionary(group.copies.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var wanted: [FoundFile] = []
        for path in Set(paths).sorted() {
            if path == group.keeper.path { outcome.refused[path] = "The copy that is kept."; continue }
            guard let file = copies[path] else { outcome.refused[path] = "Not a copy in this group."; continue }
            wanted.append(file)
        }
        guard !wanted.isEmpty else { return outcome }
        guard stillTheSame(group.keeper) == nil, LargeFileScanner.fullHash(group.keeper.path) == group.hash else {
            for file in wanted { outcome.refused[file.path] = "The kept copy changed or is gone, so no copy was moved." }
            return outcome
        }
        // N - 1 at most: with the keeper verified, every other copy may go, never more.
        for file in wanted.prefix(group.all.count - 1) {
            if let reason = stillTheSame(file) { outcome.refused[file.path] = reason; continue }
            guard LargeFileScanner.fullHash(file.path) == group.hash else { outcome.refused[file.path] = "It changed since the scan."; continue }
            trash(file, into: &outcome)
        }
        return outcome
    }

    /// nil when the file is still a regular file of the scanned length, in a root; else why it stays.
    func stillTheSame(_ file: FoundFile) -> String? {
        guard roots.covers(file.path) else { return "Not in a folder Large Files reads." }
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return "It is gone." }
        guard info.st_mode & S_IFMT == S_IFREG else { return "It is not a file any more." }
        guard UInt64(info.st_size) == file.bytes else { return "It changed since the scan." }
        return nil
    }

    private func trash(_ file: FoundFile, into outcome: inout Outcome) {
        do {
            let destination = try move(URL(fileURLWithPath: file.path))
            outcome.trashed[file.path] = destination?.path ?? ""
            outcome.bytes += file.allocatedBytes
        } catch {
            outcome.refused[file.path] = error.localizedDescription
        }
    }
}
