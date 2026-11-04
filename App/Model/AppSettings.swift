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
