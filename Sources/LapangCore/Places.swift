import Darwin
import Foundation

/// The folders Lapang looks at. Built from this Mac by `thisMac()`, or from
/// a temp folder in the tests, so no rule ever has a hardcoded path.
public struct Places: Sendable, Equatable {
    public var home: URL
    /// The user's own temp folder (`$TMPDIR`), e.g. /var/folders/39/…/T.
    public var userTemp: URL
    /// /private/tmp, where Claude Code keeps its session temp folders.
    public var sharedTemp: URL
    public var uid: UInt32

    public init(home: URL, userTemp: URL, sharedTemp: URL, uid: UInt32) {
        self.home = home
        self.userTemp = userTemp
        self.sharedTemp = sharedTemp
        self.uid = uid
    }

    public static func thisMac() -> Places {
        Places(
            home: FileManager.default.homeDirectoryForCurrentUser,
            userTemp: userTempFolder(),
            sharedTemp: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            uid: getuid()
        )
    }

    /// `$TMPDIR` as the system defines it. A GUI app has no `TMPDIR` of the
    /// shell, and `NSTemporaryDirectory()` would answer a sandbox's folder if
    /// the app were ever sandboxed, so ask confstr directly.
    static func userTempFolder() -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if length > 0, length <= buffer.count {
            let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            let path = String(decoding: bytes, as: UTF8.self)
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    public var chromeHeadlessCache: URL {
        home.appending(path: "Library/Caches/Google/Chrome-headless", directoryHint: .isDirectory)
    }

    /// /private/tmp/claude-<uid>
    public var claudeTemp: URL {
        sharedTemp.appending(path: "claude-\(uid)", directoryHint: .isDirectory)
    }

    /// Every Claude Code account folder: each `~/.ccs/instances/<name>` and
    /// `~/.claude`, the ones that exist.
    public var claudeAccounts: [URL] {
        var accounts = FileSystem.subfolders(of: home.appending(path: ".ccs/instances", directoryHint: .isDirectory))
        let plain = home.appending(path: ".claude", directoryHint: .isDirectory)
        if FileSystem.isRealFolder(plain) { accounts.append(plain) }
        return accounts
    }

    public var deletionLog: URL {
        home.appending(path: "Library/Logs/Lapang/deleted.log", directoryHint: .notDirectory)
    }

    /// Home folders the growth watch leaves out: the rest of Library (other
    /// apps' private data, mail, photos) and the folders of the owner's own
    /// documents and media.
    static let growthSkipped: Set<String> = [
        "Library", "Documents", "Pictures", "Movies", "Music", "Applications", "Public", ".Trash",
    ]

    /// Where "Grew in the last day" looks: every real folder in the home
    /// folder, hidden ones too (where tools keep their caches), except
    /// `growthSkipped`; Library's Application Support and Caches; and both
    /// temp folders. macOS asks once before Desktop and Downloads are read.
    public var growthRoots: [URL] {
        FileSystem.subfolders(of: home).filter { !Self.growthSkipped.contains($0.lastPathComponent) }
            + ["Library/Application Support", "Library/Caches"].map { home.appending(path: $0, directoryHint: .isDirectory) }
            + [userTemp, sharedTemp]
    }

    /// Where the project rule looks for node_modules and the like: the home
    /// folders the growth watch reads, minus hidden ones. Those belong to
    /// tools (~/.vscode's extensions, global npm and Composer packages), and
    /// deleting a folder there would break the tool.
    public var projectRoots: [URL] {
        FileSystem.subfolders(of: home).filter {
            let name = $0.lastPathComponent
            return !name.hasPrefix(".") && !Self.growthSkipped.contains(name)
        }
    }
}
