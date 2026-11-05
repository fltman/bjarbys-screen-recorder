import SwiftUI
import RecorderKit

struct MenuBarContent: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var flashback = AppModel.shared.flashback
    @ObservedObject var recorder: RecordingController
    @ObservedObject var settings: AppSettings
    @ObservedObject private var hotKeys = HotKeys.shared

    var body: some View {
        if recorder.phase == .recording {
            Button("Stoppa inspelningen  (\(RecordingController.duration(recorder.status.elapsed)))") {
                Task { await recorder.stop() }
            }
            Button(recorder.status.isPaused ? "Fortsätt" : "Pausa") { recorder.togglePause() }
            Button(recorder.isDrawing ? "Sluta rita" : "Rita på skärmen") { recorder.toggleDrawing() }
                .keyboardShortcut(hotKeys.binding(.draw).keyboardShortcut)
            Divider()
        } else {
            // Kortkommandona visas i menyn (de globala gäller också när menyn är stängd).
            Button("Spela in skärmen") { recorder.recordDisplayUnderMouse() }
                .keyboardShortcut(hotKeys.binding(.toggleRecording).keyboardShortcut)
                .disabled(recorder.isBusy)
            Button("Spela in fönster …") { recorder.recordWindow() }
                .disabled(recorder.isBusy)
            Button("Spela in program …") { recorder.recordApplication() }
                .disabled(recorder.isBusy)
            Button("Spela in område …") { recorder.recordArea() }
                .keyboardShortcut(hotKeys.binding(.area).keyboardShortcut)
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
            Toggle(settings.appAudio.isEmpty ? "Datorljud" : "Övrigt datorljud", isOn: $settings.systemAudio)
            Menu("Ljud per app") {
                let apps = settings.menuAudioApps
                if apps.isEmpty { Text("Inga appar med ljud just nu") }
                ForEach(apps) { a in
                    Toggle(a.isPlaying ? "\(a.name)  ♪" : a.name,
                           isOn: Binding(get: { settings.isAppChosen(a.bundleID) },
                                         set: { settings.setApp(a.bundleID, name: a.name, chosen: $0) }))
                }
                Divider()
                Text("Varje vald app får ett eget spår.")
                Text("Datorljud blir då allt annat.")
            }
            Divider()
            Menu("Inspelning") {
                Toggle("Kortkommandon och skrivande", isOn: $settings.keystrokes)
                    .help("Kortkommandon visas i filmen, och skrivande ger en zoom där du skriver — bara när och var, aldrig vad. Kräver Indataövervakning (och Tillgänglighet för var).")
                Toggle("Nedräkning", isOn: $settings.countdown)
                if AppSettings.hdrAvailable {
                    Toggle("HDR (10 bit)", isOn: $settings.hdr)
                }
                Divider()
                Toggle("Dölj skrivbordssymboler", isOn: $settings.hideDesktopIcons)
                Toggle("Dölj notiser och widgets", isOn: $settings.hideNotifications)
                Picker("Bildfrekvens", selection: $settings.fps) {
                    Text("30 bilder/s").tag(30)
                    Text("60 bilder/s").tag(60)
                    // Bara om någon skärm visar 120 Hz (ProMotion): annars finns inga fler rutor att få.
                    if NSScreen.screens.contains(where: { $0.maximumFramesPerSecond >= 120 }) {
                        Text("120 bilder/s").tag(120)
                    }
                }
            }
            Menu("Teleprompter") {
                Toggle("Visa manuset under inspelningen", isOn: $settings.teleprompterEnabled)
                Button("Manus …") { app.showScriptEditor() }
            }
        }
        flashbackMenu
        Menu("Skärmdump") {
            Button("Fönster …") { app.screenshots.window() }
            Button("Område …") { app.screenshots.area() }
            Button("Hela skärmen") { app.screenshots.fullScreen() }
            Divider()
            Toggle("Med bakgrund och skugga", isOn: $settings.screenshotPolish)
            Picker("Bakgrund", selection: $settings.screenshotBackground) {
                ForEach(EditProject.Background.presets.indices, id: \.self) { i in
                    Text("Förval \(i + 1)").tag(i)
                }
            }
            .disabled(!settings.screenshotPolish)
        }
        Divider()
        Button("Bibliotek …") { app.showLibrary() }
        Menu("Inställningar") {
            Button("Delning …") { app.showSharingSettings() }
            Button("Kortkommandon …") { app.showHotKeySettings() }
            Button("Behörigheter …") { app.showPermissions() }
        }
        Divider()
        Button("Avsluta Bjarbys skärminspelare") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var flashbackMenu: some View {
        if flashback.isRunning {
            Button(flashback.isSaving ? String(localized: "Sparar …")
                                      : String(localized: "Spara senaste \(settings.flashbackMinutes) min  (\(hotKeys.binding(.flashback).display))")) {
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
