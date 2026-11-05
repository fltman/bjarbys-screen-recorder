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

    init() { refreshDevices() }

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
        CaptureOptions(fps: fps, systemAudio: systemAudio, microphone: selectedMicrophone,
                       camera: selectedCamera, keystrokes: keystrokes)
    }
}
