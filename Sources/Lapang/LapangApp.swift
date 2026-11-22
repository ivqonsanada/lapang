import AppKit
import SwiftUI

@main
struct LapangApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Lapang", id: "main") {
            MainView()
                .environment(LapangModel.shared)
        }
        .defaultSize(width: 760, height: 780)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(LapangModel.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A Dock icon and a menu bar, also when run unbundled during development.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        #if DEBUG
        if let folder = AppIcon.folder {
            // scripts/make-icon.sh
            do { try AppIcon.writeIconSet(to: folder) } catch { print("write-icon: \(error)") }
            NSApp.terminate(nil)
            return
        }
        if Snapshot.printCachesRequested {
            Snapshot.printCaches()
            return
        }
        if let folder = Snapshot.folder { Snapshot.run(into: folder) }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
