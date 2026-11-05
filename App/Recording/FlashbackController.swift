import Foundation
import AppKit
import ScreenCaptureKit
import RecorderKit

/// Flashback i appen: bufferten går i bakgrunden när den är påslagen, och "Spara" gör de
/// senaste minuterna till en vanlig inspelning som öppnas i redigeraren.
@MainActor
final class FlashbackController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isSaving = false
    @Published private(set) var lastError: String?
    private var recorder: FlashbackRecorder?
    private var diskTimer: Timer?
    private let settings: AppSettings

    static let workDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("com.brattoo.skarminspelare/flashback", isDirectory: true)

    init(settings: AppSettings) { self.settings = settings }

    /// Startar eller stoppar efter inställningen.
    func apply() {
        if settings.flashbackEnabled { Task { await start() } } else { Task { await stop() } }
    }

    func start() async {
        guard recorder == nil, CGPreflightScreenCaptureAccess() else { return }
        if let free = DiskSpace.freeBytes(at: RecordingLibrary.defaultDirectory.deletingLastPathComponent()),
           free < DiskSpace.warnBelow {
            lastError = String(localized: "För lite ledigt diskutrymme för flashback.")
            return
        }
        var options = CaptureOptions()
        options.systemAudio = settings.systemAudio
        options.keystrokes = settings.keystrokes
        // Mikrofonen bara om det är uttryckligen valt: en mikrofon som alltid är på syns
        // (orange prick) och är inte vad man väntar sig av en bakgrundsbuffert.
        if settings.flashbackMicrophone { options.microphone = settings.selectedMicrophone }
        let r = FlashbackRecorder(bufferSeconds: Double(settings.flashbackMinutes) * 60, segmentSeconds: 60,
                                  directory: Self.workDirectory, options: options) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                throw FlashbackError.empty
            }
            return CaptureTarget.display(display, in: content)
        }
        r.onError = { [weak self] e in self?.lastError = e.localizedDescription }
        do {
            try await r.start()
            recorder = r
            isRunning = true
            lastError = nil
            diskTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkDisk() }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() async {
        diskTimer?.invalidate()
        diskTimer = nil
        if let r = recorder { await r.stop() }
        recorder = nil
        isRunning = false
    }

    /// Sparar de senaste minuterna och öppnar dem i redigeraren.
    func save() {
        guard let r = recorder, !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let bundle = try await r.save(last: Double(settings.flashbackMinutes) * 60,
                                              into: RecordingLibrary.defaultDirectory)
                AppModel.shared.library.reload()
                AppModel.shared.openEditor(bundle)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func checkDisk() {
        guard let free = DiskSpace.freeBytes(at: Self.workDirectory), free < DiskSpace.stopBelow * 2 else { return }
        lastError = String(localized: "Flashback stoppades: disken håller på att ta slut.")
        settings.flashbackEnabled = false
        Task { await stop() }
    }
}
