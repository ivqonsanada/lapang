import Foundation

/// How a learned spot recognises its folders again.
public enum NamePattern: Sendable, Hashable {
    /// A family: the key and any random ending (e2e-run-381UXa → "e2e-run-").
    case family(String)
    /// One exact name (node_modules).
    case exact(String)
    /// Headless Chrome's scoped_dir<pid>_<n> folders.
    case prefix(String)

    /// The pattern a deleted folder's name teaches.
    static func learned(from name: String, rule: RuleID) -> NamePattern {
        if rule == .headlessScratch, name.hasPrefix("scoped_dir") { return .prefix("scoped_dir") }
        if rule == .browserProfiles, let known = Rules.profilePrefixes.first(where: name.hasPrefix) {
            return .prefix(known)
        }
        if let parts = Families.split(name), parts.looksRandom { return .family(parts.key) }
        return .exact(name)
    }

    public func matches(_ name: String) -> Bool {
        switch self {
        case .family(let key): Families.split(name)?.key == key
        case .exact(let exact): name == exact
        case .prefix(let prefix): name.hasPrefix(prefix)
        }
    }

    /// "e2e-run-*", "node_modules".
    public var display: String {
        switch self {
        case .family(let key): Families.display(key)
        case .exact(let name): name
        case .prefix(let prefix): prefix + "*"
        }
    }

    /// Whether many folders can match: a family or a prefix, not one name.
    var isFamily: Bool {
        if case .exact = self { return false }
        return true
    }
}

/// A place where the person deleted leftovers: one folder, one rule, one
/// name pattern, learned from the deletion log.
public struct Spot: Sendable, Hashable, Identifiable {
    public var id: String { "\(rule.rawValue)|\(folder.path)|\(pattern.display)" }
    public let rule: RuleID
    public let folder: URL
    public let pattern: NamePattern
    /// Deletion runs: lines more than 10 minutes apart start a new one.
    public var cleanings: Int
    public var itemsDeleted: Int
    public var bytesFreed: Int64
    public var firstCleaned: Date
    public var lastCleaned: Date
}

/// One line of ~/Library/Logs/Lapang/deleted.log.
struct LogLine: Sendable, Equatable {
    let time: Date
    let rule: RuleID
    let bytes: Int64
    let path: String
}

/// What one learned spot holds now.
public struct SpotReport: Sendable, Identifiable {
    public var id: String { spot.id }
    public let spot: Spot
    /// Folders there now that the spot's rule would list, largest first.
    public let items: [Item]
    public let checkedAt: Date
    /// False when the spot's folder no longer exists (a session that ended).
    public let folderExists: Bool

    public init(spot: Spot, items: [Item], checkedAt: Date, folderExists: Bool = true) {
        self.spot = spot
        self.items = items.sorted { $0.bytes > $1.bytes }
        self.checkedAt = checkedAt
        self.folderExists = folderExists
    }

    /// Made after the last time this spot was cleaned.
    public var back: [Item] { items.filter { $0.created > spot.lastCleaned } }
    public var backBytes: Int64 { back.reduce(0) { $0 + $1.bytes } }
    public var cleanable: [Item] { items.filter { $0.isIdle(at: checkedAt) } }
    public var cleanableBytes: Int64 { cleanable.reduce(0) { $0 + $1.bytes } }

    /// What came back per day since the last clean. Nil before half a day has
    /// passed: a few hours say little about a day.
    public var bytesPerDay: Double? {
        let elapsed = checkedAt.timeIntervalSince(spot.lastCleaned)
        guard elapsed >= 12 * 3600 else { return nil }
        return Double(backBytes) / (elapsed / 86400)
    }

    /// The same report under another idle setting; nothing is measured again.
    public func withIdle(_ idle: TimeInterval) -> SpotReport {
        SpotReport(spot: spot, items: items.map { $0.withIdle(idle) }, checkedAt: checkedAt, folderExists: folderExists)
    }
}

/// Learns from the deletion log where leftovers come back, and looks there
/// again. Lapang writes the log; it stays on this Mac.
public enum DeletionHistory {
    /// The rules whose items are named in a shared folder, so a new one with
    /// the same kind of name is the same leftover coming back. Claude
    /// sessions and subagent logs are new by design every time.
    static let learnedRules: Set<RuleID> = [.browserProfiles, .headlessScratch, .repeatedCopies, .projectFolders]

    /// The spots in the log at `url`; none when there is no log yet.
    public static func spots(fromLog url: URL) -> [Spot] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return spots(from: parse(text))
    }

    static func parse(_ text: String) -> [LogLine] {
        let dates = ISO8601DateFormatter()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5,
                  let time = dates.date(from: String(fields[0])),
                  let rule = RuleID(rawValue: String(fields[1])),
                  fields[2] == "deleted" || fields[2].hasPrefix("partly deleted"),
                  let bytes = Int64(fields[3]),
                  fields[4].hasPrefix("/")
            else { return nil }
            return LogLine(time: time, rule: rule, bytes: bytes, path: String(fields[4]))
        }
    }

    /// Groups deletions by folder, rule and name pattern. A family is learned
    /// from one deletion; one exact name only once it was deleted twice, so a
    /// project's node_modules deleted once is not watched for ever.
    static func spots(from lines: [LogLine]) -> [Spot] {
        struct Key: Hashable { let rule: RuleID; let folder: String; let pattern: NamePattern }
        var groups: [Key: [LogLine]] = [:]
        for line in lines where learnedRules.contains(line.rule) {
            let url = URL(fileURLWithPath: line.path)
            let key = Key(
                rule: line.rule, folder: url.deletingLastPathComponent().path,
                pattern: NamePattern.learned(from: url.lastPathComponent, rule: line.rule)
            )
            groups[key, default: []].append(line)
        }
        return groups.compactMap { key, lines -> Spot? in
            guard key.pattern.isFamily || lines.count >= 2 else { return nil }
            let times = lines.map(\.time).sorted()
            var cleanings = 1
            for (earlier, later) in zip(times, times.dropFirst()) where later.timeIntervalSince(earlier) > 600 {
                cleanings += 1
            }
            return Spot(
                rule: key.rule, folder: URL(fileURLWithPath: key.folder, isDirectory: true), pattern: key.pattern,
                cleanings: cleanings, itemsDeleted: lines.count, bytesFreed: lines.reduce(0) { $0 + $1.bytes },
                firstCleaned: times.first!, lastCleaned: times.last!
            )
        }.sorted { $0.lastCleaned > $1.lastCleaned }
    }

    /// Looks in each spot's folder again: every folder there that matches the
    /// spot and that its rule would still list, measured. Reads each folder's
    /// names once however many spots share it. Throws CancellationError when
    /// the calling task is cancelled.
    public static func check(
        _ spots: [Spot], in places: Places, settings: RuleSettings, now: Date = Date()
    ) throws -> [SpotReport] {
        var listings: [String: [String]?] = [:]
        return try spots.map { spot in
            if listings[spot.folder.path] == nil {
                listings[spot.folder.path] = .some(try? FileManager.default.contentsOfDirectory(atPath: spot.folder.path))
            }
            guard let names = listings[spot.folder.path] ?? nil else {
                return SpotReport(spot: spot, items: [], checkedAt: now, folderExists: false)
            }
            var items: [Item] = []
            for name in names.sorted() where spot.pattern.matches(name) {
                try Task.checkCancellation()
                let url = spot.folder.appending(path: name, directoryHint: .isDirectory)
                guard let root = Rules.root(of: url, for: spot.rule, in: places),
                      let info = FileSystem.info(url),
                      let stats = try? Scanner.measure(url)
                else { continue }
                items.append(Item(
                    rule: spot.rule, url: url, root: root,
                    bytes: stats.freeableBytes, diskBytes: stats.allocatedBytes, files: stats.files,
                    created: info.created, lastChange: stats.newestChange, idleNeeded: settings.idle(for: spot.rule)
                ))
            }
            return SpotReport(spot: spot, items: items, checkedAt: now)
        }
    }
}
