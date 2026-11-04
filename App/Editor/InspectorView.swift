import SwiftUI
import AppKit
import RecorderKit

/// Inställningarna till höger. Allt här är ett beslut om utseendet; inspelningen rörs aldrig.
struct InspectorView: View {
    @ObservedObject var model: EditorModel

    private func binding<T>(_ keyPath: WritableKeyPath<EditProject, T>) -> Binding<T> {
        Binding(get: { model.project[keyPath: keyPath] }, set: { v in model.update { $0[keyPath: keyPath] = v } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let zoom = model.selectedZoom { zoomSection(zoom) }
                if let seg = model.selectedSegment { segmentSection(seg) }
                backgroundSection
                frameSection
                autoZoomSection
                cursorSection
                if model.recording.hasCamera { cameraSection }
                if model.recording.hasMicrophone || model.recording.hasSystemAudio { audioSection }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Markerat

    private func zoomSection(_ zoom: EditProject.ZoomSegment) -> some View {
        Section2("Markerad zoom", systemImage: "plus.magnifyingglass") {
            LabeledSlider("Förstoring", value: Binding(get: { zoom.scale }, set: { v in model.updateZoom(zoom.id) { $0.scale = v } }),
                          range: 1.1...5, format: "%.1f×")
            Toggle("Följ markören", isOn: Binding(get: { zoom.followsCursor },
                                                  set: { v in model.updateZoom(zoom.id) { $0.followsCursor = v } }))
            LabeledSlider("Mitt, sidled", value: Binding(get: { zoom.centerX }, set: { v in model.updateZoom(zoom.id) { $0.centerX = v } }),
                          range: 0...1, format: "%.2f")
            LabeledSlider("Mitt, höjdled", value: Binding(get: { zoom.centerY }, set: { v in model.updateZoom(zoom.id) { $0.centerY = v } }),
                          range: 0...1, format: "%.2f")
            Text(zoom.isAuto ? "Föreslagen ur klicken. Ändrar du den blir den din och följer inte med när förslagen görs om."
                             : "Din egen zoom.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Ta bort zoomen", role: .destructive) { model.deleteZoom(zoom.id) }
        }
    }

    private func segmentSection(_ seg: EditProject.ClipSegment) -> some View {
        Section2("Markerad del", systemImage: "film") {
            Picker("Hastighet", selection: Binding(get: { seg.speed }, set: { model.setSpeed($0, for: seg.id) })) {
                ForEach([0.5, 1, 1.5, 2, 4, 8], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
            }
            Text("\(String(format: "%.1f", seg.duration)) s i inspelningen").font(.caption).foregroundStyle(.secondary)
            Button("Ta bort delen", role: .destructive) { model.deleteSegment(seg.id) }
                .disabled(model.project.segments.count < 2)
        }
    }

    // MARK: - Utseende

    private var backgroundSection: some View {
        Section2("Bakgrund", systemImage: "paintpalette") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 8), spacing: 8) {
                ForEach(EditProject.Background.presets, id: \.self) { bg in
                    Circle()
                        .fill(LinearGradient(colors: [Color(hex: bg.colorA), Color(hex: bg.colorB)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: model.project.background == bg ? 2.5 : 0).padding(-3))
                        .onTapGesture { model.update { $0.background = bg } }
                }
            }
            Picker("Typ", selection: binding(\.background.kind)) {
                Text("Gradient").tag(EditProject.Background.Kind.gradient)
                Text("Enfärgad").tag(EditProject.Background.Kind.solid)
                Text("Oskärpa").tag(EditProject.Background.Kind.blur)
            }
            .pickerStyle(.segmented)
            if model.project.background.kind != .blur {
                HStack {
                    ColorPicker("Färg", selection: hexBinding(\.background.colorA), supportsOpacity: false)
                    if model.project.background.kind == .gradient {
                        ColorPicker("till", selection: hexBinding(\.background.colorB), supportsOpacity: false)
                    }
                }
                if model.project.background.kind == .gradient {
                    LabeledSlider("Vinkel", value: binding(\.background.angle), range: 0...360, format: "%.0f°")
                }
            }
        }
    }

    private var frameSection: some View {
        Section2("Bild", systemImage: "rectangle.inset.filled") {
            Picker("Format", selection: binding(\.aspect)) {
                Text("Inspelningens").tag(EditProject.Aspect.source)
                Text("16:9 bred").tag(EditProject.Aspect.wide)
                Text("9:16 stående").tag(EditProject.Aspect.vertical)
                Text("1:1 kvadrat").tag(EditProject.Aspect.square)
                Text("4:3").tag(EditProject.Aspect.classic)
            }
            LabeledSlider("Marginal", value: binding(\.padding), range: 0...0.25, format: "%.0f %%", scale: 100)
            LabeledSlider("Hörn", value: binding(\.cornerRadius), range: 0...0.06, format: "%.1f %%", scale: 100)
            LabeledSlider("Skugga", value: binding(\.shadow), range: 0...1, format: "%.0f %%", scale: 100)
        }
    }

    private var autoZoomSection: some View {
        Section2("Zoom", systemImage: "sparkle.magnifyingglass") {
            Toggle("Föreslå zoomar ur klicken", isOn: Binding(get: { model.project.autoZoom }, set: { v in
                model.update { $0.autoZoom = v }
                model.regenerateAutoZooms()
            }))
            LabeledSlider("Förstoring", value: binding(\.zoomScale), range: 1.25...4, format: "%.1f×") { editing in
                if !editing { model.regenerateAutoZooms() }
            }
            HStack {
                Button("Gör om förslagen") { model.regenerateAutoZooms() }
                Button("Ny zoom vid spelhuvudet") { model.addZoomAtPlayhead() }
            }
            .controlSize(.small)
            let auto = model.project.zooms.filter(\.isAuto).count
            let own = model.project.zooms.count - auto
            Text("\(auto) föreslagna, \(own) egna. Dra blocken i tidslinjen för att flytta dem, dra i kanterna för att ändra längd.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cursorSection: some View {
        Section2("Markör", systemImage: "cursorarrow") {
            Toggle("Visa markören", isOn: binding(\.cursor.visible))
            LabeledSlider("Storlek", value: binding(\.cursor.scale), range: 0.8...3, format: "%.1f×")
            LabeledSlider("Utjämning", value: binding(\.cursor.smoothing), range: 0...1, format: "%.0f %%", scale: 100)
            Toggle("Dölj när den står still", isOn: binding(\.cursor.hideWhenIdle))
            Toggle("Visa klick", isOn: binding(\.cursor.clickEffect))
            if !model.plan.cursorPath.hasData {
                Text("Ingen markördata i den här inspelningen.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var cameraSection: some View {
        Section2("Kamera", systemImage: "person.crop.circle") {
            Toggle("Visa kameran", isOn: binding(\.camera.visible))
            Picker("Form", selection: binding(\.camera.shape)) {
                Text("Cirkel").tag(EditProject.CameraStyle.Shape.circle)
                Text("Rundad ruta").tag(EditProject.CameraStyle.Shape.rounded)
            }
            .pickerStyle(.segmented)
            LabeledSlider("Storlek", value: binding(\.camera.size), range: 0.12...0.45, format: "%.0f %%", scale: 100)
            Picker("Hörn", selection: binding(\.camera.corner)) {
                Text("Nere till höger").tag(EditProject.CameraStyle.Corner.bottomRight)
                Text("Nere till vänster").tag(EditProject.CameraStyle.Corner.bottomLeft)
                Text("Uppe till höger").tag(EditProject.CameraStyle.Corner.topRight)
                Text("Uppe till vänster").tag(EditProject.CameraStyle.Corner.topLeft)
            }
            Toggle("Spegelvänd", isOn: binding(\.camera.mirror))
        }
    }

    private var audioSection: some View {
        Section2("Ljud", systemImage: "waveform") {
            if model.recording.hasMicrophone {
                HStack {
                    Toggle("", isOn: Binding(get: { !model.project.audio.microphoneMuted },
                                             set: { v in model.update { $0.audio.microphoneMuted = !v } }))
                        .labelsHidden()
                    LabeledSlider("Mikrofon", value: binding(\.audio.microphoneVolume), range: 0...2, format: "%.0f %%", scale: 100)
                }
            }
            if model.recording.hasSystemAudio {
                HStack {
                    Toggle("", isOn: Binding(get: { !model.project.audio.systemMuted },
                                             set: { v in model.update { $0.audio.systemMuted = !v } }))
                        .labelsHidden()
                    LabeledSlider("Datorljud", value: binding(\.audio.systemVolume), range: 0...2, format: "%.0f %%", scale: 100)
                }
            }
        }
    }

    private func hexBinding(_ keyPath: WritableKeyPath<EditProject, String>) -> Binding<Color> {
        Binding(get: { Color(hex: model.project[keyPath: keyPath]) },
                set: { c in model.update { $0[keyPath: keyPath] = c.hexString } })
    }
}

// MARK: - Byggstenar

private struct Section2<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LabeledSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1
    var onEditingChanged: (Bool) -> Void = { _ in }

    init(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, format: String, scale: Double = 1,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
        self.scale = scale
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value * scale)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
        }
    }
}

extension Color {
    init(hex: String) {
        let c = RenderPlan.color(hex: hex)
        self.init(.sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue))
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()), Int((ns.blueComponent * 255).rounded()))
    }
}
