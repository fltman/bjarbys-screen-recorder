import Foundation
import SwiftUI
import RecorderKit

/// Inställningar som överlever omstart. Enheterna sparas med id; finns enheten inte längre
/// faller valet tillbaka på standardmikrofonen respektive ingen kamera.
@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("micID") var micID: String = "standard"
    @AppStorage("cameraID") var cameraID: String = ""
    @AppStorage("systemAudio") var systemAudio: Bool = true
    @AppStorage("keystrokes") var keystrokes: Bool = false
    @AppStorage("fps") var fps: Int = 60
    /// HDR (10 bit, BT.2020 PQ). Bara på skärmar som kan visa HDR.
    @AppStorage("hdr") var hdr: Bool = false
    static var hdrAvailable: Bool {
        NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
    }
    @AppStorage("countdown") var countdown: Bool = true
    /// whisper.cpp-mappen (med build/bin och models). Tom = leta på de vanliga ställena.
    @AppStorage("whisperRoot") var whisperRoot: String = ""
    /// Modellfilen; tom = bästa som finns för språket.
    @AppStorage("whisperModel") var whisperModel: String = ""
    @AppStorage("speechLanguage") var speechLanguage: String = "sv"
    /// Flashback: spela in i bakgrunden och spara de senaste minuterna i efterhand.
    @AppStorage("flashbackEnabled") var flashbackEnabled: Bool = false
    @AppStorage("flashbackMinutes") var flashbackMinutes: Int = 5
    @AppStorage("flashbackMicrophone") var flashbackMicrophone: Bool = false
    /// Teleprompter: manuset rullar i en ruta vid kameran under inspelningen.
    @AppStorage("teleprompterEnabled") var teleprompterEnabled: Bool = false
    @AppStorage("teleprompterText") var teleprompterText: String = ""
    @AppStorage("teleprompterWPM") var teleprompterWPM: Double = 130
    @AppStorage("teleprompterFontSize") var teleprompterFontSize: Double = 26
    /// Skärmdumparnas bakgrund (förval 0–7) och om de ska poleras alls.
    @AppStorage("screenshotBackground") var screenshotBackground: Int = 0
    @AppStorage("screenshotPolish") var screenshotPolish: Bool = true
    /// Appar med eget ljudspår (JSON-lista med bundle-id och namn).
    @AppStorage("appAudio") private var appAudioJSON: String = "[]"

    var appAudio: [AudioSourceChoice] {
        get { (try? JSONDecoder().decode([AudioSourceChoice].self, from: Data(appAudioJSON.utf8))) ?? [] }
        set { appAudioJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8) ?? "[]") ?? "[]" }
    }

    func isAppChosen(_ bundleID: String) -> Bool { appAudio.contains { $0.bundleID == bundleID } }

    func setApp(_ bundleID: String, name: String, chosen: Bool) {
        var list = appAudio.filter { $0.bundleID != bundleID }
        if chosen { list.append(AudioSourceChoice(bundleID: bundleID, name: name)) }
        appAudio = list
    }

    /// Apparna som är anslutna till ljudsystemet just nu (uppdateras när de kommer och går).
    @Published private(set) var audioApps: [AudioProcesses.App] = []
    private var audioObserver: AnyObject?

    /// Det menyn visar: apparna med ljud just nu, och de valda även om de inte är igång.
    var menuAudioApps: [AudioProcesses.App] {
        let running = audioApps
        let missing = appAudio.filter { c in !running.contains { $0.bundleID == c.bundleID } }
            .map { AudioProcesses.App(bundleID: $0.bundleID, name: $0.name, isPlaying: false) }
        return running + missing
    }

    func refreshAudioApps() { audioApps = AudioProcesses.apps() }

    /// Inställningarna för transkribering, eller nil om whisper.cpp inte går att hitta.
    var whisperSetup: WhisperSetup? {
        let root = whisperRoot.isEmpty ? WhisperSetup.findRoot() : URL(fileURLWithPath: whisperRoot)
        guard let root else { return nil }
        var setup = WhisperSetup(root: root, model: whisperModel, language: speechLanguage)
        if whisperModel.isEmpty || !setup.availableModels.contains(whisperModel) {
            setup.model = WhisperSetup.preferredModel(among: setup.availableModels, language: speechLanguage) ?? ""
        }
        return setup
    }

    @Published private(set) var microphones: [Devices.Device] = []
    @Published private(set) var cameras: [Devices.Device] = []

    init() {
        refreshDevices()
        refreshAudioApps()
        audioObserver = AudioProcesses.observe { [weak self] in self?.refreshAudioApps() }
    }

    func refreshDevices() {
        microphones = Devices.microphones()
        cameras = Devices.cameras()
    }

    var selectedMicrophone: Devices.Device? {
        switch micID {
        case "": return nil
        case "standard": return Devices.defaultMicrophone
        default: return microphones.first { $0.id == micID } ?? Devices.defaultMicrophone
        }
    }

    var selectedCamera: Devices.Device? {
        cameraID.isEmpty ? nil : cameras.first { $0.id == cameraID }
    }

    var captureOptions: CaptureOptions {
        var o = CaptureOptions(fps: fps, systemAudio: systemAudio, microphone: selectedMicrophone,
                               camera: selectedCamera, keystrokes: keystrokes, apps: appAudio)
        o.hdr = hdr && Self.hdrAvailable
        return o
    }
}
