import Foundation

public enum RuleID: String, Sendable, CaseIterable, Codable, Hashable {
    case browserProfiles
    case headlessScratch
    case claudeTemp
    case subagentLogs
}

/// One thing a rule would delete: a folder, measured.
public struct Item: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let rule: RuleID
    public let url: URL
    /// The folder this item must stay inside. The deleter refuses anything
    /// whose real path is not under this one's real path.
    public let root: URL
    public let bytes: Int64
    public let files: Int
    public let created: Date
    public let lastChange: Date
    /// How long nothing inside may have changed before it can be deleted.
    public let idleNeeded: TimeInterval

    public init(
        rule: RuleID, url: URL, root: URL, bytes: Int64, files: Int,
        created: Date, lastChange: Date, idleNeeded: TimeInterval
    ) {
        self.rule = rule
        self.url = url
        self.root = root
        self.bytes = bytes
        self.files = files
        self.created = created
        self.lastChange = lastChange
        self.idleNeeded = idleNeeded
    }

    public func isIdle(at now: Date) -> Bool {
        now.timeIntervalSince(lastChange) >= idleNeeded
    }
}

/// The settings a person can change. Times in seconds.
public struct RuleSettings: Sendable, Equatable, Codable {
    public var browserIdle: TimeInterval = 2 * 3600
    public var scratchIdle: TimeInterval = 2 * 3600
    public var claudeTempIdle: TimeInterval = 2 * 86400
    public var subagentAge: TimeInterval = 3 * 86400

    public init() {}

    public func idle(for rule: RuleID) -> TimeInterval {
        switch rule {
        case .browserProfiles: browserIdle
        case .headlessScratch: scratchIdle
        case .claudeTemp: claudeTempIdle
        case .subagentLogs: subagentAge
        }
    }
}

/// A folder a rule wants measured, and the root it belongs to.
public struct Candidate: Sendable, Hashable {
    public let url: URL
    public let root: URL
}

public struct RuleReport: Sendable {
    public let rule: RuleID
    /// Largest first.
    public let items: [Item]
    public let scannedAt: Date
    /// Candidates that could not be measured (vanished mid-scan, unreadable).
    public let unreadable: Int

    public init(rule: RuleID, items: [Item], scannedAt: Date, unreadable: Int = 0) {
        self.rule = rule
        self.items = items.sorted { $0.bytes > $1.bytes }
        self.scannedAt = scannedAt
        self.unreadable = unreadable
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var cleanable: [Item] { items.filter { $0.isIdle(at: scannedAt) } }
    public var cleanableBytes: Int64 { cleanable.reduce(0) { $0 + $1.bytes } }
    /// Items made in the 24 hours before the scan. A leak shows up here
    /// first: one project's check scripts once made about 100 browser profiles a day.
    public var newInLastDay: Int {
        items.filter { scannedAt.timeIntervalSince($0.created) < 86400 }.count
    }
    public var oldest: Date? { items.map(\.created).min() }
    public var newest: Date? { items.map(\.created).max() }
}

public enum Rules {
    /// Folder names Lapang knows as test browser profiles.
    public static let profilePrefixes = [
        "playwright_firefoxdev_profile-", "puppeteer_dev_firefox_profile-",
        "playwright_chromiumdev_profile-", "puppeteer_dev_chrome_profile-",
    ]

    /// Rule 1. Top-level folders in $TMPDIR that hold a Chrome profile
    /// (Default/Preferences inside) or carry a known test-profile prefix.
    /// scoped_dir folders belong to rule 2.
    public static func browserProfiles(_ places: Places) -> [Candidate] {
        let root = places.userTemp
        return FileSystem.subfolders(of: root).filter { folder in
            let name = folder.lastPathComponent
            if name.hasPrefix("scoped_dir") { return false }
            if profilePrefixes.contains(where: name.hasPrefix) { return true }
            return FileSystem.info(folder.appending(path: "Default/Preferences"))?.isFile == true
        }.map { Candidate(url: $0, root: root) }
    }

    /// Rule 2. Headless Chrome's scoped_dir folders, in its cache folder and
    /// in $TMPDIR.
    public static func headlessScratch(_ places: Places) -> [Candidate] {
        [places.chromeHeadlessCache, places.userTemp].flatMap { root in
            FileSystem.subfolders(of: root)
                .filter { $0.lastPathComponent.hasPrefix("scoped_dir") }
                .map { Candidate(url: $0, root: root) }
        }
    }

    /// Rule 3. Claude Code's session temp folders,
    /// /private/tmp/claude-<uid>/<project>/<session>.
    public static func claudeTemp(_ places: Places) -> [Candidate] {
        let root = places.claudeTemp
        return FileSystem.subfolders(of: root).flatMap { project in
            FileSystem.subfolders(of: project).map { Candidate(url: $0, root: root) }
        }
    }

    /// Rule 4. The subagents folder of each session,
    /// <account>/projects/<project>/<session>/subagents. Never a main
    /// transcript (those are files next to the session folders) and never
    /// anything under memory/.
    public static func subagentLogs(_ places: Places) -> [Candidate] {
        places.claudeAccounts.flatMap { account -> [Candidate] in
            let root = account.appending(path: "projects", directoryHint: .isDirectory)
            return FileSystem.subfolders(of: root).flatMap { project in
                FileSystem.subfolders(of: project)
                    .filter { $0.lastPathComponent != "memory" }
                    .map { $0.appending(path: "subagents", directoryHint: .isDirectory) }
                    .filter(FileSystem.isRealFolder)
                    .map { Candidate(url: $0, root: root) }
            }
        }
    }

    public static func candidates(for rule: RuleID, in places: Places) -> [Candidate] {
        switch rule {
        case .browserProfiles: browserProfiles(places)
        case .headlessScratch: headlessScratch(places)
        case .claudeTemp: claudeTemp(places)
        case .subagentLogs: subagentLogs(places)
        }
    }

    /// Finds and measures everything one rule looks after. Runs on the
    /// calling thread; throws CancellationError when its task is cancelled.
    public static func scan(
        _ rule: RuleID,
        in places: Places,
        settings: RuleSettings,
        now: Date = Date()
    ) throws -> RuleReport {
        let idle = settings.idle(for: rule)
        var items: [Item] = []
        var unreadable = 0
        for candidate in candidates(for: rule, in: places) {
            try Task.checkCancellation()
            guard let info = FileSystem.info(candidate.url), info.isFolder,
                  let stats = try? Scanner.measure(candidate.url)
            else { unreadable += 1; continue }
            items.append(Item(
                rule: rule, url: candidate.url, root: candidate.root,
                bytes: stats.allocatedBytes, files: stats.files,
                created: info.created, lastChange: stats.newestChange, idleNeeded: idle
            ))
        }
        return RuleReport(rule: rule, items: items, scannedAt: now, unreadable: unreadable)
    }
}
