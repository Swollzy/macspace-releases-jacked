import CryptoKit
import Darwin
import Foundation

/// One file Large Files found: where it is, its size, and what moving it to the Trash would free on the disk.
public struct FoundFile: Codable, Equatable, Hashable, Sendable {
    public var path: String
    /// The file's length, which two copies share.
    public var bytes: UInt64
    /// The blocks it takes on the disk, which can be less (an APFS clone, a sparse file).
    public var allocatedBytes: UInt64
    public var modified: Date?
    public var created: Date?

    public init(path: String, bytes: UInt64, allocatedBytes: UInt64, modified: Date? = nil, created: Date? = nil) {
        self.path = path
        self.bytes = bytes
        self.allocatedBytes = allocatedBytes
        self.modified = modified
        self.created = created
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Files with the same length and the same SHA-256 of their whole content. `keeper` is never offered for the Trash: a group always
/// keeps one copy, and at most `copies.count - 1` can go.
public struct DuplicateGroup: Codable, Equatable, Sendable, Identifiable {
    /// The full SHA-256, in hex.
    public var hash: String
    public var bytes: UInt64
    /// The copy that stays: the oldest, then the shortest path, then the first by name. Never trashed.
    public var keeper: FoundFile
    /// The other copies, which the user may check.
    public var copies: [FoundFile]

    public var id: String { hash }
    /// What trashing every other copy would free.
    public var reclaimableBytes: UInt64 { copies.reduce(0) { $0 + $1.allocatedBytes } }
    public var all: [FoundFile] { [keeper] + copies }
}

public struct LargeFilesSnapshot: Codable, Equatable, Sendable {
    public var roots: [String]
    /// Files of `largeThreshold` or more, largest first.
    public var largeFiles: [FoundFile]
    /// Largest reclaimable first.
    public var duplicates: [DuplicateGroup]
    /// Roots that could not be read (macOS asks for each of Documents, Desktop and Downloads unless MacSpace has Full Disk Access).
    public var unreadableRoots: [String]
    public var scanned: Date

    public init(roots: [String], largeFiles: [FoundFile], duplicates: [DuplicateGroup], unreadableRoots: [String] = [], scanned: Date = Date()) {
        self.roots = roots
        self.largeFiles = largeFiles
        self.duplicates = duplicates
        self.unreadableRoots = unreadableRoots
        self.scanned = scanned
    }

    public var largeBytes: UInt64 { largeFiles.reduce(0) { $0 + $1.allocatedBytes } }
    public var duplicateReclaimableBytes: UInt64 { duplicates.reduce(0) { $0 + $1.reclaimableBytes } }
}

/// Reads the roots for large files and duplicates. Duplicates are found in three passes, each only over what the one before left
/// together: the same length, then the same SHA-256 of the first and last 64 KB, then the same SHA-256 of the whole file. Only the
/// last decides: two files are duplicates only with the same length and the same full hash.
public struct LargeFileScanner: Sendable {
    /// Files of this size or more are listed as large: 100 MB.
    public static let largeThreshold: UInt64 = 100_000_000
    /// Smaller files are not compared: hashing every small file in the user's folders costs more than they could free.
    public static let duplicateMinimum: UInt64 = 1_000_000
    static let partialChunk = 64 * 1024
    /// `SF_DATALESS` in <sys/stat.h>: the file's content is only in the cloud.
    static let datalessFlag: UInt32 = 0x4000_0000

    public var roots: ScanRoots
    public var largeThreshold: UInt64
    public var duplicateMinimum: UInt64

    public init(roots: ScanRoots, largeThreshold: UInt64 = LargeFileScanner.largeThreshold, duplicateMinimum: UInt64 = LargeFileScanner.duplicateMinimum) {
        self.roots = roots
        self.largeThreshold = largeThreshold
        self.duplicateMinimum = duplicateMinimum
    }

    public func scan(progress: @Sendable (Double) -> Void = { _ in }) -> LargeFilesSnapshot {
        var unreadable: [String] = []
        var files: [FoundFile] = []
        // Each file once: a hard link is the same file under another name, and trashing it frees nothing.
        var seenInodes = Set<String>()
        for (index, root) in roots.roots.enumerated() {
            if !collect(root, into: &files, seen: &seenInodes) { unreadable.append(root) }
            progress(0.4 * Double(index + 1) / Double(max(roots.roots.count, 1)))
        }
        let large = files.filter { $0.bytes >= largeThreshold }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        let duplicates = findDuplicates(files.filter { $0.bytes >= duplicateMinimum }, progress: { progress(0.4 + 0.6 * $0) })
        progress(1)
        return LargeFilesSnapshot(roots: roots.roots, largeFiles: large, duplicates: duplicates, unreadableRoots: unreadable)
    }

    /// Every regular file under `root` the walk may enter. False when the root itself could not be listed.
    private func collect(_ root: String, into files: inout [FoundFile], seen: inout Set<String>) -> Bool {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
                                      .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey]
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard (try? FileManager.default.contentsOfDirectory(atPath: root)) != nil else { return false }
        // Packages are skipped as a whole: a file inside a Photos library or an app is not the user's to trash on its own.
        guard let walk = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                        options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return false }
        for case let url as URL in walk {
            let path = url.path
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if values.isPackage == true || !roots.mayEnter(path, under: root) { walk.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, !path.contains("\n") else { continue }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            // A file still only in the cloud takes no space here, and reading it would download it.
            if info.st_flags & Self.datalessFlag != 0 { continue }
            guard seen.insert("\(info.st_dev):\(info.st_ino)").inserted else { continue }
            let bytes = UInt64(size)
            guard bytes >= min(largeThreshold, duplicateMinimum) else { continue }
            files.append(FoundFile(path: path, bytes: bytes, allocatedBytes: UInt64(max(0, values.totalFileAllocatedSize ?? size)),
                                   modified: values.contentModificationDate, created: values.creationDate))
        }
        return true
    }

    func findDuplicates(_ files: [FoundFile], progress: (Double) -> Void) -> [DuplicateGroup] {
        let bySize = Dictionary(grouping: files, by: \.bytes).values.filter { $0.count > 1 }
        var groups: [DuplicateGroup] = []
        for (index, sameSize) in bySize.enumerated() {
            let byPartial = Dictionary(grouping: sameSize, by: { Self.partialHash($0.path) ?? "unreadable:\($0.path)" }).values.filter { $0.count > 1 }
            for candidates in byPartial {
                let byFull = Dictionary(grouping: candidates, by: { Self.fullHash($0.path) ?? "unreadable:\($0.path)" })
                for (hash, copies) in byFull where copies.count > 1 && !hash.hasPrefix("unreadable:") {
                    let ordered = copies.sorted(by: Self.keepFirst)
                    groups.append(DuplicateGroup(hash: hash, bytes: ordered[0].bytes, keeper: ordered[0], copies: Array(ordered.dropFirst())))
                }
            }
            progress(Double(index + 1) / Double(bySize.count))
        }
        return groups.sorted { $0.reclaimableBytes != $1.reclaimableBytes ? $0.reclaimableBytes > $1.reclaimableBytes : $0.hash < $1.hash }
    }

    /// Which copy a group keeps: the oldest (it is most likely the original), then the shortest path, then the first by name.
    static func keepFirst(_ a: FoundFile, _ b: FoundFile) -> Bool {
        let ad = a.created ?? a.modified ?? .distantFuture, bd = b.created ?? b.modified ?? .distantFuture
        if ad != bd { return ad < bd }
        if a.path.count != b.path.count { return a.path.count < b.path.count }
        return a.path < b.path
    }

    /// SHA-256 of the first and last 64 KB (the whole file when it is shorter than both).
    public static func partialHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            var hasher = SHA256()
            let head = try handle.read(upToCount: partialChunk) ?? Data()
            hasher.update(data: head)
            let end = try handle.seekToEnd()
            if end > UInt64(partialChunk * 2) {
                try handle.seek(toOffset: end - UInt64(partialChunk))
                hasher.update(data: try handle.read(upToCount: partialChunk) ?? Data())
            } else if end > UInt64(partialChunk) {
                try handle.seek(toOffset: UInt64(partialChunk))
                hasher.update(data: try handle.readToEnd() ?? Data())
            }
            return hex(hasher.finalize())
        } catch {
            return nil
        }
    }

    /// SHA-256 of the whole file, read in 1 MB pieces.
    public static func fullHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                let done = try autoreleasepool { () throws -> Bool in
                    guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return true }
                    hasher.update(data: chunk)
                    return false
                }
                if done { break }
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
