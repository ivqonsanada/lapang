import Foundation
import Testing
@testable import LapangCore

private func fakeMac(_ tree: TempTree) throws -> Places {
    try tree.folder("home")
    try tree.folder("T")
    try tree.folder("tmp")
    return Places(home: tree.url("home"), userTemp: tree.url("T"), sharedTemp: tree.url("tmp"), uid: 501)
}

private func line(_ time: Date, _ rule: String, _ outcome: String, _ bytes: Int64, _ path: String) -> String {
    [ISO8601DateFormatter().string(from: time), rule, outcome, String(bytes), path].joined(separator: "\t")
}

@Suite struct DeletionHistoryTests {
    @Test func learnsFamiliesAtOnceAndNamesWhenDeletedTwice() {
        let now = Date()
        let log = [
            line(.daysAgo(2, from: now), "browserProfiles", "deleted", 100, "/T/e2e-run-381UXa"),
            line(.daysAgo(2, from: now).addingTimeInterval(5), "browserProfiles", "deleted", 200, "/T/e2e-run-3MkN6L"),
            line(.daysAgo(1, from: now), "browserProfiles", "partly deleted: 1 entry stayed", 50, "/T/e2e-run-9DG3Hg"),
            line(.daysAgo(1, from: now), "browserProfiles", "skipped: changed since the scan", 70, "/T/e2e-run-0aaaaa"),
            line(.daysAgo(5, from: now), "projectFolders", "deleted", 1000, "/code/app/node_modules"),
            line(.daysAgo(9, from: now), "projectFolders", "deleted", 3000, "/code/web/node_modules"),
            line(.daysAgo(3, from: now), "projectFolders", "deleted", 2000, "/code/web/node_modules"),
            line(.daysAgo(4, from: now), "claudeTemp", "deleted", 9000, "/tmp/claude-501/-p/aaaa-Bb12"),
            line(.daysAgo(4, from: now), "claudeTemp", "deleted", 9000, "/tmp/claude-501/-p/cccc-Dd34"),
            "not a log line",
        ].joined(separator: "\n")

        let spots = DeletionHistory.spots(from: DeletionHistory.parse(log))
        #expect(spots.count == 2)
        let profiles = spots.first { $0.rule == .browserProfiles }
        #expect(profiles?.pattern == .family("e2e-run-"))
        #expect(profiles?.folder.path == "/T")
        #expect(profiles?.itemsDeleted == 3)
        #expect(profiles?.bytesFreed == 350)
        #expect(profiles?.cleanings == 2)
        let web = spots.first { $0.rule == .projectFolders }
        #expect(web?.pattern == .exact("node_modules"))
        #expect(web?.folder.path == "/code/web")
        #expect(web?.cleanings == 2)
        #expect(spots.first?.rule == .browserProfiles)  // the latest cleaned first
    }

    @Test func knownPrefixesAndScopedDirsAreOneSpotEach() {
        #expect(NamePattern.learned(from: "scoped_dir1234_5678901", rule: .headlessScratch) == .prefix("scoped_dir"))
        #expect(NamePattern.learned(from: "puppeteer_dev_chrome_profile-AbC123", rule: .browserProfiles)
            == .prefix("puppeteer_dev_chrome_profile-"))
        #expect(NamePattern.learned(from: "checkout.kbMU", rule: .repeatedCopies) == .family("checkout."))
        #expect(NamePattern.learned(from: ".next", rule: .projectFolders) == .exact(".next"))
        #expect(NamePattern.family("e2e-run-").matches("e2e-run-abcdef"))
        #expect(!NamePattern.family("e2e-run-").matches("e2e-run-x-AbC123"))
    }

    @Test func countsWhatCameBackSinceTheLastClean() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let now = Date()
        let cleaned = Date.daysAgo(2, from: now)
        let temp = places.userTemp.path
        let log = line(cleaned, "browserProfiles", "deleted", 500, "\(temp)/e2e-run-381UXa")
        guard let spot = DeletionHistory.spots(from: DeletionHistory.parse(log)).first else {
            Issue.record("no spot learned")
            return
        }

        for name in ["e2e-run-AAAA11", "e2e-run-BBBB22", "e2e-run-CCCC33"] {
            try tree.file("T/\(name)/Default/Cookies", bytes: 4000)
        }
        try tree.file("T/e2e-run-DDDD44/notes.txt")          // not a browser profile
        try tree.file("T/other-uji-EEEE55/Default/Cookies")      // another family
        try tree.age("T", to: .hoursAgo(5, from: now))
        try tree.setCreated("T/e2e-run-AAAA11", to: .daysAgo(1, from: now))
        try tree.setCreated("T/e2e-run-BBBB22", to: .hoursAgo(5, from: now))
        try tree.setCreated("T/e2e-run-CCCC33", to: .daysAgo(3, from: now))  // kept last time
        try tree.age("T/e2e-run-BBBB22/Default/Cookies", to: .hoursAgo(0.5, from: now))

        let report = try DeletionHistory.check([spot], in: places, settings: RuleSettings(), now: now)[0]
        #expect(report.folderExists)
        #expect(report.items.map(\.url.lastPathComponent).sorted() == ["e2e-run-AAAA11", "e2e-run-BBBB22", "e2e-run-CCCC33"])
        #expect(report.back.map(\.url.lastPathComponent).sorted() == ["e2e-run-AAAA11", "e2e-run-BBBB22"])
        #expect(report.cleanable.map(\.url.lastPathComponent).sorted() == ["e2e-run-AAAA11", "e2e-run-CCCC33"])
        #expect(report.items.allSatisfy { $0.root == places.userTemp && $0.rule == .browserProfiles })
        let perDay = try #require(report.bytesPerDay)
        #expect(abs(perDay - Double(report.backBytes) / 2) < Double(report.backBytes) * 0.01)
    }

    @Test func aSpotWhoseFolderWentIsSaidSo() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let log = line(Date(), "repeatedCopies", "deleted", 500, tree.url("tmp/claude-501/-p/s/scratchpad/checkout.kbMU").path)
        let spots = DeletionHistory.spots(from: DeletionHistory.parse(log))
        let report = try DeletionHistory.check(spots, in: places, settings: RuleSettings())
        #expect(report.count == 1)
        #expect(report[0].folderExists == false)
        #expect(report[0].items.isEmpty)
    }

    @Test func aCopyComingBackIsOfferedWithItsScratchpadAsRoot() throws {
        let tree = try TempTree()
        let places = try fakeMac(tree)
        let now = Date()
        let scratchpad = "tmp/claude-501/-p/s/scratchpad"
        let log = line(.daysAgo(1, from: now), "repeatedCopies", "deleted", 500, tree.url("\(scratchpad)/checkout.kbMU").path)
        try tree.file("\(scratchpad)/checkout.Zz12/vendor/a.php", bytes: 3000)
        try tree.file("\(scratchpad)/notes.md")
        let spots = DeletionHistory.spots(from: DeletionHistory.parse(log))
        let report = try DeletionHistory.check(spots, in: places, settings: RuleSettings(), now: now)[0]
        #expect(report.items.map(\.url.lastPathComponent) == ["checkout.Zz12"])
        #expect(report.items[0].root.path == tree.url(scratchpad).path)
        #expect(report.back.count == 1)
    }
}
