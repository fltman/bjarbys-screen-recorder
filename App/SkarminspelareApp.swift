import SwiftUI
import RecorderKit

@main
struct SkarminspelareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(app: AppModel.shared, recorder: AppModel.shared.recorder,
                           settings: AppModel.shared.settings)
        } label: {
            MenuBarLabel(recorder: AppModel.shared.recorder)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var recorder: RecordingController

    var body: some View {
        switch recorder.phase {
        case .recording:
            Image(systemName: recorder.status.isPaused ? "pause.circle.fill" : "stop.circle.fill")
        case .countdown, .choosing, .stopping:
            Image(systemName: "circle.dotted")
        case .idle:
            Image(systemName: "record.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if TestMode.isRequested {
                NSApp.setActivationPolicy(.accessory)
                TestMode.run()
                return
            }
            let app = AppModel.shared
            let hk = HotKeys.shared
            hk.register(15, id: HotKeyID.toggleRecording) { app.recorder.toggleFromHotKey() } // R
            hk.register(35, id: HotKeyID.pause) { app.recorder.togglePause() }                // P
            hk.register(0, id: HotKeyID.area) { app.recorder.recordArea() }                   // A
            Task {
                _ = await app.library.recoverUnfinished(excluding: nil)
            }
            if CGPreflightScreenCaptureAccess() {
                app.showLibrary()
            } else {
                app.showPermissions()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.showLibrary() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
