import AppKit
import SwiftUI

@main
struct M3U8DownloaderApp: App {
    /// Owned here rather than in `ContentView` so the Settings scene shares the
    /// same instance: clearing a tool override must update the main window's
    /// banner, which it cannot do through a second copy.
    @State private var coordinator = DownloadCoordinator()

    /// Needed only for `applicationShouldTerminate`, which SwiftUI has no equivalent of.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("M3U8 Downloader", id: "main") {
            ContentView(coordinator: coordinator)
                // The delegate is created before the scene, so it cannot be handed the
                // coordinator at init; this runs before anything can be started.
                .onAppear { appDelegate.coordinator = coordinator }
        }
        // A single window, enforced: this app has one job list, and multiple windows over
        // one coordinator would show the same state twice with no way to tell them apart —
        // each with its own draft form, all saving over the same stored options. A
        // `WindowGroup` here (as before) offered File > New Window despite this comment.
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}

/// Stops the engine, and everything it started, before the app exits.
///
/// Quitting used to leave them running: the child processes outlive their parent, so the
/// engine and any ffmpeg it had started carried on writing files with nothing left to
/// report on them.
final class AppDelegate: NSObject, NSApplicationDelegate {

    var coordinator: DownloadCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, coordinator.hasActiveWork else { return .terminateNow }

        guard Self.confirmQuit(running: coordinator.activeJobCount) else {
            return .terminateCancel
        }

        // Quit only once the processes are really gone; replying immediately would exit
        // while they are still being shut down, which is the situation being fixed.
        Task { @MainActor in
            await coordinator.stopAllAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func confirmQuit(running: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            running == 1 ? "A job is still running" : "\(running) jobs are still running"
        alert.informativeText =
            "Quitting stops it. Files that were only partly written stay where they are."
        alert.addButton(withTitle: "Quit and Stop")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
