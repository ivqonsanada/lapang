import Foundation
import Synchronization

/// The PATH of the person's own shell. An app opened from Finder gets only
/// /usr/bin:/bin:/usr/sbin:/sbin, and on this Mac pnpm and node (through
/// fnm) are put on PATH by ~/.zshrc, which only an interactive zsh reads.
public struct ShellEnvironment: Sendable, Equatable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    static let marker = "__LAPANG_PATH__"

    /// Starts `zsh -ilc` once and reads its PATH between two markers, since
    /// an interactive shell may print its own lines first.
    public static func load(shell: URL = URL(fileURLWithPath: "/bin/zsh")) async throws -> ShellEnvironment {
        let result = try await CommandRunner.run(
            shell, ["-ilc", "printf '%s\\n' \"\(marker)${PATH}\(marker)\""],
            path: "/usr/bin:/bin:/usr/sbin:/sbin", timeout: 30
        )
        guard let path = parsePath(result.output) else {
            throw CommandError.noPath(result.output.suffix(300).description)
        }
        return ShellEnvironment(path: path)
    }

    static func parsePath(_ output: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let path = parts[parts.count - 2].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The first executable called `tool` on this PATH.
    public func find(_ tool: String) -> URL? {
        for folder in path.split(separator: ":") where !folder.isEmpty {
            let candidate = URL(fileURLWithPath: String(folder)).appending(path: tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

public enum CommandError: Error, Equatable {
    case noPath(String)
    case timedOut
}

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    /// stdout and stderr together, in the order they came.
    public let output: String

    public var succeeded: Bool { status == 0 }

    /// The last lines, for showing in the window.
    public func tail(_ lines: Int = 3) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}

public enum CommandRunner {
    /// Runs a program with only HOME, USER, LANG and the given PATH, stdin
    /// closed, and kills it after `timeout` seconds.
    public static func run(
        _ executable: URL, _ arguments: [String], path: String, timeout: TimeInterval
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let environment = ProcessInfo.processInfo.environment
        process.environment = [
            "HOME": environment["HOME"] ?? NSHomeDirectory(),
            "USER": environment["USER"] ?? NSUserName(),
            "LANG": "en_US.UTF-8",
            "PATH": path,
        ]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = Mutex(Data())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil  // end of file
            } else {
                collected.withLock { $0.append(chunk) }
            }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let data = collected.withLock { $0 + rest }
        if process.terminationReason == .uncaughtSignal, status == SIGTERM {
            throw CommandError.timedOut
        }
        return CommandResult(status: status, output: String(decoding: data, as: UTF8.self))
    }
}
