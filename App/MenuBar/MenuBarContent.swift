import SwiftUI
import RecorderKit

struct MenuBarContent: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var flashback = AppModel.shared.flashback
    @ObservedObject var recorder: RecordingController
    @ObservedObject var settings: AppSettings

    var body: some View {
        if recorder.phase == .recording {
            Button("Stoppa inspelningen  (\(RecordingController.duration(recorder.status.elapsed)))") {
                Task { await recorder.stop() }
            }
            Button(recorder.status.isPaused ? "Fortsätt" : "Pausa") { recorder.togglePause() }
            Divider()
        } else {
            Button("Spela in skärmen") { recorder.recordDisplayUnderMouse() }
                .disabled(recorder.isBusy)
            Button("Spela in fönster …") { recorder.recordWindow() }
                .disabled(recorder.isBusy)
            Button("Spela in program …") { recorder.recordApplication() }
                .disabled(recorder.isBusy)
            Button("Spela in område …") { recorder.recordArea() }
                .disabled(recorder.isBusy)
            Divider()
            Picker("Mikrofon", selection: $settings.micID) {
                Text("Ingen").tag("")
                Text("Standardmikrofonen").tag("standard")
                ForEach(settings.microphones) { Text($0.name).tag($0.id) }
            }
            Picker("Kamera", selection: $settings.cameraID) {
                Text("Ingen").tag("")
                ForEach(settings.cameras) { Text($0.name).tag($0.id) }
            }
            Toggle("Datorljud", isOn: $settings.systemAudio)
            Toggle("Spela in kortkommandon", isOn: $settings.keystrokes)
            Toggle("Nedräkning", isOn: $settings.countdown)
            Picker("Bildfrekvens", selection: $settings.fps) {
                Text("30 bilder/s").tag(30)
                Text("60 bilder/s").tag(60)
            }
            Divider()
        }
        flashbackMenu
        Divider()
        Button("Bibliotek …") { app.showLibrary() }
        Button("Behörigheter …") { app.showPermissions() }
        Divider()
        Button("Avsluta Bjarbys skärminspelare") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var flashbackMenu: some View {
        if flashback.isRunning {
            Button(flashback.isSaving ? String(localized: "Sparar …")
                                      : String(localized: "Spara senaste \(settings.flashbackMinutes) min  (⌃⌥⌘S)")) {
                flashback.save()
            }
            .disabled(flashback.isSaving)
        }
        Menu("Flashback") {
            Toggle("Spela in i bakgrunden", isOn: Binding(get: { settings.flashbackEnabled },
                                                          set: { settings.flashbackEnabled = $0; flashback.apply() }))
            Picker("Spara", selection: Binding(get: { settings.flashbackMinutes }, set: { v in
                settings.flashbackMinutes = v
                if flashback.isRunning { Task { await flashback.stop(); await flashback.start() } }
            })) {
                ForEach([1, 2, 5, 10], id: \.self) { Text("Senaste \($0) min").tag($0) }
            }
            Toggle("Med mikrofon", isOn: Binding(get: { settings.flashbackMicrophone }, set: { v in
                settings.flashbackMicrophone = v
                if flashback.isRunning { Task { await flashback.stop(); await flashback.start() } }
            }))
            if let e = flashback.lastError { Text(e) }
        }
    }
}
