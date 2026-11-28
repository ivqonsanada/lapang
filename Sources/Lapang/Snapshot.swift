#if DEBUG
import AppKit
import Darwin
import LapangCore

/// `Lapang --snapshot=<folder>` (debug builds only): draws the window into
/// PNGs at each stage of a real scan, in light and dark, then quits. The
/// shell that builds Lapang may not record the screen, so the app draws
/// itself. Nothing is deleted: the sheets are opened and closed, never confirmed.
@MainActor
enum Snapshot {
    static var folder: URL? {
        CommandLine.arguments
            .first { $0.hasPrefix("--snapshot=") }
            .map { URL(fileURLWithPath: String($0.dropFirst("--snapshot=".count)), isDirectory: true) }
    }

    /// `Lapang --print-caches`: what rule 5 finds on this Mac, then quit.
    static var printCachesRequested: Bool { CommandLine.arguments.contains("--print-caches") }

    static func printCaches() {
        Task { @MainActor in
            do {
                let environment = try await ShellEnvironment.load()
                for cache in await PackageCaches.scan(environment) {
                    print("\(cache.name): \(cache.bytes) \(cache.folder.path) via \(cache.tool.path)")
                }
            } catch {
                print("caches: \(error)")
            }
            NSApp.terminate(nil)
        }
    }

    static func run(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = LapangModel.shared
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.title == "Lapang" }) else {
                print("snapshot: no window")
                NSApp.terminate(nil)
                return
            }
            // The tallest screen shows the whole window, every section in one picture.
            if let screen = NSScreen.screens.max(by: { $0.visibleFrame.height < $1.visibleFrame.height }) {
                let area = screen.visibleFrame
                let height = min(2100, area.height - 40)
                window.setFrame(NSRect(x: area.minX + 20, y: area.maxY - height - 20, width: 760, height: height), display: true)
            } else {
                window.setContentSize(NSSize(width: 760, height: 1180))
            }
            NSApp.appearance = NSAppearance(named: .aqua)
            try? await Task.sleep(for: .seconds(0.6))
            capture(window, "1-scanning-light", folder)

            let started = Date()
            while model.isScanning || model.history.running, Date().timeIntervalSince(started) < 900 {
                try? await Task.sleep(for: .seconds(1))
            }
            print("snapshot: scan took \(Int(Date().timeIntervalSince(started))) s")
            try? await Task.sleep(for: .seconds(1))
            capture(window, "2-done-light", folder)

            let biggest = RuleID.allCases
                .compactMap { model.report($0) }
                .max { $0.cleanableBytes < $1.cleanableBytes }
            model.preview = biggest?.cleanableBytes ?? 0
            try? await Task.sleep(for: .seconds(0.8))
            capture(window, "3-preview-light", folder)
            model.preview = 0

            NSApp.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .seconds(1))
            capture(window, "4-done-dark", folder)

            if let rule = biggest?.rule, biggest?.cleanable.isEmpty == false {
                model.reviewing = rule
                try? await Task.sleep(for: .seconds(1))
                if let sheet = window.attachedSheet { capture(sheet, "5-review-dark", folder) }
                NSApp.appearance = NSAppearance(named: .aqua)
                try? await Task.sleep(for: .seconds(0.8))
                if let sheet = window.attachedSheet { capture(sheet, "6-review-light", folder) }
                model.reviewing = nil
                try? await Task.sleep(for: .seconds(1))
            }
            if model.caches.value?.isEmpty == false {
                model.cleaningCaches = true
                try? await Task.sleep(for: .seconds(1))
                if let sheet = window.attachedSheet { capture(sheet, "7-caches-light", folder) }
                model.cleaningCaches = false
                try? await Task.sleep(for: .seconds(0.8))
            }
            report(model)
            NSApp.terminate(nil)
        }
    }

    /// Captures the window as the screen shows it, title bar and toolbar
    /// included. SwiftUI draws through Core Animation, so cacheDisplay comes
    /// back empty; CGWindowListCreateImage of one's own window works without
    /// the screen recording permission. It is deprecated, so it is looked up
    /// at run time.
    static func capture(_ window: NSWindow, _ name: String, _ folder: URL) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            print("snapshot: CGWindowListCreateImage is not available")
            return
        }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // optionIncludingWindow; boundsIgnoreFraming | bestResolution
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else {
            print("snapshot: no image for \(name)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let url = folder.appending(path: name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path) \(image.width)x\(image.height)")
    }

    /// The numbers behind the window, for comparing with du.
    static func report(_ model: LapangModel) {
        if let space = model.space {
            print("space: total \(space.total) free \(space.free) strict \(space.freeStrict)")
        }
        for rule in RuleID.allCases {
            guard let report = model.report(rule) else { print("\(rule.rawValue): none"); continue }
            print("\(rule.rawValue): items \(report.items.count) bytes \(report.totalBytes) cleanable \(report.cleanable.count) \(report.cleanableBytes) new \(report.newInLastDay) unreadable \(report.unreadable)")
            for item in report.items.prefix(3) { print("  \(item.bytes) \(item.url.path)") }
        }
        for cache in model.caches.value ?? [] { print("cache \(cache.name): \(cache.bytes) \(cache.folder.path) via \(cache.tool.path)") }
        if let error = model.caches.error { print("caches error: \(error)") }
        for spot in model.history.value ?? [] {
            print("came back \(spot.spot.rule.rawValue) \(spot.spot.pattern.display) in \(spot.spot.folder.path): items \(spot.items.count) back \(spot.back.count) \(spot.backBytes) cleanable \(spot.cleanable.count) perDay \(Int64(spot.bytesPerDay ?? 0)) exists \(spot.folderExists)")
        }
        if let error = model.history.error { print("history error: \(error)") }
        if let copies = model.report(.repeatedCopies) {
            for family in copies.families.prefix(8) {
                print("family \(family.key)* in \(family.folder.path): \(family.items.count) folders, freeable \(family.bytes), on disk \(family.diskBytes)")
            }
        }
        for growth in model.growth.value ?? [] { print("grew: \(growth.bytes) \(growth.files) \(growth.url.path)") }
        if let error = model.growth.error { print("growth error: \(error)") }
    }
}
#endif
