import Foundation
@testable import LapangCore

/// A throwaway folder for one test, removed when the test ends.
final class TempTree {
    let root: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
        root = base.appending(path: "lapang-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 10) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func symlink(_ relative: String, to destination: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }

    /// Sets the modification time of `relative` and of everything inside it,
    /// deepest first, so a folder's own time is not bumped afterwards.
    func age(_ relative: String, to date: Date) throws {
        let top = url(relative)
        var paths: [String] = []
        if let names = FileManager.default.subpaths(atPath: top.path) {
            paths = names.map { top.appending(path: $0).path }
        }
        paths.sort { $0.count > $1.count }
        paths.append(top.path)
        for path in paths {
            var times = [timeval(date), timeval(date)]
            _ = lutimes(path, &times)
        }
    }

    /// Sets the creation (birth) time of one entry.
    func setCreated(_ relative: String, to date: Date) throws {
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url(relative).path)
    }
}

private func timeval(_ date: Date) -> Darwin.timeval {
    let seconds = date.timeIntervalSince1970.rounded(.down)
    return Darwin.timeval(tv_sec: Int(seconds), tv_usec: Int32((date.timeIntervalSince1970 - seconds) * 1_000_000))
}

extension Date {
    static func hoursAgo(_ hours: Double, from now: Date = Date()) -> Date {
        now.addingTimeInterval(-hours * 3600)
    }

    static func daysAgo(_ days: Double, from now: Date = Date()) -> Date {
        now.addingTimeInterval(-days * 86400)
    }
}
