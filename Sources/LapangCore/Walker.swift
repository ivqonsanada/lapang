import Darwin
import Foundation

/// What one folder holds, counted the way `du` counts: allocated blocks, not
/// file lengths, each hard-linked file once.
public struct FolderStats: Sendable, Equatable {
    public var allocatedBytes: Int64 = 0
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

    struct InodeKey: Hashable {
        var device: Int32
        var inode: UInt64
    }

    /// Measures a folder (or a single file).
    static func measure(_ url: URL) throws -> FolderStats {
        var stats = FolderStats()
        var seenLinks = Set<InodeKey>()
        try walk(url.path) { entry, _ in
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D, FTS_DNR, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let statp = entry.pointee.fts_statp else { stats.unreadable += 1; return }
                let st = statp.pointee
                let kind = st.st_mode & S_IFMT
                if kind == S_IFREG, st.st_nlink > 1 {
                    // A hard link: its blocks once, like du.
                    guard seenLinks.insert(InodeKey(device: st.st_dev, inode: st.st_ino)).inserted else { return }
                }
                stats.allocatedBytes += Int64(st.st_blocks) * 512
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
