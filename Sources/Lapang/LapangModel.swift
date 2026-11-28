import AppKit
import LapangCore
import Observation
import SwiftUI

/// One thing the window shows: the last value, whether it is being measured
/// again, and the last error. The value stays on screen while a new scan runs.
struct Slot<Value> {
    var value: Value?
    var running = false
    var error: String?
}

/// The settings a person can change, kept in UserDefaults.
struct AppSettings: Codable, Equatable {
    var rules = RuleSettings()
}

/// Free space at one scan, kept so the next scan can say what changed.
struct ScanMark: Codable, Equatable {
    var free: Int64
    var date: Date
}

/// Runs blocking work (fts walks, deleting) off the main actor. The work
/// runs in the caller's task, so cancelling that task stops it.
@concurrent
func offMain<T: Sendable>(_ work: @Sendable () throws -> T) async throws -> T {
    try work()
}

@MainActor
@Observable
final class LapangModel {
    static let shared = LapangModel()

    let places = Places.thisMac()
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save(settings, as: "settings")
            for rule in RuleID.allCases {
                if let report = rules[rule]?.value {
                    rules[rule]?.value = report.withIdle(settings.rules.idle(for: rule))
                }
            }
            if let reports = history.value {
                history.value = reports.map { $0.withIdle(settings.rules.idle(for: $0.spot.rule)) }
            }
        }
    }

    var space: VolumeSpace?
    var spaceError: String?
    /// Free space at the scan before this one.
    var previousScan: ScanMark?
    var lastScan: Date?

    var rules: [RuleID: Slot<RuleReport>] = Dictionary(uniqueKeysWithValues: RuleID.allCases.map { ($0, Slot()) })
    var caches = Slot<[PackageCache]>()
    var growth = Slot<[Growth]>()
    /// The root the growth watch is reading now.
    var growthRoot: URL?
    /// The places the deletion log says were cleaned, looked at again.
    var history = Slot<[SpotReport]>()
    var historyChecked: Date?

    /// Bytes the row under the pointer would free, drawn on the capacity bar.
    var preview: Int64 = 0

    /// The open review sheet, if any.
    var reviewing: RuleID?
    /// The open review sheet of one place that refilled, if any.
    var reviewingSpot: SpotReport?
    var cleaningCaches = false

    private var tasks: [String: Task<Void, Never>] = [:]
    private var shell: ShellEnvironment?
    private var started = false

    private init() {
        settings = Self.load("settings") ?? AppSettings()
    }

    var isScanning: Bool {
        rules.values.contains(where: \.running) || caches.running || growth.running
    }

    var scanStatus: String {
        if rules.values.contains(where: \.running) { return "Measuring leftovers" }
        if caches.running { return "Measuring package caches" }
        if growth.running, let root = growthRoot { return "Looking in \(Format.path(root, home: places.home))" }
        return "Scanning"
    }

    func report(_ rule: RuleID) -> RuleReport? {
        rules[rule]?.value
    }

    var deletionLogExists: Bool {
        FileManager.default.fileExists(atPath: places.deletionLog.path)
    }

    // MARK: Scanning

    func start() {
        #if DEBUG
        if CommandLine.arguments.contains("--print-caches") { return }
        #endif
        guard !started else { return }
        started = true
        scanAll()
        tasks["space"] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.refreshSpace()
            }
        }
        tasks["historyTimer"] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.historyInterval))
                self?.checkHistory()
            }
        }
    }

    /// How often the places in the deletion log are looked at again.
    static let historyInterval: TimeInterval = 15 * 60

    /// Tasks Stop leaves running: the timers, and the history check, which is
    /// quick and shows its progress in its own section.
    private static let lasting: Set<String> = ["space", "historyTimer", "history"]

    func scanAll() {
        stopScan()
        refreshSpace()
        previousScan = Self.load("lastScan")
        if let space {
            save(ScanMark(free: space.free, date: Date()), as: "lastScan")
        }
        lastScan = Date()
        for rule in RuleID.allCases { scan(rule) }
        scanCaches()
        scanGrowth()
        checkHistory()
    }

    func stopScan() {
        for (key, task) in tasks where !Self.lasting.contains(key) {
            task.cancel()
            tasks[key] = nil
        }
        for rule in RuleID.allCases { rules[rule]?.running = false }
        caches.running = false
        growth.running = false
        growthRoot = nil
    }

    func refreshSpace() {
        do {
            let fresh = try FreeSpace.read(at: places.home)
            if fresh != space { space = fresh }
            spaceError = nil
        } catch {
            spaceError = error.localizedDescription
        }
    }

    func scan(_ rule: RuleID) {
        tasks[rule.rawValue]?.cancel()
        rules[rule]?.running = true
        rules[rule]?.error = nil
        let places = places
        let rules = settings.rules
        tasks[rule.rawValue] = Task { [weak self] in
            do {
                let report = try await offMain { try Rules.scan(rule, in: places, settings: rules) }
                self?.rules[rule] = Slot(value: report)
            } catch is CancellationError {
                return
            } catch {
                self?.rules[rule]?.running = false
                self?.rules[rule]?.error = error.localizedDescription
            }
        }
    }

    func scanCaches() {
        tasks["caches"]?.cancel()
        caches.running = true
        caches.error = nil
        tasks["caches"] = Task { [weak self] in
            guard let self else { return }
            do {
                let environment = try await shellEnvironment()
                let found = await PackageCaches.scan(environment)
                try Task.checkCancellation()
                caches = Slot(value: found)
            } catch is CancellationError {
                return
            } catch {
                caches.running = false
                caches.error = error.localizedDescription
            }
        }
    }

    func scanGrowth() {
        tasks["growth"]?.cancel()
        growth.running = true
        growth.error = nil
        let roots = places.growthRoots
        tasks["growth"] = Task { [weak self] in
            do {
                let found = try await offMain {
                    try GrowthWatch.scan(roots: roots) { root in
                        Task { @MainActor in self?.growthRoot = root }
                    }
                }
                self?.growth = Slot(value: found)
                self?.growthRoot = nil
            } catch is CancellationError {
                return
            } catch {
                self?.growth.running = false
                self?.growth.error = error.localizedDescription
            }
        }
    }

    /// The log the history is learned from. Debug builds take
    /// --history-log=<file>, so a snapshot can show a history this Mac has not made.
    var historyLog: URL {
        #if DEBUG
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--history-log=") }) {
            return URL(fileURLWithPath: String(argument.dropFirst("--history-log=".count)))
        }
        #endif
        return places.deletionLog
    }

    /// Reads the deletion log and looks again in each place it names.
    func checkHistory() {
        tasks["history"]?.cancel()
        history.running = true
        history.error = nil
        let places = places
        let rules = settings.rules
        let log = historyLog
        tasks["history"] = Task { [weak self] in
            do {
                let reports = try await offMain {
                    try DeletionHistory.check(DeletionHistory.spots(fromLog: log), in: places, settings: rules)
                }
                self?.history = Slot(value: reports)
                self?.historyChecked = Date()
            } catch is CancellationError {
                return
            } catch {
                self?.history.running = false
                self?.history.error = error.localizedDescription
            }
        }
    }

    private func shellEnvironment() async throws -> ShellEnvironment {
        if let shell { return shell }
        let loaded = try await ShellEnvironment.load()
        shell = loaded
        return loaded
    }

    // MARK: Cleaning

    /// Deletes what the person confirmed, then measures the rule and the
    /// free space again. `progress` gets the number of items done.
    func delete(_ items: [Item], progress: @escaping @Sendable (Int) -> Void) async -> DeletionResult {
        let deleter = Deleter(log: places.deletionLog)
        let result = (try? await offMain { deleter.delete(items, progress: progress) }) ?? DeletionResult()
        refreshSpace()
        for rule in Set(items.map(\.rule)) { scan(rule) }
        checkHistory()
        return result
    }

    struct CleanOutcome: Sendable {
        let cache: PackageCache
        let output: String
        let succeeded: Bool
        let freed: Int64?
    }

    /// Runs one cache's clean command and measures its folder again.
    func clean(_ cache: PackageCache) async -> CleanOutcome {
        do {
            let environment = try await shellEnvironment()
            let result = try await PackageCaches.clean(cache, environment)
            let folder = cache.folder
            let after = try? await offMain { try Scanner.measure(folder) }
            let freed = after.map { max(0, cache.bytes - $0.allocatedBytes) }
            return CleanOutcome(cache: cache, output: result.tail(2), succeeded: result.succeeded, freed: freed)
        } catch CommandError.timedOut {
            return CleanOutcome(cache: cache, output: "Stopped after 30 minutes.", succeeded: false, freed: nil)
        } catch {
            return CleanOutcome(cache: cache, output: error.localizedDescription, succeeded: false, freed: nil)
        }
    }

    func cleaningFinished() {
        refreshSpace()
        scanCaches()
    }

    // MARK: Finder

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Storage

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, as key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
