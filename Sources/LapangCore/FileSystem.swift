import Darwin
import Foundation

/// What `lstat` says about one path. Symlinks are reported as symlinks,
/// never followed.
public struct FileInfo: Sendable, Equatable {
    public var isFolder: Bool
    public var isFile: Bool
    public var isSymlink: Bool
    public var device: Int32
    public var modified: Date
    public var created: Date
}

public enum FileSystem {
    public static func info(_ url: URL) -> FileInfo? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let kind = st.st_mode & S_IFMT
        return FileInfo(
            isFolder: kind == S_IFDIR,
            isFile: kind == S_IFREG,
            isSymlink: kind == S_IFLNK,
            device: st.st_dev,
            modified: st.st_mtimespec.date,
            created: st.st_birthtimespec.date
        )
    }

    /// A folder that is a folder, not a symlink to one.
    public static func isRealFolder(_ url: URL) -> Bool {
        info(url)?.isFolder == true
    }

    /// The real folders directly inside `url` (hidden ones too), sorted by
    /// name. Symlinks are left out. An unreadable or missing folder has none.
    public static func subfolders(of url: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.sorted().compactMap { name in
            let child = url.appending(path: name, directoryHint: .isDirectory)
            return isRealFolder(child) ? child : nil
        }
    }

    /// The folder a Claude Code project name stands for, found by trying each
    /// - as a / and keeping the paths that exist: -Users-me-code-web-app is
    /// /Users/me/code/web-app when that folder exists. A -- is a hidden
    /// folder (/.config). Nil when no folder on disk matches.
    public static func claudeProjectFolder(_ encoded: String) -> URL? {
        guard encoded.hasPrefix("-") else { return nil }
        let tokens = encoded.dropFirst().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        func search(_ base: String, _ index: Int) -> String? {
            if index == tokens.count { return base }
            var name = ""
            var next = index
            if tokens[next].isEmpty, next + 1 < tokens.count {
                name = "."
                next += 1
            }
            for end in next..<tokens.count {
                name += (end > next ? "-" : "") + tokens[end]
                let path = base + "/" + name
                if FileSystem.isRealFolder(URL(fileURLWithPath: path)), let found = search(path, end + 1) {
                    return found
                }
            }
            return nil
        }
        return search("", 0).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The path with every symlink in it resolved (/var → /private/var), or
    /// nil when it does not exist.
    public static func realPath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The bytes deleting this one file would free: APFS's private size, the
    /// blocks it shares with no clone. A file pnpm cloned from its store, or
    /// a checkout copied with `cp -c`, can hold 0 of its own. Nil where the
    /// volume cannot say; use the allocated size there. Never follows a
    /// symlink.
    public static func privateBytes(_ path: UnsafePointer<CChar>) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // A UInt32 length, then the off_t packed right after it (offset 4).
        var buffer = (UInt64(0), UInt64(0))
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        let size: off_t? = withUnsafeMutableBytes(of: &buffer) { raw in
            guard getattrlist(path, &request, raw.baseAddress, raw.count, options) == 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4, as: off_t.self)
        }
        return size.map { Int64($0) }
    }
}

extension timespec {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(tv_sec) + TimeInterval(tv_nsec) / 1_000_000_000)
    }
}
