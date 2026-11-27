import Foundation
import Testing
@testable import LapangCore

@Suite struct DeleterTests {
    /// An idle profile folder in tree/T, and the item a scan would make of it.
    private func idleProfile(_ tree: TempTree, _ name: String = "puppeteer_dev_firefox_profile-1", bytes: Int = 20_000) throws -> Item {
        try tree.file("T/\(name)/Default/Cookies", bytes: bytes)
        try tree.file("T/\(name)/Default/Preferences", bytes: 100)
        try tree.age("T/\(name)", to: .hoursAgo(5))
        return try item(tree, "T/\(name)", root: "T")
    }

    private func item(_ tree: TempTree, _ path: String, root: String) throws -> Item {
        let stats = try Scanner.measure(tree.url(path))
        return Item(
            rule: .browserProfiles, url: tree.url(path), root: tree.url(root),
            bytes: stats.freeableBytes, diskBytes: stats.allocatedBytes, files: stats.files, created: .hoursAgo(5),
            lastChange: stats.newestChange, idleNeeded: 2 * 3600
        )
    }

    private func deleter(_ tree: TempTree) -> Deleter {
        Deleter(log: tree.url("Logs/Lapang/deleted.log"))
    }

    private func exists(_ url: URL) -> Bool {
        FileSystem.info(url) != nil
    }

    @Test func deletesAnIdleItemAndLogsIt() throws {
        let tree = try TempTree()
        let item = try idleProfile(tree)
        let result = deleter(tree).delete([item])
        #expect(result.deleted.count == 1)
        #expect(result.skipped.isEmpty)
        #expect(result.freedBytes == item.bytes)
        #expect(!exists(item.url))
        #expect(exists(tree.url("T")))

        let log = try String(contentsOf: tree.url("Logs/Lapang/deleted.log"), encoding: .utf8)
        let fields = log.split(separator: "\n")[0].split(separator: "\t").map(String.init)
        #expect(fields.count == 5)
        #expect(fields[1] == "browserProfiles")
        #expect(fields[2] == "deleted")
        #expect(fields[3] == String(item.bytes))
        #expect(fields[4] == item.url.path)
    }

    @Test func countsOnlyWhatAFolderHeldOnItsOwn() throws {
        let tree = try TempTree()
        try tree.file("store/big", bytes: 200_000)
        try tree.file("T/puppeteer_dev_firefox_profile-1/Default/Preferences", bytes: 100)
        // A clone of the store's file: it shares every block with it.
        #expect(clonefile(tree.url("store/big").path, tree.url("T/puppeteer_dev_firefox_profile-1/Default/big").path, 0) == 0)
        try tree.age("T/puppeteer_dev_firefox_profile-1", to: .hoursAgo(5))
        let item = try item(tree, "T/puppeteer_dev_firefox_profile-1", root: "T")
        #expect(item.diskBytes >= 200_000)
        #expect(item.bytes < 100_000)

        let result = deleter(tree).delete([item])
        #expect(result.deleted.count == 1)
        #expect(result.freedBytes < 100_000)
        #expect(exists(tree.url("store/big")))
    }

    @Test func refusesAPathOutsideTheRoot() throws {
        let tree = try TempTree()
        try tree.file("outside/x/data")
        try tree.folder("T")
        try tree.age("outside", to: .daysAgo(3))
        let escaping = try item(tree, "outside/x", root: "T")
        let dotted = Item(
            rule: .browserProfiles, url: URL(fileURLWithPath: tree.url("T").path + "/../outside/x"),
            root: tree.url("T"), bytes: 1, files: 1, created: .daysAgo(3), lastChange: .daysAgo(3), idleNeeded: 3600
        )
        let rootItself = Item(
            rule: .browserProfiles, url: tree.url("T"), root: tree.url("T"),
            bytes: 1, files: 1, created: .daysAgo(3), lastChange: .daysAgo(3), idleNeeded: 3600
        )
        let result = deleter(tree).delete([escaping, dotted, rootItself])
        #expect(result.deleted.isEmpty)
        #expect(result.skipped.map(\.reason) == [.outsideRoot, .outsideRoot, .outsideRoot])
        #expect(exists(tree.url("outside/x/data")))
        #expect(exists(tree.url("T")))
    }

    @Test func refusesAnItemThatBecameASymlink() throws {
        let tree = try TempTree()
        let item = try idleProfile(tree)
        try tree.file("precious/keep", bytes: 500)
        try FileManager.default.removeItem(at: item.url)
        try tree.symlink("T/puppeteer_dev_firefox_profile-1", to: tree.url("precious").path)

        let result = deleter(tree).delete([item])
        #expect(result.skipped.map(\.reason) == [.symlink])
        #expect(exists(tree.url("precious/keep")))
        #expect(exists(item.url))
    }

    @Test func refusesAnItemThatBecameActive() throws {
        let tree = try TempTree()
        let item = try idleProfile(tree)
        try tree.file("T/puppeteer_dev_firefox_profile-1/Default/Fresh", bytes: 10)  // written just now
        let result = deleter(tree).delete([item])
        guard case .becameActive = result.skipped.first?.reason else {
            Issue.record("expected becameActive, got \(String(describing: result.skipped.first?.reason))")
            return
        }
        #expect(exists(tree.url("T/puppeteer_dev_firefox_profile-1/Default/Cookies")))
    }

    @Test func reportsAnItemAlreadyGone() throws {
        let tree = try TempTree()
        let item = try idleProfile(tree)
        try FileManager.default.removeItem(at: item.url)
        #expect(deleter(tree).delete([item]).skipped.map(\.reason) == [.gone])
    }

    @Test func removesSymlinksInsideAsLinks() throws {
        let tree = try TempTree()
        try tree.file("precious/keep", bytes: 500)
        try tree.file("T/puppeteer_dev_firefox_profile-1/Default/Cookies")
        try tree.symlink("T/puppeteer_dev_firefox_profile-1/Default/link", to: tree.url("precious").path)
        try tree.age("T/puppeteer_dev_firefox_profile-1", to: .hoursAgo(5))
        let item = try item(tree, "T/puppeteer_dev_firefox_profile-1", root: "T")

        let result = deleter(tree).delete([item])
        #expect(result.deleted.count == 1)
        #expect(!exists(item.url))
        #expect(exists(tree.url("precious/keep")))
    }

    @Test func emptiesReadOnlyFolders() throws {
        let tree = try TempTree()
        try tree.file("T/puppeteer_dev_firefox_profile-1/locked/inner/file")
        try tree.age("T/puppeteer_dev_firefox_profile-1", to: .hoursAgo(5))
        chmod(tree.url("T/puppeteer_dev_firefox_profile-1/locked/inner").path, 0o555)
        chmod(tree.url("T/puppeteer_dev_firefox_profile-1/locked").path, 0o555)
        let item = try item(tree, "T/puppeteer_dev_firefox_profile-1", root: "T")

        let result = deleter(tree).delete([item])
        #expect(result.skipped.isEmpty)
        #expect(!exists(item.url))
    }

    @Test func acceptsARootReachedThroughASymlink() throws {
        // $TMPDIR is /var/folders/…, and /var is a symlink to /private/var.
        let tree = try TempTree()
        _ = try idleProfile(tree)
        try tree.symlink("varT", to: tree.url("T").path)
        let item = try item(tree, "varT/puppeteer_dev_firefox_profile-1", root: "varT")
        let result = deleter(tree).delete([item])
        #expect(result.deleted.count == 1)
        #expect(!exists(tree.url("T/puppeteer_dev_firefox_profile-1")))
        #expect(exists(tree.url("T")))
    }

    @Test func deletesSeveralAndKeepsGoingPastASkip() throws {
        let tree = try TempTree()
        let first = try idleProfile(tree, "puppeteer_dev_firefox_profile-a")
        let second = try idleProfile(tree, "puppeteer_dev_firefox_profile-b")
        let third = try idleProfile(tree, "puppeteer_dev_firefox_profile-c")
        try tree.file("T/puppeteer_dev_firefox_profile-b/new")
        var done: [Int] = []
        let result = deleter(tree).delete([first, second, third]) { done.append($0) }
        #expect(result.deleted.map(\.item.url.lastPathComponent) == ["puppeteer_dev_firefox_profile-a", "puppeteer_dev_firefox_profile-c"])
        #expect(result.skipped.count == 1)
        #expect(done == [1, 2, 3])
        let log = try String(contentsOf: tree.url("Logs/Lapang/deleted.log"), encoding: .utf8)
        #expect(log.split(separator: "\n").count == 3)
        #expect(log.contains("skipped: changed since the scan"))
    }
}
