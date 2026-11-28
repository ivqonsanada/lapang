import Foundation

public enum RuleID: String, Sendable, CaseIterable, Codable, Hashable, Identifiable {
    case browserProfiles
    case headlessScratch
    case claudeTemp
    case repeatedCopies
    case subagentLogs
    case projectFolders

    public var id: String { rawValue }
}

/// One thing a rule would delete: a folder, measured.
public struct Item: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let rule: RuleID
    public let url: URL
    /// The folder this item must stay inside. The deleter refuses anything
    /// whose real path is not under this one's real path.
    public let root: URL
    /// What deleting it would free (APFS private size, see FolderStats).
    public let bytes: Int64
    /// Its size on disk, as du counts it. More than `bytes` when its files
    /// share blocks with clones elsewhere, such as pnpm's store.
    public let diskBytes: Int64
    public let files: Int
    public let created: Date
    public let lastChange: Date
    /// How long nothing inside may have changed before it can be deleted.
    public let idleNeeded: TimeInterval

    public init(
        rule: RuleID, url: URL, root: URL, bytes: Int64, diskBytes: Int64? = nil, files: Int,
        created: Date, lastChange: Date, idleNeeded: TimeInterval
    ) {
        self.rule = rule
        self.url = url
        self.root = root
        self.bytes = bytes
        self.diskBytes = diskBytes ?? bytes
        self.files = files
        self.created = created
        self.lastChange = lastChange
        self.idleNeeded = idleNeeded
    }

    public func isIdle(at now: Date) -> Bool {
        now.timeIntervalSince(lastChange) >= idleNeeded
    }

    /// The same item under another idle setting; nothing is measured again.
    public func withIdle(_ idle: TimeInterval) -> Item {
        Item(
            rule: rule, url: url, root: root, bytes: bytes, diskBytes: diskBytes, files: files,
            created: created, lastChange: lastChange, idleNeeded: idle
        )
    }

    /// Bytes it shares with clones elsewhere, freed only when those go too.
    public var sharedBytes: Int64 { max(diskBytes - bytes, 0) }
}

/// The settings a person can change. Times in seconds.
public struct RuleSettings: Sendable, Equatable, Codable {
    public var browserIdle: TimeInterval = 2 * 3600
    public var scratchIdle: TimeInterval = 2 * 3600
    public var claudeTempIdle: TimeInterval = 2 * 86400
    public var subagentAge: TimeInterval = 3 * 86400
    public var projectIdle: TimeInterval = 7 * 86400
    public var copiesIdle: TimeInterval = 6 * 3600
    /// A family of repeated copies is listed only when its folders take this
    /// much on disk in all. Thousands of empty mktemp folders are clutter,
    /// not a reason to look.
    public var copiesMinimumBytes: Int64 = 100_000_000

    public init() {}

    /// Settings saved by an older version lack the newer keys; those take
    /// their defaults instead of throwing the saved ones away.
    public init(from decoder: any Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RuleSettings()
        browserIdle = try saved.decodeIfPresent(TimeInterval.self, forKey: .browserIdle) ?? defaults.browserIdle
        scratchIdle = try saved.decodeIfPresent(TimeInterval.self, forKey: .scratchIdle) ?? defaults.scratchIdle
        claudeTempIdle = try saved.decodeIfPresent(TimeInterval.self, forKey: .claudeTempIdle) ?? defaults.claudeTempIdle
        subagentAge = try saved.decodeIfPresent(TimeInterval.self, forKey: .subagentAge) ?? defaults.subagentAge
        projectIdle = try saved.decodeIfPresent(TimeInterval.self, forKey: .projectIdle) ?? defaults.projectIdle
        copiesIdle = try saved.decodeIfPresent(TimeInterval.self, forKey: .copiesIdle) ?? defaults.copiesIdle
        copiesMinimumBytes = try saved.decodeIfPresent(Int64.self, forKey: .copiesMinimumBytes) ?? defaults.copiesMinimumBytes
    }

    public func idle(for rule: RuleID) -> TimeInterval {
        switch rule {
        case .browserProfiles: browserIdle
        case .headlessScratch: scratchIdle
        case .claudeTemp: claudeTempIdle
        case .repeatedCopies: copiesIdle
        case .subagentLogs: subagentAge
        case .projectFolders: projectIdle
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
    /// Items left alone because something inside changed recently.
    public var inUse: Int { items.count - cleanable.count }
    public var oldest: Date? { items.map(\.created).min() }

    /// The same report under another idle setting, as of the same scan.
    public func withIdle(_ idle: TimeInterval) -> RuleReport {
        RuleReport(rule: rule, items: items.map { $0.withIdle(idle) }, scannedAt: scannedAt, unreadable: unreadable)
    }
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
            return isChromeProfile(folder)
        }.map { Candidate(url: $0, root: root) }
    }

    /// Entries only a Chromium profile's Default folder holds. Preferences
    /// alone is not enough: a test browser that was killed can leave a
    /// profile without it, holding only caches and storage.
    static let chromeProfileMarkers = [
        "Preferences", "Cookies", "Session Storage", "Local Storage", "GPUCache", "Service Worker",
    ]

    static func isChromeProfile(_ folder: URL) -> Bool {
        let profile = folder.appending(path: "Default", directoryHint: .isDirectory)
        guard FileSystem.isRealFolder(profile) else { return false }
        return chromeProfileMarkers.contains { FileSystem.info(profile.appending(path: $0)) != nil }
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

    /// Folder names rule 5 looks for. Each is made again by an install or a
    /// build: node_modules by npm, pnpm, yarn or bun, .next by Next.js,
    /// .open-next by OpenNext, vendor by Composer.
    public static let projectFolderNames: Set<String> = ["node_modules", ".next", ".open-next", "vendor"]

    static let nodeLockfiles = [
        "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb",
    ]

    /// Rule 5. node_modules, .next and .open-next beside a package.json whose
    /// project (or workspace above it, up to `root`) has a lockfile, and
    /// vendor beside composer.json and composer.lock. A vendor folder without
    /// them is source (Laravel's resources/views/vendor, lang/vendor). The
    /// lockfile keeps out packages installed by a tool, which ship a
    /// package.json but no lockfile.
    static func isProjectFolder(_ folder: URL, under root: URL) -> Bool {
        func has(_ dir: URL, _ name: String) -> Bool {
            FileSystem.info(dir.appending(path: name, directoryHint: .notDirectory))?.isFile == true
        }
        let parent = folder.deletingLastPathComponent()
        if folder.lastPathComponent == "vendor" {
            return has(parent, "composer.json") && has(parent, "composer.lock")
        }
        guard has(parent, "package.json") else { return false }
        let rootDepth = root.standardizedFileURL.pathComponents.count
        var dir = parent
        while dir.standardizedFileURL.pathComponents.count >= rootDepth {
            if nodeLockfiles.contains(where: { has(dir, $0) }) { return true }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }
        return false
    }

    /// Walks every project root for rule 5's folders. Never looks inside one
    /// it found (a nested node_modules is part of its parent's), inside .git,
    /// or through a symlink. Each folder's root is its own project folder, so
    /// the deleter takes nothing else.
    public static func projectFolders(_ places: Places) throws -> [Candidate] {
        var found: [Candidate] = []
        for root in places.projectRoots {
            try Walker.walk(root.path) { entry, fts in
                guard Int32(entry.pointee.fts_info) == FTS_D, entry.pointee.fts_level > 0 else { return }
                let name = Walker.name(entry)
                if name == ".git" { Walker.skip(fts, entry); return }
                guard projectFolderNames.contains(name) else { return }
                let url = URL(fileURLWithPath: String(cString: entry.pointee.fts_path), isDirectory: true)
                let belongs = isProjectFolder(url, under: root)
                if belongs {
                    found.append(Candidate(url: url, root: url.deletingLastPathComponent()))
                }
                // A vendor folder that is source may hold more source; the rest
                // hold only what an install put there.
                if belongs || name != "vendor" { Walker.skip(fts, entry) }
            }
        }
        return found
    }

    /// Rule 6. Folders a script made once per run and never removed: three
    /// or more siblings with one name and a random ending (see Families), in
    /// $TMPDIR, in /private/tmp and in the scratchpad of every Claude Code
    /// session that is still running. A session that went idle is rule 3's,
    /// whole. Folders rules 1 and 2 already list are left to them.
    public static func repeatedCopies(_ places: Places, settings: RuleSettings, now: Date) -> [Candidate] {
        var claimed = Set((browserProfiles(places) + headlessScratch(places)).map(\.url.path))
        claimed.insert(places.claudeTemp.path)
        let roots = [places.userTemp, places.sharedTemp]
            + liveScratchpads(places, idle: settings.claudeTempIdle, now: now)
        return roots.flatMap { root -> [Candidate] in
            let folders = FileSystem.subfolders(of: root).filter { !claimed.contains($0.path) }
            let byName = Dictionary(folders.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
            return Families.group(Array(byName.keys)).values
                .flatMap { $0 }
                .compactMap { byName[$0] }
                .sorted { $0.path < $1.path }
                .map { Candidate(url: $0, root: root) }
        }
    }

    /// The scratchpad of each Claude Code session where something was done
    /// within `idle`: the session folder, its scratchpad or anything directly
    /// in either changed. That reads a few names per session; rule 3 measures
    /// everything inside, so a session live here is never idle for rule 3.
    static func liveScratchpads(_ places: Places, idle: TimeInterval, now: Date) -> [URL] {
        FileSystem.subfolders(of: places.claudeTemp).flatMap { project in
            FileSystem.subfolders(of: project).compactMap { session -> URL? in
                let scratchpad = session.appending(path: "scratchpad", directoryHint: .isDirectory)
                guard FileSystem.isRealFolder(scratchpad) else { return nil }
                let newest = [session, scratchpad].flatMap { folder -> [Date] in
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                    return [FileSystem.info(folder)?.modified]
                        .compactMap { $0 }
                        + names.compactMap { FileSystem.info(folder.appending(path: $0))?.modified }
                }.max() ?? .distantPast
                return now.timeIntervalSince(newest) < idle ? scratchpad : nil
            }
        }
    }

    public static func candidates(
        for rule: RuleID, in places: Places, settings: RuleSettings = RuleSettings(), now: Date = Date()
    ) throws -> [Candidate] {
        switch rule {
        case .browserProfiles: browserProfiles(places)
        case .headlessScratch: headlessScratch(places)
        case .claudeTemp: claudeTemp(places)
        case .repeatedCopies: repeatedCopies(places, settings: settings, now: now)
        case .subagentLogs: subagentLogs(places)
        case .projectFolders: try projectFolders(places)
        }
    }

    /// Whether `folder`, found again after a deletion, is something `rule`
    /// looks after, with `root` the folder the deleter must keep it inside.
    /// Nil for rules whose items are not named in a shared folder (3 and 4),
    /// and for a folder the rule would not list.
    static func root(of folder: URL, for rule: RuleID, in places: Places) -> URL? {
        guard FileSystem.isRealFolder(folder) else { return nil }
        let name = folder.lastPathComponent
        let parent = folder.deletingLastPathComponent()
        func same(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }
        switch rule {
        case .browserProfiles:
            guard same(parent, places.userTemp), !name.hasPrefix("scoped_dir"),
                  profilePrefixes.contains(where: name.hasPrefix) || isChromeProfile(folder)
            else { return nil }
            return places.userTemp
        case .headlessScratch:
            guard name.hasPrefix("scoped_dir"),
                  same(parent, places.userTemp) || same(parent, places.chromeHeadlessCache)
            else { return nil }
            return parent
        case .repeatedCopies:
            let inTemp = same(parent, places.userTemp) || same(parent, places.sharedTemp)
            // <claude-uid>/<project>/<session>/scratchpad
            let session = parent.deletingLastPathComponent()
            let inScratchpad = parent.lastPathComponent == "scratchpad"
                && same(session.deletingLastPathComponent().deletingLastPathComponent(), places.claudeTemp)
            guard inTemp || inScratchpad, Families.split(name) != nil,
                  !Families.looksLikeAnAppsOwn(name),
                  root(of: folder, for: .browserProfiles, in: places) == nil,
                  root(of: folder, for: .headlessScratch, in: places) == nil
            else { return nil }
            return parent
        case .projectFolders:
            guard projectFolderNames.contains(name), isProjectFolder(folder, under: places.home) else { return nil }
            return parent
        case .claudeTemp, .subagentLogs:
            return nil
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
        for candidate in try candidates(for: rule, in: places, settings: settings, now: now) {
            try Task.checkCancellation()
            guard let info = FileSystem.info(candidate.url), info.isFolder,
                  let stats = try? Scanner.measure(candidate.url)
            else { unreadable += 1; continue }
            items.append(Item(
                rule: rule, url: candidate.url, root: candidate.root,
                bytes: stats.freeableBytes, diskBytes: stats.allocatedBytes, files: stats.files,
                created: info.created, lastChange: stats.newestChange, idleNeeded: idle
            ))
        }
        if rule == .repeatedCopies {
            items = CopyFamily.families(of: items)
                .filter { $0.diskBytes >= settings.copiesMinimumBytes }
                .flatMap(\.items)
        }
        return RuleReport(rule: rule, items: items, scannedAt: now, unreadable: unreadable)
    }
}

/// Repeated copies that share a folder and a family key, e.g. the 110
/// checkout.* folders in one session's scratchpad.
public struct CopyFamily: Sendable, Identifiable {
    public var id: String { folder.path + "/" + key }
    public let folder: URL
    public let key: String
    /// Largest first.
    public let items: [Item]

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var diskBytes: Int64 { items.reduce(0) { $0 + $1.diskBytes } }

    /// Largest first, by what deleting frees.
    public static func families(of items: [Item]) -> [CopyFamily] {
        let grouped = Dictionary(grouping: items) { item in
            FamilyID(folder: item.url.deletingLastPathComponent().path, key: Families.split(item.url.lastPathComponent)?.key ?? item.url.lastPathComponent)
        }
        return grouped.map { id, members in
            CopyFamily(
                folder: URL(fileURLWithPath: id.folder, isDirectory: true), key: id.key,
                items: members.sorted { $0.bytes > $1.bytes }
            )
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
    }

    private struct FamilyID: Hashable {
        let folder: String
        let key: String
    }
}

extension RuleReport {
    /// The report's items by family (meaningful for repeated copies).
    public var families: [CopyFamily] { CopyFamily.families(of: items) }
}
