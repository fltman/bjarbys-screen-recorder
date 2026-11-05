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

    // MARK: - Bildlager

    private static func icon(_ k: Overlay.Kind) -> String {
        switch k {
        case .title: "textformat.size"
        case .callout: "scope"
        case .fact: "text.bubble"
        case .qr: "qrcode"
        case .text: "textformat"
        case .image: "photo"
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
        }
    }

    private var overlays: some View {
        Section2("Bildlager", systemImage: "square.on.square") {
            ForEach(model.project.overlays.sorted { $0.at < $1.at }) { o in overlayRow(o) }
            Menu {
                ForEach(Overlay.Kind.allCases, id: \.self) { k in
                    Button {
                        if k == .image { pickImage() } else { model.addOverlay(k) }
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
                if o.kind == .text {
                    LabeledSlider("Textstorlek", value: Binding(get: { o.size }, set: { v in model.updateOverlay(o.id) { $0.size = v } }),
                                  range: 0.5...2.5, format: "%.0f %%", scale: 100)
                    Toggle("På en platta", isOn: Binding(get: { o.background }, set: { v in model.updateOverlay(o.id) { $0.background = v } }))
                }
                if o.kind == .text || o.kind == .image {
                    let f = o.frame ?? Rect(x: 0.5, y: 0.5, width: 0.5, height: 0.3)
                    LabeledSlider("Sidled", value: frameBinding(o.id, \.x, f), range: 0...1, format: "%.2f")
                    LabeledSlider("Höjdled", value: frameBinding(o.id, \.y, f), range: 0...1, format: "%.2f")
                    LabeledSlider(o.kind == .text ? "Största bredd" : "Storlek", value: Binding(get: { f.width }, set: { v in
                        model.updateOverlay(o.id) { ov in
                            var r = ov.frame ?? f
                            if ov.kind == .image { r.height *= v / max(r.width, 0.01) }
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
                        Image(systemName: c.role == .music ? "music.note" : (c.role == .narration ? "person.wave.2" : "speaker.wave.1"))
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
