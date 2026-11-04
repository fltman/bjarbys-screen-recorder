import Foundation
import AppKit
import SwiftUI
import ScreenCaptureKit
import RecorderKit

/// Styr en inspelning från val av källa till stopp: nedräkning, HUD, kameraförhandsvisning
/// och vad som händer efteråt.
@MainActor
final class RecordingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case choosing
        case countdown(Int)
        case recording
        case stopping
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = CaptureSession.Status()
    @Published private(set) var sourceTitle = ""

    let settings: AppSettings
    let library: LibraryModel
    /// Anropas när en inspelning är klar, med paketet (redigeraren öppnas där).
    var onFinished: ((RecordingBundle) -> Void)?
    var onNeedsPermissions: (() -> Void)?

    private(set) var session: CaptureSession?
    private let picker = ContentPicker()
    private var hud: HUDPanel?
    private var countdownPanel: CountdownPanel?
    private var cameraPanel: CameraPreviewPanel?
    private var areaSelector: AreaSelector?

    init(settings: AppSettings, library: LibraryModel) {
        self.settings = settings
        self.library = library
    }

    var isBusy: Bool { phase != .idle }
    var activeBundleURL: URL? { session?.bundle.url }

    // MARK: - Välja källa

    /// Hela skärmen som muspekaren står på.
    func recordDisplayUnderMouse() {
        guard ensurePermission() else { return }
        Task {
            phase = .choosing
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
                let id = screen.flatMap { Self.displayID(of: $0) } ?? CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                    phase = .idle; return
                }
                await begin(CaptureTarget.display(display, in: content))
            } catch {
                fail("Skärmen gick inte att läsa: \(error.localizedDescription)")
            }
        }
    }

    func recordWindow() {
        guard ensurePermission() else { return }
        Task {
            phase = .choosing
            guard let filter = await picker.pick([.singleWindow], style: .window) else {
                phase = .idle; return
            }
            await begin(CaptureTarget.fromPicker(filter))
        }
    }

    func recordApplication() {
        guard ensurePermission() else { return }
        Task {
            phase = .choosing
            guard let filter = await picker.pick([.singleApplication], style: .application) else {
                phase = .idle; return
            }
            await begin(CaptureTarget.fromPicker(filter))
        }
    }

    func recordArea() {
        guard ensurePermission() else { return }
        phase = .choosing
        let selector = AreaSelector()
        areaSelector = selector
        selector.run { [weak self] rect in
            guard let self else { return }
            self.areaSelector = nil
            guard let rect else { self.phase = .idle; return }
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    guard let display = content.displays.first(where: { $0.frame.contains(center) })
                            ?? content.displays.first else { self.phase = .idle; return }
                    await self.begin(CaptureTarget.area(rect, on: display, in: content))
                } catch {
                    self.fail("Skärmen gick inte att läsa: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Kortkommandot: stoppa om det spelas in, annars spela in skärmen under pekaren.
    func toggleFromHotKey() {
        switch phase {
        case .recording: Task { await stop() }
        case .idle: recordDisplayUnderMouse()
        default: break
        }
    }

    // MARK: - Starta

    private func begin(_ target: CaptureTarget) async {
        sourceTitle = target.title
        if settings.countdown {
            let panel = CountdownPanel(on: target.displayID)
            countdownPanel = panel
            for n in stride(from: 3, through: 1, by: -1) {
                phase = .countdown(n)
                panel.show(n)
                try? await Task.sleep(for: .milliseconds(900))
                if phase == .idle { panel.close(); countdownPanel = nil; return }
            }
            panel.close()
            countdownPanel = nil
        }
        do {
            let session = try CaptureSession(target: target, options: settings.captureOptions,
                                             directory: library.directory)
            session.onStatus = { [weak self] s in self?.status = s }
            session.onAutoStop = { [weak self] reason in
                Task { await self?.stop(reason: reason) }
            }
            self.session = session
            try await session.start()
            phase = .recording
            showHUD(on: target.displayID)
            if let camera = session.camera {
                let panel = CameraPreviewPanel(session: camera.session, on: target.displayID)
                panel.orderFrontRegardless()
                cameraPanel = panel
            }
        } catch {
            if let bundle = session?.bundle {
                try? FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
            }
            session = nil
            fail("Inspelningen kunde inte starta: \(error.localizedDescription)")
        }
    }

    func cancelCountdown() {
        if case .countdown = phase { phase = .idle }
    }

    // MARK: - Under inspelning

    func togglePause() {
        guard let session, phase == .recording else { return }
        if session.clock.isPaused { session.resume() } else { session.pause() }
    }

    func stop(reason: CaptureSession.StopReason = .user) async {
        guard let session, phase == .recording else { return }
        phase = .stopping
        closePanels()
        let meta = await session.stop(reason: reason)
        self.session = nil
        phase = .idle
        status = CaptureSession.Status()
        library.reload()
        switch reason {
        case .diskFull:
            let gb = Double(DiskSpace.freeBytes(at: library.directory) ?? 0) / 1e9
            alert("Inspelningen stoppades eftersom disken nästan är full",
                  String(format: "%.1f GB ledigt. Allt fram till stoppet är sparat (%@).", gb,
                         Self.duration(meta.duration)))
        case .streamFailed(let why):
            alert("Inspelningen avbröts", "Skärmströmmen slutade svara (\(why)). Allt fram till avbrottet är sparat.")
        case .user, .sharingStopped:
            break
        }
        if meta.track(.screen) != nil {
            onFinished?(session.bundle)
        }
    }

    func discard() async {
        guard let session, phase == .recording else { return }
        phase = .stopping
        closePanels()
        await session.discard()
        self.session = nil
        phase = .idle
        status = CaptureSession.Status()
        library.reload()
    }

    // MARK: - Hjälp

    private func showHUD(on displayID: CGDirectDisplayID) {
        let panel = HUDPanel(controller: self, on: displayID)
        panel.orderFrontRegardless()
        hud = panel
    }

    private func closePanels() {
        hud?.close(); hud = nil
        cameraPanel?.close(); cameraPanel = nil
        countdownPanel?.close(); countdownPanel = nil
    }

    private func ensurePermission() -> Bool {
        guard phase == .idle else { return false }
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        onNeedsPermissions?()
        return false
    }

    private func fail(_ message: String) {
        phase = .idle
        closePanels()
        alert("Något gick fel", message)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        NSApp.activate()
        a.runModal()
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == displayID }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
