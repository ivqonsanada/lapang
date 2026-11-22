import Foundation

/// Rule 5: pnpm's stores and npm's cache. They rebuild themselves, so
/// cleaning them is safe; the next install downloads again what it needs.
///
/// pnpm keeps one store per store layout (store/v3 for pnpm 9, v10, v11 for
/// pnpm 11 and 12), and a project's "packageManager" field makes pnpm switch
/// to that version, kept in <pnpm home>/.tools/pnpm/<version>. On this Mac the
/// global pnpm 10 has an empty v10 while pnpm 12 filled v11 with 11.5 GB, so
/// every installed version is asked for its store, and each store is pruned
/// by the version that owns it.
public struct PackageCache: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case pnpm, npm
    }

    public var id: String { folder.path }
    public let kind: Kind
    /// The version that owns this store, when known ("12.3.4").
    public let version: String?
    public let tool: URL
    /// The folder the clean command empties.
    public let folder: URL
    public let bytes: Int64

    public init(kind: Kind, version: String?, tool: URL, folder: URL, bytes: Int64) {
        self.kind = kind
        self.version = version
        self.tool = tool
        self.folder = folder
        self.bytes = bytes
    }

    public var arguments: [String] {
        switch kind {
        case .pnpm: ["store", "prune"]
        case .npm: ["cache", "clean", "--force"]
        }
    }

    /// The command as shown to the person.
    public var commandLine: String {
        ([kind.rawValue] + arguments).joined(separator: " ")
    }

    /// "pnpm 12.3.4", "pnpm", "npm".
    public var name: String {
        [kind.rawValue, version].compactMap { $0 }.joined(separator: " ")
    }
}

public enum PackageCaches {
    /// Commands run from an empty folder of Lapang's own, where no
    /// package.json can make pnpm switch versions. Not /: pnpm 9 and 10 write
    /// a temp file in the current folder, and / is read-only.
    static var neutralFolder: URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "lapang-commands", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Finds pnpm (every installed version) and npm on the person's PATH,
    /// asks each for its cache folder, and measures it. Tools that are not
    /// installed and stores that hold no files are left out.
    public static func scan(_ environment: ShellEnvironment) async -> [PackageCache] {
        var caches: [PackageCache] = []
        var seen = Set<String>()
        let tools = pnpmTools(environment).map { (PackageCache.Kind.pnpm, $0.version, $0.tool) }
            + [environment.find("npm")].compactMap { $0 }.map { (PackageCache.Kind.npm, String?.none, $0) }
        for (kind, version, tool) in tools {
            guard !Task.isCancelled,
                  let folder = await cacheFolder(kind, tool: tool, environment: environment),
                  !seen.contains(folder.standardizedFileURL.path),
                  FileSystem.isRealFolder(folder),
                  let stats = try? Scanner.measure(folder),
                  stats.files > 0
            else { continue }
            seen.insert(folder.standardizedFileURL.path)
            caches.append(PackageCache(kind: kind, version: version, tool: tool, folder: folder, bytes: stats.allocatedBytes))
        }
        return caches
    }

    /// pnpm's own versions in <pnpm home>/.tools/pnpm, newest first, then the
    /// pnpm on PATH. pnpm installs a version into 12.3.4_tmp_66143 and links
    /// 12.3.4 to it, so only the clean version names count (links followed:
    /// these are only run, never deleted); half-installed and .broken ones
    /// are skipped.
    static func pnpmTools(_ environment: ShellEnvironment) -> [(version: String?, tool: URL)] {
        guard let global = environment.find("pnpm") else { return [] }
        let home = global.resolvingSymlinksInPath().deletingLastPathComponent()
        let toolsFolder = home.appending(path: ".tools/pnpm", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: toolsFolder.path)) ?? []
        let versions = names
            .filter { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        var tools: [(version: String?, tool: URL)] = versions.compactMap { version in
            let tool = home.appending(path: ".tools/pnpm/\(version)/bin/pnpm")
            return FileManager.default.isExecutableFile(atPath: tool.path) ? (version, tool) : nil
        }
        tools.append((nil, global))
        return tools
    }

    static func cacheFolder(_ kind: PackageCache.Kind, tool: URL, environment: ShellEnvironment) async -> URL? {
        let arguments = kind == .pnpm ? ["store", "path"] : ["config", "get", "cache"]
        guard let result = try? await CommandRunner.run(
                  tool, arguments, path: environment.path, timeout: 30, directory: neutralFolder),
              result.succeeded,
              let line = result.output.split(separator: "\n").last(where: { $0.hasPrefix("/") })
        else { return nil }
        let folder = URL(fileURLWithPath: String(line).trimmingCharacters(in: .whitespaces), isDirectory: true)
        // npm cache clean empties _cacache; the rest of ~/.npm is logs and settings.
        return kind == .npm ? folder.appending(path: "_cacache", directoryHint: .isDirectory) : folder
    }

    /// Runs the clean command (pruning a large store takes a few minutes).
    public static func clean(_ cache: PackageCache, _ environment: ShellEnvironment) async throws -> CommandResult {
        try await CommandRunner.run(
            cache.tool, cache.arguments, path: environment.path, timeout: 30 * 60, directory: neutralFolder)
    }
}
