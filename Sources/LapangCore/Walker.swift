import Darwin
import Foundation

/// What one folder holds, counted the way `du` counts: allocated blocks, not
/// file lengths, each hard-linked file once.
public struct FolderStats: Sendable, Equatable {
    public var allocatedBytes: Int64 = 0
    /// What deleting the folder would free: each file's APFS private size
    /// (clones share their blocks), and a hard-linked file only when all its
    /// links are inside.
    public var freeableBytes: Int64 = 0
    public var files: Int = 0
    public var folders: Int = 0
    /// The newest modification time of anything inside, the folder itself
    /// included. A folder's own time changes when something is added to it or
    /// removed from it, so this is "when was anything last done here".
    public var newestChange: Date = .distantPast
    /// Folders that could not be read (permissions) and entries that could not
    /// be stat'ed. Their contents are not in the totals.
    public var unreadable: Int = 0

    public init() {}
}

public enum WalkError: Error, Equatable {
    case cannotOpen(path: String, errno: Int32)
}

/// fts(3) over one folder: physical (never follows a symlink, the starting
/// path included), stays on the starting volume, and never changes the
/// process's working directory (other threads are running).
enum Walker {
    static let options = FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR

    /// Calls `visit` for every entry under `path`, the root included, in fts
    /// order (a folder before its contents, then again after them as FTS_DP).
    /// Checks for cancellation every 1,024 entries.
    static func walk(
        _ path: String,
        options: Int32 = Walker.options,
        _ visit: (UnsafeMutablePointer<FTSENT>, OpaquePointer?) throws -> Void
    ) throws {
        guard let cPath = strdup(path) else { throw WalkError.cannotOpen(path: path, errno: ENOMEM) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, options, nil) else {
            throw WalkError.cannotOpen(path: path, errno: errno)
        }
        defer { fts_close(fts) }
        var count = 0
        while let entry = fts_read(fts) {
            count += 1
            if count & 1023 == 0, Task.isCancelled { throw CancellationError() }
            try visit(entry, OpaquePointer(fts))
        }
    }

    /// Skips the folder `entry` is at (call on FTS_D).
    static func skip(_ fts: OpaquePointer?, _ entry: UnsafeMutablePointer<FTSENT>) {
        fts_set(UnsafeMutablePointer<FTS>(fts), entry, FTS_SKIP)
    }

    /// The name of the entry (its last path component).
    static func name(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        withUnsafePointer(to: &entry.pointee.fts_name) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: Int(entry.pointee.fts_namelen)) {
                String(decoding: UnsafeBufferPointer(start: $0, count: Int(entry.pointee.fts_namelen)), as: UTF8.self)
            }
        }
    }

    struct InodeKey: Hashable {
        var device: Int32
        var inode: UInt64
    }

    /// Measures a folder (or a single file).
    static func measure(_ url: URL) throws -> FolderStats {
        var stats = FolderStats()
        // Hard-linked files: how many of their links are inside, and their size.
        var links: [InodeKey: (seen: Int, needed: Int, bytes: Int64)] = [:]
        try walk(url.path) { entry, _ in
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D, FTS_DNR, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let statp = entry.pointee.fts_statp else { stats.unreadable += 1; return }
                let st = statp.pointee
                let kind = st.st_mode & S_IFMT
                let allocated = Int64(st.st_blocks) * 512
                if kind == S_IFREG, st.st_nlink > 1 {
                    // A hard link: its blocks once, like du; freed only when
                    // every link to it is in here.
                    let key = InodeKey(device: st.st_dev, inode: st.st_ino)
                    if let known = links[key] {
                        links[key] = (known.seen + 1, known.needed, known.bytes)
                        return
                    }
                    links[key] = (1, Int(st.st_nlink), allocated)
                } else if kind == S_IFREG {
                    stats.freeableBytes += FileSystem.privateBytes(entry.pointee.fts_path) ?? allocated
                } else {
                    stats.freeableBytes += allocated
                }
                stats.allocatedBytes += allocated
                if kind == S_IFDIR { stats.folders += 1 } else { stats.files += 1 }
                let modified = st.st_mtimespec.date
                if modified > stats.newestChange { stats.newestChange = modified }
                if info == FTS_DNR { stats.unreadable += 1 }
            case FTS_ERR, FTS_NS:
                stats.unreadable += 1
            default:
                break  // FTS_DP (a folder again, after its contents), FTS_DC, FTS_DOT
            }
        }
        for link in links.values where link.seen >= link.needed {
            stats.freeableBytes += link.bytes
        }
        return stats
    }
}

public enum Scanner {
    /// Measures `url` without following symlinks or leaving its volume.
    /// Throws CancellationError when the calling task is cancelled.
    public static func measure(_ url: URL) throws -> FolderStats {
        try Walker.measure(url)
    }
}
