import Foundation

/// Rule 5: pnpm's store and npm's cache. Both rebuild themselves, so
/// cleaning them is safe; the next install downloads again what it needs.
public struct PackageCache: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case pnpm, npm
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let tool: URL
    /// The folder the clean command empties.
    public let folder: URL
    public let bytes: Int64

    /// The command shown to the person and then run.
    public var arguments: [String] {
        switch kind {
        case .pnpm: ["store", "prune"]
        case .npm: ["cache", "clean", "--force"]
        }
    }

    public var commandLine: String {
        ([kind.rawValue] + arguments).joined(separator: " ")
    }
}

public enum PackageCaches {
    /// Finds pnpm and npm on the person's PATH, asks each where its cache is,
    /// and measures it. A tool that is not installed is left out.
    public static func scan(_ environment: ShellEnvironment) async -> [PackageCache] {
        var caches: [PackageCache] = []
        for kind in PackageCache.Kind.allCases {
            guard !Task.isCancelled,
                  let tool = environment.find(kind.rawValue),
                  let folder = await cacheFolder(kind, tool: tool, environment: environment),
                  FileSystem.isRealFolder(folder),
                  let stats = try? Scanner.measure(folder)
            else { continue }
            caches.append(PackageCache(kind: kind, tool: tool, folder: folder, bytes: stats.allocatedBytes))
        }
        return caches
    }

    static func cacheFolder(_ kind: PackageCache.Kind, tool: URL, environment: ShellEnvironment) async -> URL? {
        let arguments = kind == .pnpm ? ["store", "path"] : ["config", "get", "cache"]
        guard let result = try? await CommandRunner.run(tool, arguments, path: environment.path, timeout: 30),
              result.succeeded,
              let line = result.output.split(separator: "\n").last(where: { $0.hasPrefix("/") })
        else { return nil }
        let folder = URL(fileURLWithPath: String(line).trimmingCharacters(in: .whitespaces), isDirectory: true)
        // npm cache clean empties _cacache; the rest of ~/.npm is logs and settings.
        return kind == .npm ? folder.appending(path: "_cacache", directoryHint: .isDirectory) : folder
    }

    /// Runs the clean command (pruning a large store takes a few minutes).
    public static func clean(_ cache: PackageCache, _ environment: ShellEnvironment) async throws -> CommandResult {
        try await CommandRunner.run(cache.tool, cache.arguments, path: environment.path, timeout: 30 * 60)
    }
}
