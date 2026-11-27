import Darwin
import Foundation

/// Rule 6, watch only: a folder that had a lot written into it lately.
/// Chrome's 4 GB on-device AI model was found this way on 2026-11-21: no
/// rule knew it, but its folder took 4 GB in one day.
public struct Growth: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    /// Allocated bytes of files modified inside the window, not counting
    /// what deeper folders in the same list already show. The list never
    /// counts a byte twice.
    public let bytes: Int64
    public let files: Int
    /// True when deeper folders of this one are listed too, so `bytes` is
    /// what grew spread over its other folders.
    public let spreadOut: Bool
}

public enum GrowthWatch {
    public struct Options: Sendable {
        public var window: TimeInterval = 86400
        /// How many folder levels below a root a finding can name.
        public var depth: Int = 3
        public var threshold: Int64 = 1_000_000_000

        public init() {}
    }

    /// Scans every root (missing ones are skipped), largest finding first.
    /// `progress` gets each root as it starts.
    public static func scan(
        roots: [URL], now: Date = Date(), options: Options = Options(),
        progress: (URL) -> Void = { _ in }
    ) throws -> [Growth] {
        var found: [Growth] = []
        for root in roots where FileSystem.isRealFolder(root) {
            progress(root)
            found += try scan(root: root, now: now, options: options)
        }
        return found.sorted { $0.bytes > $1.bytes }
    }

    struct Sum {
        var bytes: Int64 = 0
        var files = 0
    }

    static func scan(root: URL, now: Date, options: Options) throws -> [Growth] {
        let cutoff = now.addingTimeInterval(-options.window)
        let depth = max(0, options.depth)
        // names[n] is the name of the folder at level n on the current path.
        var names = [String](repeating: "", count: depth + 1)
        var sums: [[String]: Sum] = [:]
        var seenLinks = Set<Walker.InodeKey>()

        try Walker.walk(root.path) { entry, fts in
            let info = Int32(entry.pointee.fts_info)
            let level = Int(entry.pointee.fts_level)
            if info == FTS_D {
                let name = Walker.name(entry)
                // Git's object store: packs are rewritten often and say
                // nothing about what grew.
                if name == "objects", level >= 1, entry.pointee.fts_parent.map(Walker.name) == ".git" {
                    Walker.skip(fts, entry)
                    return
                }
                if level >= 1, level <= depth { names[level] = name }
                return
            }
            guard info == FTS_F, level >= 1, let statp = entry.pointee.fts_statp else { return }
            let st = statp.pointee
            guard st.st_mtimespec.date >= cutoff else { return }
            if st.st_nlink > 1, !seenLinks.insert(Walker.InodeKey(device: st.st_dev, inode: st.st_ino)).inserted {
                return
            }
            let bytes = Int64(st.st_blocks) * 512
            let deepest = min(level - 1, depth)
            var key: [String] = []
            sums[key, default: Sum()].add(bytes)
            if deepest >= 1 {
                for index in 1...deepest {
                    key.append(names[index])
                    sums[key, default: Sum()].add(bytes)
                }
            }
        }
        return select(sums, root: root, threshold: options.threshold)
    }

    /// The deepest folders over the threshold. A folder above them is named
    /// too when what was written in it outside those folders is itself over
    /// the threshold, and then with that part only.
    static func select(_ sums: [[String]: Sum], root: URL, threshold: Int64) -> [Growth] {
        var covered: [[String]: Sum] = [:]
        var found: [Growth] = []
        for key in sums.keys.sorted(by: { $0.count > $1.count }) {
            let sum = sums[key]!
            let inside = covered[key, default: Sum()]
            let rest = Sum(bytes: sum.bytes - inside.bytes, files: sum.files - inside.files)
            let reported = rest.bytes >= threshold
            if reported {
                let url = key.reduce(root) { $0.appending(path: $1, directoryHint: .isDirectory) }
                found.append(Growth(url: url, bytes: rest.bytes, files: rest.files, spreadOut: inside.bytes > 0))
            }
            if !key.isEmpty {
                let parent = Array(key.dropLast())
                let passed = reported ? sum : inside
                covered[parent, default: Sum()].bytes += passed.bytes
                covered[parent, default: Sum()].files += passed.files
            }
        }
        return found
    }
}

extension GrowthWatch.Sum {
    mutating func add(_ more: Int64) {
        bytes += more
        files += 1
    }
}
