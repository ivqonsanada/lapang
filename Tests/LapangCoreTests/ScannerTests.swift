import Foundation
import Testing
@testable import LapangCore

@Suite struct ScannerTests {
    @Test func countsFilesFoldersAndAllocatedBytes() throws {
        let tree = try TempTree()
        try tree.file("a/one", bytes: 10_000)
        try tree.file("a/b/two", bytes: 50_000)
        try tree.file("three", bytes: 1)

        let stats = try Scanner.measure(tree.root)
        #expect(stats.files == 3)
        #expect(stats.folders == 3)  // root, a, a/b
        // Allocated bytes are whole blocks, so never less than the lengths.
        #expect(stats.allocatedBytes >= 60_001)
        #expect(stats.allocatedBytes < 60_001 + 6 * 16_384)
        #expect(stats.unreadable == 0)
    }

    @Test func neverFollowsSymlinks() throws {
        let tree = try TempTree()
        try tree.file("small", bytes: 10)
        try tree.symlink("usr", to: "/usr")
        let stats = try Scanner.measure(tree.root)
        // /usr holds gigabytes; the link itself holds nothing.
        #expect(stats.allocatedBytes < 1_000_000)
        #expect(stats.files == 2)  // the file and the link
    }

    @Test func aSymlinkAsTheStartingPathIsNotFollowed() throws {
        let tree = try TempTree()
        let link = try tree.symlink("usr", to: "/usr")
        let stats = try Scanner.measure(link)
        #expect(stats.allocatedBytes < 1_000_000)
        #expect(stats.folders == 0)
    }

    @Test func countsAHardLinkedFileOnce() throws {
        let tree = try TempTree()
        let original = try tree.file("one", bytes: 200_000)
        let single = try Scanner.measure(tree.root)
        try FileManager.default.linkItem(at: original, to: tree.url("two"))
        try tree.age("", to: .hoursAgo(1))
        let linked = try Scanner.measure(tree.root)
        #expect(linked.allocatedBytes == single.allocatedBytes)
    }

    @Test func newestChangeIsTheNewestEntryInside() throws {
        let tree = try TempTree()
        try tree.file("old/x")
        try tree.file("deep/er/y")
        let now = Date()
        try tree.age("", to: .daysAgo(5, from: now))
        try tree.age("deep/er/y", to: .hoursAgo(3, from: now))

        let stats = try Scanner.measure(tree.root)
        #expect(abs(stats.newestChange.timeIntervalSince(.hoursAgo(3, from: now))) < 1)
    }

    @Test func aMissingPathCountsAsUnreadable() throws {
        let tree = try TempTree()
        let stats = try Scanner.measure(tree.url("nope"))
        #expect(stats.files == 0)
        #expect(stats.unreadable == 1)
    }

    @Test func stopsWhenTheTaskIsCancelled() async throws {
        let tree = try TempTree()
        for index in 0..<3000 { try tree.file("f\(index % 10)/\(index)", bytes: 1) }
        let root = tree.root
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Scanner.measure(root)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct FreeSpaceTests {
    @Test func readsTheVolumeOfAFolder() throws {
        let tree = try TempTree()
        let space = try FreeSpace.read(at: tree.root)
        #expect(space.total > 0)
        #expect(space.free > 0)
        #expect(space.free <= space.total)
        #expect(space.used == space.total - space.free)
        #expect(space.purgeable >= 0)
    }

    @Test func purgeableIsTheGapBetweenFinderAndDf() {
        let space = VolumeSpace(total: 500, free: 80, freeStrict: 60)
        #expect(space.purgeable == 20)
        #expect(space.used == 420)
        #expect(VolumeSpace(total: 500, free: 60, freeStrict: 80).purgeable == 0)
    }
}

@Suite struct PlacesTests {
    @Test func userTempIsTheDarwinTempFolder() {
        let temp = Places.userTempFolder().path
        #expect(temp.contains("/T"))
        #expect(FileManager.default.fileExists(atPath: temp))
    }

    @Test func listsClaudeAccountsThatAreRealFolders() throws {
        let tree = try TempTree()
        try tree.folder("home/.ccs/instances/main")
        try tree.folder("home/.ccs/instances/work")
        try tree.folder("elsewhere")
        try tree.symlink("home/.ccs/instances/linked", to: tree.url("elsewhere").path)
        try tree.folder("home/.claude")
        let places = Places(home: tree.url("home"), userTemp: tree.url("t"), sharedTemp: tree.url("tmp"), uid: 501)
        #expect(places.claudeAccounts.map(\.lastPathComponent) == ["main", "work", ".claude"])
        #expect(places.claudeTemp.path.hasSuffix("/tmp/claude-501"))
    }

    @Test func growthWatchLooksInHomeFoldersButNotPrivateOnes() throws {
        let tree = try TempTree()
        for name in ["Developer", ".cache", "Desktop", "Documents", "Pictures", "Library/Caches", "Library/Application Support", "Library/Mail"] {
            try tree.folder("home/\(name)")
        }
        try tree.folder("elsewhere")
        try tree.symlink("home/linked", to: tree.url("elsewhere").path)
        let places = Places(home: tree.url("home"), userTemp: tree.url("t"), sharedTemp: tree.url("tmp"), uid: 501)
        let roots = places.growthRoots.map { $0.path.replacingOccurrences(of: tree.root.path + "/", with: "") }
        #expect(roots == [
            "home/.cache", "home/Desktop", "home/Developer",
            "home/Library/Application Support", "home/Library/Caches", "t", "tmp",
        ])
    }
}
