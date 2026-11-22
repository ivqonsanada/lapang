import Darwin
import Foundation

/// Why an item the person checked was not deleted.
public enum SkipReason: Sendable, Equatable {
    case gone
    case symlink
    case notAFolder
    case outsideRoot
    case otherVolume
    /// Something inside changed after the scan, so it is in use again.
    case becameActive(Date)
    /// Deleting started but some entries stayed (permissions, a mount).
    case failed(String)

    public var summary: String {
        switch self {
        case .gone: "already gone"
        case .symlink: "became a symlink"
        case .notAFolder: "no longer a folder"
        case .outsideRoot: "outside the rule's folder"
        case .otherVolume: "on another volume"
        case .becameActive: "changed since the scan"
        case .failed(let message): "could not be deleted: \(message)"
        }
    }
}

public struct DeletionResult: Sendable {
    public struct Deleted: Sendable {
        public let item: Item
        public let freed: Int64
    }

    public struct Skipped: Sendable {
        public let item: Item
        public let reason: SkipReason
    }

    public var deleted: [Deleted] = []
    public var skipped: [Skipped] = []

    public var freedBytes: Int64 { deleted.reduce(0) { $0 + $1.freed } }
}

/// Deletes items a person confirmed, each one checked again first:
/// still a real folder, still inside its rule's root once every symlink in
/// the path is resolved, on the same volume as the root, and still idle.
/// Never follows a symlink and never leaves the volume while deleting.
/// Every outcome is appended to the log.
public struct Deleter: Sendable {
    public let log: URL
    private let now: @Sendable () -> Date

    public init(log: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.log = log
        self.now = now
    }

    /// Nil when the item may be deleted now, otherwise why not.
    public func check(_ item: Item) -> SkipReason? {
        guard let info = FileSystem.info(item.url) else { return .gone }
        if info.isSymlink { return .symlink }
        guard info.isFolder else { return .notAFolder }

        let name = item.url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              let rootReal = FileSystem.realPath(item.root), rootReal != "/",
              let parentReal = FileSystem.realPath(item.url.deletingLastPathComponent())
        else { return .outsideRoot }
        let itemReal = (parentReal == "/" ? "" : parentReal) + "/" + name
        guard itemReal.hasPrefix(rootReal + "/") else { return .outsideRoot }

        guard let rootInfo = FileSystem.info(URL(fileURLWithPath: rootReal)), rootInfo.device == info.device
        else { return .otherVolume }

        guard let stats = try? Scanner.measure(item.url) else { return .failed("could not be measured") }
        if now().timeIntervalSince(stats.newestChange) < item.idleNeeded {
            return .becameActive(stats.newestChange)
        }
        return nil
    }

    /// Checks and deletes each item in turn. `progress` gets the number done.
    /// Stops between items when the task is cancelled.
    public func delete(_ items: [Item], progress: (Int) -> Void = { _ in }) -> DeletionResult {
        var result = DeletionResult()
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            if let reason = check(item) {
                result.skipped.append(.init(item: item, reason: reason))
                write(item: item, outcome: "skipped: \(reason.summary)", bytes: item.bytes)
            } else {
                let (freed, failure) = remove(item.url)
                if let failure {
                    // Whatever went is still freed space, and the person sees why the rest stayed.
                    result.skipped.append(.init(item: item, reason: .failed(failure)))
                    if freed > 0 { result.deleted.append(.init(item: item, freed: freed)) }
                    write(item: item, outcome: "partly deleted: \(failure)", bytes: freed)
                } else {
                    result.deleted.append(.init(item: item, freed: freed))
                    write(item: item, outcome: "deleted", bytes: freed)
                }
            }
            progress(index + 1)
        }
        return result
    }

    /// Removes a folder tree bottom up with fts: physical (a symlink inside is
    /// removed as a link, its target untouched) and on one volume only.
    /// Returns the bytes freed and, when something stayed, the first error.
    func remove(_ url: URL) -> (freed: Int64, failure: String?) {
        var freed: Int64 = 0
        var failures = 0
        var firstError: String?
        var rootDevice: Int32?

        func fail(_ path: UnsafeMutablePointer<CChar>, _ code: Int32) {
            failures += 1
            if firstError == nil { firstError = String(cString: strerror(code)) }
        }

        do {
            try Walker.walk(url.path) { entry, fts in
                let info = Int32(entry.pointee.fts_info)
                let path = entry.pointee.fts_path!
                let st = entry.pointee.fts_statp?.pointee
                switch info {
                case FTS_D:
                    guard let st else { return }
                    if rootDevice == nil { rootDevice = st.st_dev }
                    if st.st_dev != rootDevice {
                        Walker.skip(fts, entry)
                        fail(path, EXDEV)
                        return
                    }
                    // A folder without owner write or search permission (Go's
                    // module cache does this) cannot be emptied; open it up.
                    if st.st_mode & S_IRWXU != S_IRWXU, st.st_uid == getuid() {
                        chmod(path, (st.st_mode & 0o7777) | S_IRWXU)
                    }
                case FTS_DP:
                    if rmdir(path) == 0 { freed += Int64(st?.st_blocks ?? 0) * 512 } else { fail(path, errno) }
                case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                    if unlink(path) == 0 {
                        if let st, (st.st_mode & S_IFMT) != S_IFREG || st.st_nlink <= 1 {
                            freed += Int64(st.st_blocks) * 512
                        }
                    } else {
                        fail(path, errno)
                    }
                case FTS_DNR, FTS_ERR, FTS_NS:
                    fail(path, entry.pointee.fts_errno)
                default:
                    break
                }
            }
        } catch {
            return (freed, "\(error)")
        }
        if failures > 0 {
            let what = failures == 1 ? "1 entry stayed" : "\(failures) entries stayed"
            return (freed, "\(what) (\(firstError ?? "unknown error"))")
        }
        return (freed, nil)
    }

    private func write(item: Item, outcome: String, bytes: Int64) {
        let time = now().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .colon))
        let line = [time, item.rule.rawValue, outcome, String(bytes), item.url.path].joined(separator: "\t") + "\n"
        let folder = log.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.utf8CString.withUnsafeBufferPointer { buffer in
            Darwin.write(fd, buffer.baseAddress, buffer.count - 1)
        }
    }
}
