import SwiftUI
import AppKit
import RecorderKit

/// Fliken Lager: producentens brev, kapitel, bildlager och extra ljud — allt AI-producenten
/// (eller du) har lagt till, och som går att ändra här.
struct LayersInspector: View {
    @ObservedObject var model: EditorModel
    @State private var noteExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let note = model.deliveryNote {
                Section2("Från producenten", systemImage: "envelope.open") {
                    DisclosureGroup(isExpanded: $noteExpanded) {
                        Text(Self.letter(note))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Text("Brevet").font(.callout.weight(.medium)) }
                }
            }
            chapters
            if !model.recording.markers.isEmpty { markers }
            overlays
            audio
        }
    }

    /// Brevet som text: rubriker (#) blir feta rader, resten tolkas som inline-markdown.
    static func letter(_ md: String) -> AttributedString {
        let lines = md.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return line }
            return "**" + t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) + "**"
        }
        let text = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(md)
    }

    // MARK: - Kapitel

    private var chapters: some View {
        Section2("Kapitel", systemImage: "list.number") {
            ForEach(model.project.chapters) { c in
                HStack(spacing: 6) {
                    Button(TransportTime.format(model.timeMap.output(at: c.at) ?? 0)) { seek(source: c.at) }
                        .buttonStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    TextField("Rubrik", text: Binding(get: { c.title }, set: { v in model.updateChapter(c.id) { $0.title = v } }))
                        .textFieldStyle(.roundedBorder)
                    Button { model.deleteChapter(c.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Ta bort kapitlet")
                }
            }
            HStack {
                Button("Nytt kapitel vid spelhuvudet") { model.addChapter() }.controlSize(.small)
                Spacer()
                Toggle("Kapitelrad i bild", isOn: Binding(get: { model.project.showsChapterBanner },
                                                          set: { v in model.update { $0.showsChapterBanner = v } }))
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Markeringar

    /// Markeringarna som sattes under inspelningen (⌃⌥⌘M): hoppa dit, gör kapitel eller dela.
    private var markers: some View {
        Section2("Markeringar", systemImage: "flag") {
            let times = model.recording.markers
            Text("\(times.count) satta under inspelningen.").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(times, id: \.self) { m in
                        Button { seek(source: m) } label: {
                            Label(model.timeMap.output(at: m).map(TransportTime.format) ?? String(localized: "bortklippt"), systemImage: "flag.fill")
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(.orange)
                    }
                }
            }
            HStack {
                Button("Gör till kapitel") {
                    model.update { $0.addChapters(at: times, title: String(localized: "Markering")) }
                }
                .controlSize(.small)
                Button("Dela vid markeringarna") { model.update { $0.split(at: times) } }
                    .controlSize(.small)
                    .help("Delar delarna där markeringarna sitter — sedan kan du ta bort eller trimma det som blev fel.")
            }
        }
    }

    // MARK: - Bildlager

    private static func icon(_ k: Overlay.Kind) -> String {
        switch k {
        case .title: "textformat.size"
        case .callout: "scope"
        case .fact: "text.bubble"
        case .qr: "qrcode"
        case .text: "textformat"
        case .image: "photo"
        case .video: "film"
        case .arrow: "arrow.up.right"
        }
    }

    private static func name(_ k: Overlay.Kind) -> LocalizedStringKey {
        switch k {
        case .title: "Rubrikkort"
        case .callout: "Markering"
        case .fact: "Faktaruta"
        case .qr: "QR-kod"
        case .text: "Text"
        case .image: "Bild"
        case .video: "Video"
        case .arrow: "Pil"
        }
    }

    private var overlays: some View {
        Section2("Bildlager", systemImage: "square.on.square") {
            ForEach(model.project.overlays.sorted { $0.at < $1.at }) { o in overlayRow(o) }
            Menu {
                ForEach(Overlay.Kind.allCases, id: \.self) { k in
                    Button {
                        if k == .image { pickImage() } else if k == .video { pickVideo() } else { model.addOverlay(k) }
                    } label: { Label(Self.name(k), systemImage: Self.icon(k)) }
                }
            } label: { Label("Lägg till vid spelhuvudet", systemImage: "plus") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if model.project.overlays.isEmpty {
                Text("Rubrikkort, markeringar runt det du klickar på, faktarutor och QR-koder. AI-producenten i Claude Code kan lägga dem åt dig.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Beskärning av ett videoinslag: hur mycket som tas bort från varje kant (0–45 %).
    @ViewBuilder private func cropControls(_ o: Overlay) -> some View {
        let c = o.crop ?? Rect(x: 0, y: 0, width: 1, height: 1)
        DisclosureGroup("Beskär") {
            LabeledSlider("Vänster", value: cropBinding(o, c, .left), range: 0...0.45, format: "%.0f %%", scale: 100)
            LabeledSlider("Höger", value: cropBinding(o, c, .right), range: 0...0.45, format: "%.0f %%", scale: 100)
            LabeledSlider("Uppe", value: cropBinding(o, c, .top), range: 0...0.45, format: "%.0f %%", scale: 100)
            LabeledSlider("Nere", value: cropBinding(o, c, .bottom), range: 0...0.45, format: "%.0f %%", scale: 100)
            if o.crop != nil {
                Button("Visa hela") { model.updateOverlay(o.id) { $0.crop = nil } }.controlSize(.small)
            }
        }
    }

    private enum Edge { case left, right, top, bottom }

    private func cropBinding(_ o: Overlay, _ c: Rect, _ edge: Edge) -> Binding<Double> {
        Binding(get: {
            switch edge {
            case .left: c.x
            case .right: 1 - c.x - c.width
            case .top: c.y
            case .bottom: 1 - c.y - c.height
            }
        }, set: { v in
            model.updateOverlay(o.id) { ov in
                var r = ov.crop ?? Rect(x: 0, y: 0, width: 1, height: 1)
                let right = 1 - r.x - r.width, bottom = 1 - r.y - r.height
                switch edge {
                case .left: r.x = v; r.width = 1 - v - right
                case .right: r.width = 1 - r.x - v
                case .top: r.y = v; r.height = 1 - v - bottom
                case .bottom: r.height = 1 - r.y - v
                }
                r.width = max(0.1, r.width); r.height = max(0.1, r.height)
                ov.crop = (r.x < 0.001 && r.y < 0.001 && r.width > 0.999 && r.height > 0.999) ? nil : r
            }
        })
    }

    private func overlayRow(_ o: Overlay) -> some View {
        let selected = model.selectedOverlayID == o.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: Self.icon(o.kind)).frame(width: 18).foregroundStyle(Color.accentColor)
                Text(o.title.isEmpty ? String(localized: "(utan text)") : o.title).lineLimit(1)
                Spacer()
                Text(TransportTime.format(model.timeMap.output(at: o.at) ?? 0))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectedOverlayID = selected ? nil : o.id
                if !selected { seek(source: o.at + 0.4) }
            }
            if selected {
                TextField("Text", text: Binding(get: { o.title }, set: { v in model.updateOverlay(o.id) { $0.title = v } }))
                    .textFieldStyle(.roundedBorder)
                if o.kind == .fact || o.kind == .title || o.kind == .qr {
                    TextField(o.kind == .fact ? "Rader (en per rad)" : "Underrad", text: Binding(
                        get: { o.lines.joined(separator: "\n") },
                        set: { v in model.updateOverlay(o.id) { $0.lines = v.split(separator: "\n").map(String.init) } }),
                              axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                }
                if o.kind == .qr {
                    TextField("Adress", text: Binding(get: { o.url }, set: { v in model.updateOverlay(o.id) { $0.url = v } }))
                        .textFieldStyle(.roundedBorder)
                }
                if o.kind == .arrow {
                    Picker("Färg", selection: Binding(get: { o.color }, set: { v in model.updateOverlay(o.id) { $0.color = v } })) {
                        Text("Röd").tag("#FF3B30")
                        Text("Gul").tag("#FFD60A")
                        Text("Blå").tag("#0A84FF")
                        Text("Grön").tag("#30D158")
                        Text("Vit").tag("#FFFFFF")
                    }
                    Text("Dra pilen i bilden, och spetsen eller starten med handtagen.").font(.caption).foregroundStyle(.secondary)
                }
                if o.kind == .text {
                    LabeledSlider("Textstorlek", value: Binding(get: { o.size }, set: { v in model.updateOverlay(o.id) { $0.size = v } }),
                                  range: 0.5...2.5, format: "%.0f %%", scale: 100)
                    Toggle("På en platta", isOn: Binding(get: { o.background }, set: { v in model.updateOverlay(o.id) { $0.background = v } }))
                }
                if o.kind == .video {
                    Toggle("Helbild", isOn: Binding(get: { o.isFullFrame }, set: { v in
                        model.updateOverlay(o.id) { $0.frame = v ? Rect(x: 0, y: 0, width: 1, height: 1) : Rect(x: 0.6, y: 0.08, width: 0.34, height: 0.34) }
                    }))
                    LabeledSlider("Ljud", value: Binding(get: { o.volume }, set: { v in model.updateOverlay(o.id) { $0.volume = v } }),
                                  range: 0...1.5, format: "%.0f %%", scale: 100)
                    Picker("Hastighet", selection: Binding(get: { o.speed }, set: { v in
                        // Samma del av filen: längden i filmen ändras med farten.
                        model.updateOverlay(o.id) { $0.duration = max(0.3, $0.duration * $0.speed / v); $0.speed = v }
                    })) {
                        ForEach([0.25, 0.5, 0.75, 1, 1.5, 2, 4], id: \.self) { Text(AppLocale.format("%g×", $0)).tag($0) }
                    }
                    cropControls(o)
                    LabeledSlider("Mjuka kanter", value: Binding(get: { o.softness }, set: { v in model.updateOverlay(o.id) { $0.softness = v } }),
                                  range: 0...1, format: "%.0f %%", scale: 100)
                        .disabled(o.isFullFrame)
                }
                if o.kind == .text || o.kind == .image || (o.kind == .video && !o.isFullFrame) {
                    let f = o.frame ?? Rect(x: 0.5, y: 0.5, width: 0.5, height: 0.3)
                    LabeledSlider("Sidled", value: frameBinding(o.id, \.x, f), range: 0...1, format: "%.2f")
                    LabeledSlider("Höjdled", value: frameBinding(o.id, \.y, f), range: 0...1, format: "%.2f")
                    LabeledSlider(o.kind == .text ? "Största bredd" : "Storlek", value: Binding(get: { f.width }, set: { v in
                        model.updateOverlay(o.id) { ov in
                            var r = ov.frame ?? f
                            if ov.kind != .text { r.height *= v / max(r.width, 0.01) }
                            r.width = v
                            ov.frame = r
                        }
                    }), range: 0.08...1, format: "%.2f")
                }
                if o.kind == .fact || o.kind == .qr {
                    Picker("Hörn", selection: Binding(get: { o.corner }, set: { v in model.updateOverlay(o.id) { $0.corner = v } })) {
                        Text("Uppe till vänster").tag(Overlay.Corner.topLeft)
                        Text("Uppe till höger").tag(Overlay.Corner.topRight)
                        Text("Nere till vänster").tag(Overlay.Corner.bottomLeft)
                        Text("Nere till höger").tag(Overlay.Corner.bottomRight)
                    }
                }
                if [.title, .text, .image, .fact, .qr].contains(o.kind) {
                    Picker("In", selection: Binding(get: { o.animation }, set: { v in model.updateOverlay(o.id) { $0.animation = v } })) {
                        Text("Tona").tag(Overlay.Animation.fade)
                        Text("Glid upp").tag(Overlay.Animation.slide)
                        Text("Poppa").tag(Overlay.Animation.pop)
                        if o.kind == .text || o.kind == .title { Text("Skrivmaskin").tag(Overlay.Animation.typewriter) }
                    }
                    .help("Hur lagret kommer in i bilden.")
                }
                LabeledSlider("Längd", value: Binding(get: { o.duration }, set: { v in model.updateOverlay(o.id) { $0.duration = v } }),
                              range: 1...12, format: "%.1f s")
                HStack {
                    Button("Flytta hit") { let s = model.sourceTimeAtPlayhead; model.updateOverlay(o.id) { $0.at = s } }
                        .help("Börja vid spelhuvudet")
                    Spacer()
                    Button("Ta bort", role: .destructive) { model.deleteOverlay(o.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.1) : .clear))
    }

    // MARK: - Ljud

    private var audio: some View {
        Section2("Extra ljud", systemImage: "music.note.list") {
            ForEach(model.project.audioClips) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: c.role == .music ? "music.note" : (c.role == .narration ? "person.wave.2" : (c.role == .dub ? "character.bubble" : "speaker.wave.1")))
                            .frame(width: 18).foregroundStyle(Color.accentColor)
                        Text(c.text.isEmpty ? c.file : c.text).lineLimit(1).font(.callout)
                        Spacer()
                        Button { model.deleteAudio(c.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Ta bort ljudklippet")
                    }
                    LabeledSlider("Volym", value: Binding(get: { c.volume }, set: { v in model.updateAudio(c.id) { $0.volume = v } }),
                                  range: 0...1.5, format: "%.0f %%", scale: 100)
                }
            }
            HStack {
                Button("Musik …") { pick(.music) }
                Button("Ljudeffekt …") { pick(.effect) }
            }
            .controlSize(.small)
            Text("Musiken sänks under tal och berättarröst. Berättarröst görs med AI-producenten i Claude Code.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func frameBinding(_ id: UUID, _ key: WritableKeyPath<Rect, Double>, _ f: Rect) -> Binding<Double> {
        Binding(get: { f[keyPath: key] }, set: { v in model.updateOverlay(id) { o in var r = o.frame ?? f; r[keyPath: key] = v; o.frame = r } })
    }

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK, let url = panel.url { model.addVideoOverlay(from: url) }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { model.addImageOverlay(from: url) }
    }

    private func pick(_ role: AudioClip.Role) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.addAudio(from: url, role: role) }
    }

    private func seek(source s: Double) {
        if let t = model.timeMap.output(at: s) { model.scrub(to: t) }
    }
}
