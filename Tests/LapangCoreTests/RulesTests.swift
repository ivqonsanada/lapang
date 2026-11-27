import Foundation
import Testing
@testable import LapangCore

/// A fake Mac inside a temp folder.
private func fakeMac(_ tree: TempTree) throws -> Places {
    try tree.folder("home")
    try tree.folder("T")
    try tree.folder("tmp")
    return Places(home: tree.url("home"), userTemp: tree.url("T"), sharedTemp: tree.url("tmp"), uid: 501)
}

@Suite struct BrowserProfileRuleTests {
    @Test func findsKnownPrefixesAndChromeProfiles() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        try tree.file("T/puppeteer_dev_firefox_profile-abc123/Default/Cookies")
        try tree.file("T/playwright_chromiumdev_profile-x/Local State")
        try tree.file("T/someapp-profile/Default/Preferences")  // a Chrome profile by shape
        try tree.file("T/someapp-cache/Default/other")           // not a profile
        try tree.file("T/scoped_dir123/x")                      // rule 2's
        try tree.file("T/puppeteer_dev_firefox_profile-file")                     // a file, not a folder
        try tree.folder("elsewhere/Default")
        try tree.file("elsewhere/Default/Preferences")
        try tree.symlink("T/puppeteer_dev_firefox_profile-link", to: tree.url("elsewhere").path)

        let names = Rules.browserProfiles(places).map(\.url.lastPathComponent).sorted()
        #expect(names == ["playwright_chromiumdev_profile-x", "puppeteer_dev_firefox_profile-abc123", "someapp-profile"])
        #expect(Rules.browserProfiles(places).allSatisfy { $0.root == places.userTemp })
    }

    @Test func onlyIdleProfilesAreCleanable() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let now = Date()
        try tree.file("T/puppeteer_dev_firefox_profile-old/Default/Cookies", bytes: 4000)
        try tree.file("T/puppeteer_dev_firefox_profile-busy/Default/Cookies", bytes: 4000)
        try tree.age("T/puppeteer_dev_firefox_profile-old", to: .hoursAgo(3, from: now))
        try tree.age("T/puppeteer_dev_firefox_profile-busy", to: .hoursAgo(3, from: now))
        // Something inside the busy one was written 10 minutes ago.
        try tree.age("T/puppeteer_dev_firefox_profile-busy/Default/Cookies", to: .hoursAgo(0.17, from: now))

        let report = try Rules.scan(.browserProfiles, in: places, settings: RuleSettings(), now: now)
        #expect(report.items.count == 2)
        #expect(report.cleanable.map(\.url.lastPathComponent) == ["puppeteer_dev_firefox_profile-old"])
        #expect(report.cleanableBytes > 0 && report.cleanableBytes < report.totalBytes)
    }

    @Test func countsWhatAppearedInTheLastDay() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let now = Date()
        for index in 0..<5 { try tree.file("T/puppeteer_dev_firefox_profile-\(index)/Default/Cookies") }
        try tree.setCreated("T/puppeteer_dev_firefox_profile-0", to: .daysAgo(3, from: now))
        try tree.setCreated("T/puppeteer_dev_firefox_profile-1", to: .daysAgo(2, from: now))

        let report = try Rules.scan(.browserProfiles, in: places, settings: RuleSettings(), now: now)
        #expect(report.items.count == 5)
        #expect(report.newInLastDay == 3)
        #expect(abs(report.oldest!.timeIntervalSince(.daysAgo(3, from: now))) < 1)
    }
}

@Suite struct HeadlessScratchRuleTests {
    @Test func findsScopedDirsInTheCacheAndTheTempFolder() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        try tree.file("home/Library/Caches/Google/Chrome-headless/scoped_dir1/a")
        try tree.file("home/Library/Caches/Google/Chrome-headless/scoped_dir2/a")
        try tree.file("home/Library/Caches/Google/Chrome-headless/Default/a")
        try tree.file("T/scoped_dir9/a")

        let found = Rules.headlessScratch(places)
        #expect(found.map(\.url.lastPathComponent) == ["scoped_dir1", "scoped_dir2", "scoped_dir9"])
        #expect(found[0].root == places.chromeHeadlessCache)
        #expect(found[2].root == places.userTemp)
    }

    @Test func aMissingCacheFolderFindsNothing() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        #expect(Rules.headlessScratch(places).isEmpty)
        let report = try Rules.scan(.headlessScratch, in: places, settings: RuleSettings())
        #expect(report.items.isEmpty && report.totalBytes == 0)
    }
}

@Suite struct ClaudeTempRuleTests {
    @Test func takesSessionFoldersTwoLevelsDown() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let now = Date()
        try tree.file("tmp/claude-501/-Users-x-proj/aaaa/tasks/one.output", bytes: 3000)
        try tree.file("tmp/claude-501/-Users-x-proj/bbbb/scratchpad/notes.md")
        try tree.file("tmp/claude-501/-Users-x-other/cccc/tasks/t.output")
        try tree.file("tmp/claude-501/stray-file")
        try tree.file("tmp/claude-502/-Users-y/dddd/x")  // another user's
        try tree.age("tmp/claude-501", to: .daysAgo(3, from: now))
        try tree.age("tmp/claude-501/-Users-x-proj/bbbb/scratchpad/notes.md", to: .hoursAgo(5, from: now))

        let report = try Rules.scan(.claudeTemp, in: places, settings: RuleSettings(), now: now)
        #expect(report.items.map(\.url.lastPathComponent).sorted() == ["aaaa", "bbbb", "cccc"])
        // bbbb has a file from 5 hours ago, so it is a live session.
        #expect(report.cleanable.map(\.url.lastPathComponent).sorted() == ["aaaa", "cccc"])
        #expect(report.items.allSatisfy { $0.root == places.claudeTemp })
    }
}

@Suite struct SubagentLogRuleTests {
    @Test func takesOnlySubagentFoldersOfSessions() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let now = Date()
        let project = "home/.ccs/instances/main/projects/-Users-x-proj"
        try tree.file("\(project)/aaaa.jsonl", bytes: 9000)                   // main transcript
        try tree.file("\(project)/aaaa/subagents/agent-1.jsonl", bytes: 9000)
        try tree.file("\(project)/bbbb/subagents/agent-2.jsonl")
        try tree.file("\(project)/cccc/tool-results/r.txt")                  // no subagents
        try tree.file("\(project)/memory/MEMORY.md")
        try tree.file("\(project)/memory/subagents/x")                       // never under memory/
        try tree.file("home/.claude/projects/-Users-y/eeee/subagents/agent-3.jsonl")
        try tree.age("home", to: .daysAgo(10, from: now))
        try tree.age("\(project)/bbbb/subagents/agent-2.jsonl", to: .daysAgo(1, from: now))

        let report = try Rules.scan(.subagentLogs, in: places, settings: RuleSettings(), now: now)
        let paths = report.items.map { $0.url.path.replacingOccurrences(of: tree.root.path + "/", with: "") }.sorted()
        #expect(paths == [
            "home/.ccs/instances/main/projects/-Users-x-proj/aaaa/subagents",
            "home/.ccs/instances/main/projects/-Users-x-proj/bbbb/subagents",
            "home/.claude/projects/-Users-y/eeee/subagents",
        ])
        // bbbb's subagent wrote a day ago; the age setting is 3 days.
        #expect(report.cleanable.count == 2)
        #expect(!report.cleanable.contains { $0.url.path.contains("/bbbb/") })
        #expect(report.items.allSatisfy { $0.root.lastPathComponent == "projects" })
    }

    @Test func theAgeSettingIsUsed() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let now = Date()
        try tree.file("home/.claude/projects/p/s/subagents/a.jsonl")
        try tree.age("home", to: .daysAgo(5, from: now))
        var settings = RuleSettings()
        settings.subagentAge = 7 * 86400
        #expect(try Rules.scan(.subagentLogs, in: places, settings: settings, now: now).cleanable.isEmpty)
        settings.subagentAge = 4 * 86400
        let report = try Rules.scan(.subagentLogs, in: places, settings: settings, now: now)
        #expect(report.cleanable.count == 1)
        // A new setting applies to the report already made, without a scan.
        #expect(report.withIdle(7 * 86400).cleanable.isEmpty)
        #expect(report.withIdle(7 * 86400).inUse == 1)
    }
}

@Suite struct ProjectFolderRuleTests {
    private func relative(_ url: URL, _ tree: TempTree) -> String {
        url.path.replacingOccurrences(of: tree.root.path + "/", with: "")
    }

    @Test func findsDependencyAndBuildFoldersOfProjects() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        // An npm app with two builds, a package of a pnpm workspace, a Laravel app.
        try tree.file("home/code/app/package.json")
        try tree.file("home/code/app/package-lock.json")
        try tree.file("home/code/app/node_modules/react/index.js")
        try tree.file("home/code/app/node_modules/react/node_modules/x/index.js")  // part of the outer one
        try tree.file("home/code/app/.next/build-manifest.json")
        try tree.file("home/code/app/.open-next/worker.js")
        try tree.file("home/code/app/.git/node_modules/x")                        // inside .git
        try tree.file("home/code/mono/pnpm-lock.yaml")
        try tree.file("home/code/mono/packages/ui/package.json")
        try tree.file("home/code/mono/packages/ui/node_modules/.bin/tsc")
        try tree.file("home/code/site/composer.json")
        try tree.file("home/code/site/composer.lock")
        try tree.file("home/code/site/vendor/autoload.php")
        try tree.file("home/code/site/resources/views/vendor/mail/html.blade.php")  // source
        // Not a project someone works on.
        try tree.file("home/code/loose/node_modules/a/index.js")                  // no package.json
        try tree.file("home/code/tool/package.json")                              // no lockfile anywhere
        try tree.file("home/code/tool/node_modules/a/index.js")
        try tree.file("home/.vscode/extensions/ext/package.json")                 // a tool's
        try tree.file("home/.vscode/extensions/ext/package-lock.json")
        try tree.file("home/.vscode/extensions/ext/node_modules/a/index.js")
        try tree.file("home/Library/App/package.json")                            // Library is skipped
        try tree.file("home/Library/App/yarn.lock")
        try tree.file("home/Library/App/node_modules/a/index.js")
        try tree.file("home/code/linked/package.json")                            // a symlink, not a folder
        try tree.file("home/code/linked/yarn.lock")
        try tree.file("elsewhere/node_modules/a/index.js")
        try tree.symlink("home/code/linked/node_modules", to: tree.url("elsewhere/node_modules").path)

        let found = try Rules.projectFolders(places)
        #expect(found.map { relative($0.url, tree) }.sorted() == [
            "home/code/app/.next", "home/code/app/.open-next", "home/code/app/node_modules",
            "home/code/mono/packages/ui/node_modules", "home/code/site/vendor",
        ])
        // Each may only ever delete inside its own project folder.
        #expect(found.allSatisfy { $0.root.path == $0.url.deletingLastPathComponent().path })
    }

    @Test func offersOnlyFoldersLeftAlone() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let now = Date()
        for project in ["old", "fresh"] {
            try tree.file("home/code/\(project)/package.json")
            try tree.file("home/code/\(project)/bun.lock")
            try tree.file("home/code/\(project)/node_modules/a/index.js", bytes: 8000)
        }
        try tree.age("home/code/old/node_modules", to: .daysAgo(30, from: now))
        try tree.age("home/code/fresh/node_modules", to: .daysAgo(30, from: now))
        // Installed again two days ago.
        try tree.age("home/code/fresh/node_modules/a/index.js", to: .daysAgo(2, from: now))

        let report = try Rules.scan(.projectFolders, in: places, settings: RuleSettings(), now: now)
        #expect(report.items.count == 2)
        #expect(report.cleanable.map { relative($0.url, tree) } == ["home/code/old/node_modules"])
        #expect(report.cleanableBytes >= 8000)
    }

    @Test func settingsSavedBeforeANewRuleKeepTheirValues() throws {
        let saved = #"{"browserIdle":3600,"scratchIdle":7200,"claudeTempIdle":172800,"subagentAge":86400}"#
        let settings = try JSONDecoder().decode(RuleSettings.self, from: Data(saved.utf8))
        #expect(settings.browserIdle == 3600)
        #expect(settings.subagentAge == 86400)
        #expect(settings.projectIdle == RuleSettings().projectIdle)
    }
}
