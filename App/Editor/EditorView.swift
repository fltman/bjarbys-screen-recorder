import SwiftUI
import AVKit
import RecorderKit

/// Läser in inspelningen och visar redigeraren, eller ett begripligt fel.
struct EditorHost: View {
    let bundle: RecordingBundle
    @State private var model: EditorModel?
    @State private var error: String?

    var body: some View {
        Group {
            if let model {
                EditorView(model: model)
            } else if let error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text("Inspelningen gick inte att öppna").font(.headline)
                    Text(error).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .task {
            do {
                model = EditorModel(recording: try LoadedRecording.load(bundle))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var keyMonitor: Any?
    @State private var window = WindowBox()

    var body: some View {
        HStack(spacing: 0) {
            if model.transcriptShown {
                TranscriptView(model: model)
                    .frame(width: 290)
                Divider()
            }
            VStack(spacing: 0) {
                PlayerView(player: model.player)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .overlay(CanvasEditOverlay(model: model))
                    .frame(minHeight: 300)
                Divider()
                TransportBar(model: model)
                Divider()
                TimelineView(model: model)
                    .frame(height: TimelineView.height(for: model))
            }
            Divider()
            InspectorView(model: model)
                .frame(width: 310)
        }
        .background(shortcuts)
        .sheet(isPresented: $model.exportPresented) { ExportSheet(model: model) }
        .background(WindowReader(box: window))
        .onAppear { installKeys() }
        .onDisappear {
            model.saveNow(); model.player.pause()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Q och W trimmar delen under spelhuvudet till spelhuvudet (som i Premiere): bokstäver som
    /// ligger likadant på alla tangentbord (⌥[ och ⌥] går inte att trycka på ett svenskt, där
    /// klamrarna själva kräver ⌥). Bara när inget textfält har fokus och bara i redigerarens fönster.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [model, window] event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty, let w = event.window, w === window.window, w.isKeyWindow,
                  !(w.firstResponder is NSText) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q": model.trimToPlayhead(start: true); return nil
            case "w": model.trimToPlayhead(start: false); return nil
            default: return event
            }
        }
    }

    /// Kortkommandon via osynliga knappar.
    private var shortcuts: some View {
        Group {
            Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.split() }.keyboardShortcut("b", modifiers: .command)
            Button("") { model.deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { model.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") { model.exportPresented = true }.keyboardShortcut("e", modifiers: .command)
            Button("") { model.scrub(to: model.currentTime - 1 / 60) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.scrub(to: model.currentTime + 1 / 60) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

private struct TransportBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("Spela/pausa (mellanslag)")
            Text("\(Self.time(model.currentTime)) / \(Self.time(model.duration))")
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Divider().frame(height: 18)
            // Med namn när det får plats, annars bara ikoner (namnen finns i hjälptexten).
            ViewThatFits(in: .horizontal) {
                tools.labelStyle(.titleAndIcon)
                tools.labelStyle(.iconOnly)
            }
            Spacer(minLength: 8)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Ångra (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Gör om (⇧⌘Z)")
            Button { model.exportPresented = true } label: {
                Label("Exportera …", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .help("⌘E")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tools: some View {
        HStack(spacing: 12) {
            Button { model.split() } label: { Label("Dela", systemImage: "scissors") }
                .help("Dela vid spelhuvudet (⌘B)")
            Button { model.addZoomAtPlayhead() } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                .help("Lägg till en zoom vid spelhuvudet")
            Button { model.deleteSelection() } label: { Label("Ta bort", systemImage: "trash") }
                .disabled(model.selectedZoomID == nil && model.selectedSegmentID == nil && model.wordSelection == nil)
                .help("Ta bort markerad zoom, del eller markerade ord (⌫)")
            Toggle(isOn: $model.transcriptShown) { Label("Text", systemImage: "text.quote") }
                .toggleStyle(.button)
                .help("Visa texten")
        }
        .fixedSize()
    }

    static func time(_ s: Double) -> String {
        let t = max(0, s)
        return String(format: "%d:%02d.%d", Int(t) / 60, Int(t) % 60, Int((t * 10).truncatingRemainder(dividingBy: 10)))
    }
}

/// Fönstret en SwiftUI-vy ligger i (för tangenter som bara ska gälla det fönstret).
final class WindowBox { weak var window: NSWindow? }

struct WindowReader: NSViewRepresentable {
    let box: WindowBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { box.window = view.window }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        if box.window == nil { DispatchQueue.main.async { box.window = view.window } }
    }
}
