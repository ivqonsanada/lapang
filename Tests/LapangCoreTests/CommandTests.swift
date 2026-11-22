import Foundation
import Testing
@testable import LapangCore

/// Writes an executable shell script into tree/bin.
@discardableResult
private func script(_ tree: TempTree, _ name: String, _ body: String) throws -> URL {
    let url = try tree.file("bin/\(name)")
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    chmod(url.path, 0o755)
    return url
}

@Suite struct ShellEnvironmentTests {
    @Test func readsThePathBetweenTheMarkers() {
        let output = "    exec zsh\nsome banner\n__LAPANG_PATH__/a/bin:/usr/bin__LAPANG_PATH__\n"
        #expect(ShellEnvironment.parsePath(output) == "/a/bin:/usr/bin")
        #expect(ShellEnvironment.parsePath("no markers here") == nil)
        #expect(ShellEnvironment.parsePath("__LAPANG_PATH____LAPANG_PATH__") == nil)
    }

    @Test func findsTheFirstExecutableOnThePath() throws {
        let tree = try TempTree()
        try tree.file("one/pnpm")  // not executable
        let wanted = try script(tree, "pnpm", "echo hi")
        let environment = ShellEnvironment(path: "\(tree.url("one").path):\(tree.url("bin").path):/usr/bin")
        #expect(environment.find("pnpm") == wanted)
        #expect(environment.find("nothing-called-this") == nil)
    }

    @Test func loadsThePathFromARealShell() async throws {
        let environment = try await ShellEnvironment.load(shell: URL(fileURLWithPath: "/bin/sh"))
        #expect(environment.path.contains("/usr/bin"))
    }
}

@Suite struct CommandRunnerTests {
    @Test func returnsTheStatusAndBothStreams() async throws {
        let tree = try TempTree()
        let tool = try script(tree, "tool", "echo out; echo err >&2; echo \"$PATH\"; exit 3")
        let result = try await CommandRunner.run(tool, [], path: "/custom/bin:/usr/bin:/bin", timeout: 10)
        #expect(result.status == 3)
        #expect(!result.succeeded)
        #expect(result.output.contains("out"))
        #expect(result.output.contains("err"))
        #expect(result.output.contains("/custom/bin:/usr/bin:/bin"))
        #expect(result.tail(1) == "/custom/bin:/usr/bin:/bin")
    }

    @Test func readsLongOutput() async throws {
        let tree = try TempTree()
        let tool = try script(tree, "long", "i=0; while [ $i -lt 20000 ]; do echo line-$i; i=$((i+1)); done")
        let result = try await CommandRunner.run(tool, [], path: "/usr/bin:/bin", timeout: 30)
        #expect(result.succeeded)
        #expect(result.tail(1) == "line-19999")
    }

    @Test func stopsAProgramThatRunsTooLong() async throws {
        let tree = try TempTree()
        let tool = try script(tree, "slow", "sleep 20")
        await #expect(throws: CommandError.timedOut) {
            try await CommandRunner.run(tool, [], path: "/usr/bin:/bin", timeout: 0.5)
        }
    }
}

@Suite struct PackageCacheTests {
    @Test func findsAndMeasuresBothCaches() async throws {
        let tree = try TempTree()
        try tree.file("store/v10/files/00/abc", bytes: 30_000)
        try tree.file("npm/_cacache/content/x", bytes: 20_000)
        try tree.file("npm/_logs/debug.log", bytes: 90_000)
        try script(tree, "pnpm", "[ \"$1 $2\" = 'store path' ] && echo '\(tree.url("store/v10").path)'")
        try script(tree, "npm", "echo 'npm notice something'; [ \"$1 $2 $3\" = 'config get cache' ] && echo '\(tree.url("npm").path)'")

        let caches = await PackageCaches.scan(ShellEnvironment(path: tree.url("bin").path + ":/usr/bin:/bin"))
        #expect(caches.map(\.kind) == [.pnpm, .npm])
        #expect(caches[0].folder.path == tree.url("store/v10").path)
        #expect(caches[0].bytes >= 30_000)
        #expect(caches[0].name == "pnpm")
        // Only _cacache, not the logs next to it.
        #expect(caches[1].folder.lastPathComponent == "_cacache")
        #expect(caches[1].bytes >= 20_000 && caches[1].bytes < 90_000)
        #expect(caches[1].commandLine == "npm cache clean --force")
    }

    @Test func asksEveryInstalledPnpmForItsStore() async throws {
        // Like this Mac: the global pnpm 10 has an empty store, pnpm 12
        // (pinned by most projects) fills v11, pnpm 9 fills v3.
        let tree = try TempTree()
        try tree.folder("store/v10")
        try tree.file("store/v11/files/a", bytes: 40_000)
        try tree.file("store/v3/files/b", bytes: 20_000)
        func pnpm(_ relative: String, store: String) throws {
            try script(tree, relative, "pwd > '\(tree.url("cwd").path)'; [ \"$1 $2\" = 'store path' ] && echo '\(tree.url(store).path)'")
        }
        try pnpm("pnpm", store: "store/v10")
        // pnpm's layout: the version name is a link to a _tmp_ folder.
        try pnpm(".tools/pnpm/12.3.4_tmp_66143/bin/pnpm", store: "store/v11")
        try tree.symlink("bin/.tools/pnpm/12.3.4", to: "12.3.4_tmp_66143")
        try pnpm(".tools/pnpm/9.15.9/bin/pnpm", store: "store/v3")
        try pnpm(".tools/pnpm/11.9.0_tmp_79085/bin/pnpm", store: "store/v11")
        try pnpm(".tools/pnpm/10.26.1_tmp_73361/bin/pnpm", store: "store/v10")
        try tree.symlink("bin/.tools/pnpm/10.26.1", to: "10.26.1_tmp_73361")

        let caches = await PackageCaches.scan(ShellEnvironment(path: tree.url("bin").path + ":/usr/bin:/bin"))
        #expect(caches.map(\.name) == ["pnpm 12.3.4", "pnpm 9.15.9"])
        #expect(caches.map(\.folder.lastPathComponent) == ["v11", "v3"])
        #expect(caches[0].tool.path.hasSuffix(".tools/pnpm/12.3.4/bin/pnpm"))
        // Run from Lapang's own empty, writable folder, so no project's
        // packageManager field switches versions.
        let cwd = try String(contentsOf: tree.url("cwd"), encoding: .utf8)
        #expect(cwd.trimmingCharacters(in: .whitespacesAndNewlines) == FileSystem.realPath(PackageCaches.neutralFolder))
        #expect(FileManager.default.isWritableFile(atPath: PackageCaches.neutralFolder.path))
    }

    @Test func leavesOutWhatIsNotInstalled() async throws {
        let tree = try TempTree()
        try tree.folder("bin")
        let caches = await PackageCaches.scan(ShellEnvironment(path: tree.url("bin").path))
        #expect(caches.isEmpty)
    }

    @Test func runsTheCleanCommand() async throws {
        let tree = try TempTree()
        try tree.file("store/v10/x")
        let marker = tree.url("ran")
        try script(tree, "pnpm", """
            [ "$1 $2" = 'store path' ] && echo '\(tree.url("store/v10").path)'
            [ "$1 $2" = 'store prune' ] && touch '\(marker.path)' && echo 'Removed 3 packages'
            exit 0
            """)
        let environment = ShellEnvironment(path: tree.url("bin").path + ":/usr/bin:/bin")
        let cache = try #require(await PackageCaches.scan(environment).first)
        let result = try await PackageCaches.clean(cache, environment)
        #expect(result.succeeded)
        #expect(result.tail(1) == "Removed 3 packages")
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}

@Suite struct GrowthWatchTests {
    private var small: GrowthWatch.Options {
        var options = GrowthWatch.Options()
        options.threshold = 100_000
        return options
    }

    @Test func namesTheDeepestFolderThatGrew() throws {
        let tree = try TempTree()
        let now = Date()
        try tree.file("AppSupport/Google/Chrome/OptGuideOnDeviceModel/2025/weights.bin", bytes: 400_000)
        try tree.file("AppSupport/Google/Chrome/Default/History", bytes: 20_000)
        try tree.file("AppSupport/Slack/old.db", bytes: 900_000)
        try tree.age("AppSupport/Slack", to: .daysAgo(3, from: now))

        let found = try GrowthWatch.scan(roots: [tree.url("AppSupport")], now: now, options: small)
        #expect(found.count == 1)
        #expect(found[0].url.path.hasSuffix("AppSupport/Google/Chrome/OptGuideOnDeviceModel"))
        #expect(found[0].bytes >= 400_000)
        #expect(found[0].files == 1)
    }

    @Test func namesTheParentWhenSmallChildrenAddUp() throws {
        let tree = try TempTree()
        for index in 0..<5 { try tree.file("root/a/b/c\(index)/file", bytes: 40_000) }
        let found = try GrowthWatch.scan(roots: [tree.url("root")], options: small)
        #expect(found.map(\.url.lastPathComponent) == ["b"])
    }

    @Test func namesAParentOnlyForWhatIsOutsideItsNamedChild() throws {
        let tree = try TempTree()
        try tree.file("root/a/b/big/file", bytes: 300_000)
        try tree.file("root/a/b/little/file", bytes: 20_000)
        try tree.file("root/a/other/file", bytes: 150_000)
        let found = try GrowthWatch.scan(roots: [tree.url("root")], options: small)
        let names = found.map(\.url.lastPathComponent)
        #expect(names == ["big", "other"])
        #expect(found.allSatisfy { !$0.spreadOut })
    }

    @Test func aParentShowsOnlyWhatIsNotListedBelowIt() throws {
        let tree = try TempTree()
        try tree.file("root/a/big/file", bytes: 300_000)
        for index in 0..<4 { try tree.file("root/a/small\(index)/file", bytes: 40_000) }
        let found = try GrowthWatch.scan(roots: [tree.url("root")], options: small)
        #expect(found.map(\.url.lastPathComponent) == ["big", "a"])
        let parent = found[1]
        #expect(parent.spreadOut)
        #expect(parent.files == 4)
        // The four small folders only, not big's 300 KB again.
        #expect(parent.bytes >= 160_000 && parent.bytes < 300_000)
    }

    @Test func skipsGitObjectsAndSymlinks() throws {
        let tree = try TempTree()
        try tree.file("root/proj/.git/objects/pack/p.pack", bytes: 500_000)
        try tree.file("root/proj/.git/index", bytes: 10_000)
        try tree.file("elsewhere/huge", bytes: 500_000)
        try tree.symlink("root/proj/link", to: tree.url("elsewhere").path)
        #expect(try GrowthWatch.scan(roots: [tree.url("root")], options: small).isEmpty)
    }

    @Test func skipsMissingRootsAndReportsProgress() throws {
        let tree = try TempTree()
        try tree.file("one/x/y", bytes: 200_000)
        var started: [String] = []
        let found = try GrowthWatch.scan(roots: [tree.url("missing"), tree.url("one")], options: small) {
            started.append($0.lastPathComponent)
        }
        #expect(started == ["one"])
        #expect(found.map(\.url.lastPathComponent) == ["x"])
    }
}
