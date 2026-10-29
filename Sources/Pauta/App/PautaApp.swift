import SwiftUI
import UserNotifications

@main
struct PautaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared

    var body: some Scene {
        Window("Pauta", id: "main") {
            MainView()
                .environment(app)
                .modifier(WindowOpenerBridge())
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarView()
                .environment(app)
                .modifier(WindowOpenerBridge())
        } label: {
            Image(systemName: app.isRecording ? "record.circle.fill" : "waveform")
                .symbolRenderingMode(app.isRecording ? .multicolor : .monochrome)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(app)
        }
    }
}

/// Hands SwiftUI's `openWindow` to AppState so AppKit-side code can open the main window.
private struct WindowOpenerBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            AppState.shared.openMainWindow = { openWindow(id: "main") }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var island: IslandController?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()
        let app = AppState.shared
        island = IslandController(app: app)
        hotKey = HotKey { Task { @MainActor in AppState.shared.toggleRecording() } }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if Pref.apiKey.isEmpty {
            // First run: show the window so the user can paste their OpenRouter key.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AppState.shared.openMain()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Finish the recording cleanly so the audio file is not lost.
        guard AppState.shared.isRecording else { return .terminateNow }
        Task { @MainActor in
            await AppState.shared.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["meetingID"] as? String).flatMap(UUID.init)
        await MainActor.run { AppState.shared.openMain(selecting: id) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The island already announces it while the app is frontmost.
        [.list]
    }
}
