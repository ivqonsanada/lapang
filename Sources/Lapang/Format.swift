import Foundation
import LapangCore
import SwiftUI

enum Format {
    /// Decimal units, as Finder counts.
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Gigabytes to one decimal, for the numbers that roll.
    static func gigabytes(_ value: Int64) -> Double {
        (Double(value) / 1_000_000_000 * 10).rounded() / 10
    }

    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }

    /// "3 days", "5 hours", "12 minutes".
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: seconds) ?? ""
    }

    /// "today, 14:05", "yesterday, 21:10", "20 Nov, 09:12".
    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today, \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday, \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))), \(time)"
    }

    /// A path with the home folder written as ~.
    static func path(_ url: URL, home: URL) -> String {
        let path = url.path(percentEncoded: false).trimmingSuffix("/")
        let homePath = home.path(percentEncoded: false).trimmingSuffix("/")
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    /// Claude Code names a project folder after its path with / turned into
    /// -, e.g. -Users-me-code-lapang. Shown without the home part.
    static func project(_ folder: String, home: URL) -> String {
        let prefix = home.path(percentEncoded: false).trimmingSuffix("/").replacingOccurrences(of: "/", with: "-") + "-"
        return folder.hasPrefix(prefix) ? String(folder.dropFirst(prefix.count)) : folder
    }

    /// A folder as a person knows it: a Claude Code session's scratchpad by
    /// its project and session, anything else by its path.
    static func place(_ folder: URL, home: URL) -> String {
        // …/claude-<uid>/<project>/<session>/scratchpad
        let session = folder.deletingLastPathComponent()
        let project = session.deletingLastPathComponent()
        if folder.lastPathComponent == "scratchpad",
           project.deletingLastPathComponent().lastPathComponent.hasPrefix("claude-") {
            return "\(Format.project(project.lastPathComponent, home: home)) scratchpad, session \(session.lastPathComponent.prefix(8))"
        }
        return path(folder, home: home)
    }

    /// The two lines an item is listed with: what it is, and where.
    static func lines(_ item: Item, home: URL) -> (title: String, detail: String) {
        switch item.rule {
        case .claudeTemp:
            // …/claude-501/<project>/<session>
            let session = item.url.lastPathComponent
            let project = item.url.deletingLastPathComponent().lastPathComponent
            return (Format.project(project, home: home), "session \(session)")
        case .subagentLogs:
            // <account>/projects/<project>/<session>/subagents
            let session = item.url.deletingLastPathComponent()
            let project = session.deletingLastPathComponent()
            let account = project.deletingLastPathComponent().deletingLastPathComponent()
            return (Format.project(project.lastPathComponent, home: home),
                    "\(account.lastPathComponent) · session \(session.lastPathComponent)")
        case .browserProfiles, .headlessScratch:
            return (item.url.lastPathComponent, path(item.url.deletingLastPathComponent(), home: home))
        case .repeatedCopies:
            let name = item.url.lastPathComponent
            let family = Families.split(name).map { Families.display($0.key) } ?? name
            return (name, "\(family) · \(place(item.url.deletingLastPathComponent(), home: home))")
        case .projectFolders:
            // <project>/node_modules: the project by name, then what goes and where.
            let project = item.url.deletingLastPathComponent()
            return (project.lastPathComponent, "\(item.url.lastPathComponent) · \(path(project, home: home))")
        }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}

/// Text that is quieter than the primary text but keeps AA contrast in both
/// appearances (the system's secondary label sits near 4:1 on the window).
extension ShapeStyle where Self == Color {
    static var muted: Color { Color.primary.opacity(0.68) }
}

extension RuleID {
    var title: String {
        switch self {
        case .browserProfiles: "Test browser profiles"
        case .headlessScratch: "Headless Chrome scratch"
        case .claudeTemp: "Claude session temp"
        case .repeatedCopies: "Repeated temp copies"
        case .subagentLogs: "Old subagent logs"
        case .projectFolders: "Project dependencies and builds"
        }
    }

    var detail: String {
        switch self {
        case .browserProfiles: "Chrome profiles that test scripts opened in the temp folder and never removed."
        case .headlessScratch: "scoped_dir folders headless Chrome leaves in its cache and in the temp folder."
        case .claudeTemp: "Task output and scratchpads of Claude Code sessions, in /private/tmp."
        case .repeatedCopies: "Folders a script made on every run and never removed: three or more with one name and a random ending, like checkout.kbMU. Found in the temp folders and in the scratchpads of Claude Code sessions still running."
        case .subagentLogs: "Transcripts of Claude subagents. Claude Code's own 30-day cleanup leaves them."
        case .projectFolders: "node_modules, .next, .open-next and Composer's vendor in your projects. An install or a build brings them back."
        }
    }

    var reviewTitle: String {
        switch self {
        case .browserProfiles: "Delete test browser profiles?"
        case .headlessScratch: "Delete headless Chrome scratch folders?"
        case .claudeTemp: "Delete Claude session temp folders?"
        case .repeatedCopies: "Delete repeated temp copies?"
        case .subagentLogs: "Delete old subagent logs?"
        case .projectFolders: "Delete project dependencies and builds?"
        }
    }

    var emptyText: String {
        switch self {
        case .browserProfiles: "No test browser profiles in the temp folder."
        case .headlessScratch: "No scoped_dir folders."
        case .claudeTemp: "No Claude session temp folders."
        case .repeatedCopies: "No group of repeated folders takes 100 MB or more."
        case .subagentLogs: "No subagent logs."
        case .projectFolders: "No node_modules, .next, .open-next or vendor folders in your projects."
        }
    }

    /// Relevant to what the rule holds: a browser, a window-less browser,
    /// a terminal app's sessions, stacked copies, conversation transcripts, a project folder
    /// with what its tools generated.
    var symbol: String {
        switch self {
        case .browserProfiles: "globe"
        case .headlessScratch: "rectangle.dashed"
        case .claudeTemp: "terminal"
        case .repeatedCopies: "square.on.square"
        case .subagentLogs: "text.bubble"
        case .projectFolders: "folder.badge.gearshape"
        }
    }

    /// What one item is called in counts.
    var noun: (String, String) {
        switch self {
        case .browserProfiles, .headlessScratch, .repeatedCopies, .projectFolders: ("folder", "folders")
        case .claudeTemp, .subagentLogs: ("session", "sessions")
        }
    }

    /// The idle rule in words, for the review sheet.
    func idleText(_ settings: RuleSettings) -> String {
        let time = Format.duration(settings.idle(for: self))
        switch self {
        case .subagentLogs: return "Only sessions whose subagent logs are older than \(time) are listed."
        case .claudeTemp: return "Only sessions where nothing changed for \(time) are listed. A live session always has recent files."
        case .browserProfiles, .headlessScratch: return "Only folders where nothing changed for \(time) are listed."
        case .repeatedCopies: return "Only folders where nothing changed for \(time) are listed, so the copy a running script uses stays."
        case .projectFolders: return "Only folders where nothing changed for \(time) are listed. Running the project's install or build brings one back."
        }
    }
}
