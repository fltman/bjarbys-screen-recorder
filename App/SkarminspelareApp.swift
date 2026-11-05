import SwiftUI
import RecorderKit

@main
struct SkarminspelareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.lockLanguage()
        StandardStyle.load()
        // Provlägen och MCP-servern ska aldrig fastna på "Öppna fönstren igen?" efter en
        // krasch: frågan är modal, och ingen ser den (uppmätt: varje provstart hängde efter
        // en krasch). Registreringsdomänen gäller bara den här processen.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--prov-") || $0 == "--mcp" }) {
            UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        }
    }

    /// Gränssnittet är svenskt oavsett systemspråk — samma mekanism som språkval per program i
    /// Systeminställningar (`AppleLanguages` i appens egen domän). Måste ske innan någon
    /// lokaliserad text laddas. Den som vill följa systemspråket:
    /// `defaults write com.brattoo.skarminspelare followSystemLanguage -bool true`.
    static func lockLanguage() {
        let d = UserDefaults.standard
        if d.bool(forKey: "followSystemLanguage") {
            d.removeObject(forKey: "AppleLanguages")
        } else if (d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first != "sv" {
            d.set(["sv"], forKey: "AppleLanguages")
        }
    }

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
    @ObservedObject private var flashback = AppModel.shared.flashback

    var body: some View {
        switch recorder.phase {
        case .recording:
            Image(systemName: recorder.status.isPaused ? "pause.circle.fill" : "stop.circle.fill")
        case .countdown, .choosing, .stopping:
            Image(systemName: "circle.dotted")
        case .idle:
            // Flashback spelar in i bakgrunden: syns i ikonen, så att det aldrig sker i smyg.
            Image(systemName: flashback.isRunning ? "clock.arrow.circlepath" : "record.circle")
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
            if MCPServer.isRequested {
                NSApp.setActivationPolicy(.prohibited)
                MCPServer.run()
                return
            }
            let app = AppModel.shared
            let hk = HotKeys.shared
            hk.register(.toggleRecording) { app.recorder.toggleFromHotKey() }
            hk.register(.pause) { app.recorder.togglePause() }
            hk.register(.area) { app.recorder.recordArea() }
            hk.register(.flashback) { app.flashback.save() }
            hk.register(.draw) { app.recorder.toggleDrawing() }
            hk.register(.marker) { app.recorder.addMarker() }
            // iPhone och iPad via kabel syns som enheter (som i QuickTime).
            DeviceSession.allowScreenDevices()
            app.flashback.apply()
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

    /// `skarminspelare://spela-in`, `…/stoppa`, `…/paus`, `…/omrade`, `…/bibliotek`,
    /// `…/oppna?sokvag=<paket>` — för Genvägar, Raycast, Alfred och skript.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if url.isFileURL {
                    AppModel.shared.openEditor(RecordingBundle(url: url))
                } else {
                    URLCommands.handle(url)
                }
            }
        }
    }
}
