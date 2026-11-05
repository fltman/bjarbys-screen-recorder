import Foundation
import AppKit
import SwiftUI
import AVFoundation
import RecorderKit

/// Flytande panel som aldrig stjäl fokus från appen som spelas in. Appen är utesluten ur
/// inspelningsfiltret, så panelerna syns bara för den som spelar in.
class FloatingPanel: NSPanel {
    init(size: CGSize, on displayID: CGDirectDisplayID, place: (NSRect, CGSize) -> CGPoint) {
        let screen = RecordingController.screen(for: displayID) ?? NSScreen.main ?? NSScreen.screens[0]
        let origin = place(screen.visibleFrame, size)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - HUD

final class HUDPanel: FloatingPanel {
    init(controller: RecordingController, on displayID: CGDirectDisplayID) {
        let size = CGSize(width: 340, height: 120)
        super.init(size: size, on: displayID) { visible, size in
            CGPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 12)
        }
        contentView = NSHostingView(rootView: HUDView(controller: controller))
    }
}

struct HUDView: View {
    @ObservedObject var controller: RecordingController
    @State private var confirmDiscard = false

    var body: some View {
        let s = controller.status
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(s.isPaused ? Color.orange : Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(s.isPaused ? 1 : (Int(s.elapsed * 2) % 2 == 0 ? 1 : 0.35))
                Text(RecordingController.duration(s.elapsed))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                Spacer()
                if confirmDiscard {
                    Button("Släng") { Task { await controller.discard() } }
                        .tint(.red)
                    Button("Avbryt") { confirmDiscard = false }
                } else {
                    Button { controller.togglePause() } label: {
                        Image(systemName: s.isPaused ? "play.fill" : "pause.fill")
                    }
                    .help(s.isPaused ? "Fortsätt (⌃⌥⌘P)" : "Pausa (⌃⌥⌘P)")
                    Button { Task { await controller.stop() } } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stoppa (⌃⌥⌘R)")
                    Button { confirmDiscard = true } label: {
                        Image(systemName: "trash")
                    }
                    .help("Släng tagningen")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if controller.settings.selectedMicrophone != nil {
                LevelRow(icon: "mic.fill", level: s.micLevel)
            }
            if controller.settings.systemAudio {
                LevelRow(icon: "speaker.wave.2.fill", level: s.systemLevel)
            }
            ForEach(Array(s.appLevels.enumerated()), id: \.offset) { _, level in
                LevelRow(icon: "app.badge.fill", level: level)
            }
            if let warning = warning(s) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func warning(_ s: CaptureSession.Status) -> String? {
        if s.micSilent, let mic = controller.settings.selectedMicrophone {
            return String(localized: "Ingen signal från \(mic.name)")
        }
        if !s.failedTracks.isEmpty {
            return String(localized: "Spår som slutat fungera: \(s.failedTracks.map(\.rawValue).joined(separator: ", "))")
        }
        if s.diskLow, let free = s.freeBytes {
            return String(localized: "Disken håller på att ta slut: \(String(format: "%.1f", Double(free) / 1e9)) GB kvar")
        }
        if s.droppedFrames > 30 { return String(localized: "\(s.droppedFrames) rutor tappade") }
        return s.notice
    }
}

private struct LevelRow: View {
    let icon: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary)
            GeometryReader { geo in
                // Logaritmisk skala, −60 dB till 0 dB.
                let db = 20 * log10(max(level, 0.000_001))
                let fraction = CGFloat(max(0, min(1, (db + 60) / 60)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(fraction > 0.95 ? Color.red : (fraction > 0.8 ? Color.yellow : Color.green))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Nedräkning

final class CountdownPanel: FloatingPanel {
    private let model = CountdownModel()

    init(on displayID: CGDirectDisplayID) {
        let size = CGSize(width: 220, height: 220)
        super.init(size: size, on: displayID) { visible, size in
            CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        ignoresMouseEvents = true
        hasShadow = false
        contentView = NSHostingView(rootView: CountdownView(model: model))
    }

    func show(_ n: Int) {
        model.number = n
        orderFrontRegardless()
    }
}

private final class CountdownModel: ObservableObject {
    @Published var number = 3
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    @State private var drain: CGFloat = 1

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.62))
            Circle().stroke(.white.opacity(0.14), lineWidth: 6).padding(10)
            // Ringen töms under varje sekund.
            Circle()
                .trim(from: 0, to: drain)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(10)
            Text("\(model.number)")
                .font(.system(size: 104, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: model.number)
        }
        .frame(width: 200, height: 200)
        .onChange(of: model.number, initial: true) { _, _ in
            drain = 1
            withAnimation(.linear(duration: 0.95)) { drain = 0 }
        }
    }
}

// MARK: - Kameraförhandsvisning

/// Förhandsvisning av kameran medan det spelas in. Det inspelade kameraspåret är alltid
/// helt och oberoende av den här bubblan.
final class CameraPreviewPanel: FloatingPanel {
    init(session: AVCaptureSession, on displayID: CGDirectDisplayID) {
        let size = CGSize(width: 180, height: 180)
        super.init(size: size, on: displayID) { visible, size in
            CGPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
        }
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.cornerRadius = size.width / 2
        preview.masksToBounds = true
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        view.layer?.addSublayer(preview)
        contentView = view
    }
}
