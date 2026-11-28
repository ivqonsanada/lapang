import Foundation
import Testing
@testable import LapangCore

private func fakeMac(_ tree: TempTree) throws -> Places {
    try tree.folder("home")
    try tree.folder("T")
    try tree.folder("tmp")
    return Places(home: tree.url("home"), userTemp: tree.url("T"), sharedTemp: tree.url("tmp"), uid: 501)
}

@Suite struct FamilyTests {
    @Test func splitsARandomEndingOff() {
        #expect(Families.split("checkout.kbMU") == .init(key: "checkout.", tail: "kbMU", looksRandom: true))
        #expect(Families.split("e2e-run-381UXa")?.key == "e2e-run-")
        #expect(Families.split("build-ocPED8")?.key == "build-")
        #expect(Families.split("fix-nav-menu.PnPW")?.key == "fix-nav-menu.")
        // Words are endings too, but they do not look random.
        #expect(Families.split("notes-final")?.looksRandom == false)
        #expect(Families.split("node_modules")?.looksRandom == false)
    }

    @Test func leavesNamesWithoutAnEndingAlone() {
        #expect(Families.split("vendor") == nil)          // no separator
        #expect(Families.split("claude-501") == nil)      // ending too short
        #expect(Families.split("apiHeadkbMU") == nil)     // one word
        #expect(Families.split(".kbMU") == nil)           // nothing before it
        #expect(Families.split("2024-11-AbCd") == nil)    // no letter before it
        #expect(Families.split("x-abcdefghijklm") == nil) // ending too long
    }

    @Test func groupsThreeOrMoreSiblings() {
        let names = ["checkout.kbMU", "checkout.Q7xz", "checkout.p0Lm", "other.Ab12", "other.Cd34", "README"]
        #expect(Families.group(names) == ["checkout.": ["checkout.Q7xz", "checkout.kbMU", "checkout.p0Lm"]])
    }

    @Test func aWordEndingJoinsOnlyAFamilyOfRandomOnes() {
        // mktemp can draw four lowercase letters; most draws hold a digit or capital.
        #expect(Families.group(["run-AbC1", "run-XyZ2", "run-abcd"])["run-"]?.count == 3)
        #expect(Families.group(["notes-final", "notes-draft", "notes-later"]).isEmpty)
        #expect(Families.group(["notes-final", "notes-draft", "notes-v2ab"]).isEmpty)
    }

    @Test func endingsOfOneLengthAndNotAnAppsOwn() {
        #expect(Families.group(["x-AbC1", "x-AbC12", "x-AbC123"]).isEmpty)
        let apple = ["com.apple.WebKit.AbC1", "com.apple.WebKit.XyZ2", "com.apple.WebKit.Q1w2"]
        #expect(Families.group(apple).isEmpty)
    }
}

@Suite struct RepeatedCopiesRuleTests {
    private func relative(_ url: URL, _ tree: TempTree) -> String {
        url.path.replacingOccurrences(of: tree.root.path + "/", with: "")
    }

    private func settings(minimum: Int64 = 0) -> RuleSettings {
        var settings = RuleSettings()
        settings.copiesMinimumBytes = minimum
        return settings
    }

    @Test func findsCopiesInTempFoldersAndLiveScratchpads() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let now = Date()
        for tail in ["AbC1", "XyZ2", "Q1w2"] {
            try tree.file("T/build.\(tail)/out.js")
            try tree.file("T/e2e-run-\(tail)x/Default/Cookies")  // test browser profiles: rule 1's
            try tree.file("T/scoped_dir1_\(tail)/x")                   // rule 2's
            try tree.file("tmp/clone-\(tail)/README")
            try tree.file("tmp/claude-501/-Users-x-api/live/scratchpad/checkout.\(tail)/vendor/a.php")
            try tree.file("tmp/claude-501/-Users-x-api/ended/scratchpad/checkout.\(tail)/vendor/a.php")
        }
        try tree.file("T/pair.AbC1/x")   // two are not a family
        try tree.file("T/pair.XyZ2/x")
        try tree.file("T/build.Zz99")    // a file, not a folder
        try tree.age("tmp/claude-501", to: .daysAgo(3, from: now))
        // The live session wrote a task output ten minutes ago.
        try tree.file("tmp/claude-501/-Users-x-api/live/tasks/b1.output")
        try tree.age("tmp/claude-501/-Users-x-api/live/tasks", to: .hoursAgo(0.17, from: now))

        let found = Rules.repeatedCopies(places, settings: settings(), now: now)
        #expect(found.map { relative($0.url, tree) }.sorted() == [
            "T/build.AbC1", "T/build.Q1w2", "T/build.XyZ2",
            "tmp/claude-501/-Users-x-api/live/scratchpad/checkout.AbC1",
            "tmp/claude-501/-Users-x-api/live/scratchpad/checkout.Q1w2",
            "tmp/claude-501/-Users-x-api/live/scratchpad/checkout.XyZ2",
            "tmp/clone-AbC1", "tmp/clone-Q1w2", "tmp/clone-XyZ2",
        ])
        // Each may only delete inside the folder it was found in.
        #expect(found.allSatisfy { $0.root.path == $0.url.deletingLastPathComponent().path })
    }

    @Test func offersIdleCopiesOfFamiliesBigEnough() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let now = Date()
        for tail in ["AbC1", "XyZ2", "Q1w2"] {
            try tree.file("T/big.\(tail)/data", bytes: 40_000)
            try tree.file("T/small.\(tail)/data", bytes: 100)
        }
        try tree.age("T", to: .hoursAgo(8, from: now))
        try tree.age("T/big.Q1w2/data", to: .hoursAgo(1, from: now))  // a run still using it

        let report = try Rules.scan(.repeatedCopies, in: places, settings: settings(minimum: 1_000_000), now: now)
        #expect(report.items.isEmpty)
        let big = try Rules.scan(.repeatedCopies, in: places, settings: settings(minimum: 50_000), now: now)
        #expect(big.items.map(\.url.lastPathComponent).sorted() == ["big.AbC1", "big.Q1w2", "big.XyZ2"])
        #expect(big.cleanable.map(\.url.lastPathComponent).sorted() == ["big.AbC1", "big.XyZ2"])
        #expect(big.families.map(\.key) == ["big."])
        #expect(big.families.first?.items.count == 3)
    }

    @Test func settingsSavedBeforeTheRuleTakeItsDefaults() throws {
        let saved = #"{"browserIdle":3600,"scratchIdle":7200,"claudeTempIdle":172800,"subagentAge":86400,"projectIdle":86400}"#
        let settings = try JSONDecoder().decode(RuleSettings.self, from: Data(saved.utf8))
        #expect(settings.projectIdle == 86400)
        #expect(settings.copiesIdle == 6 * 3600)
        #expect(settings.copiesMinimumBytes == 100_000_000)
    }
}
