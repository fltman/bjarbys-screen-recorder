import SwiftUI
import UniformTypeIdentifiers
import AppKit
import RecorderKit

/// Inställningarna till höger. Allt här är ett beslut om utseendet; inspelningen rörs aldrig.
struct InspectorView: View {
    @ObservedObject var model: EditorModel

    private func binding<T>(_ keyPath: WritableKeyPath<EditProject, T>) -> Binding<T> {
        Binding(get: { model.project[keyPath: keyPath] }, set: { v in model.update { $0[keyPath: keyPath] = v } })
    }

    /// Flikarna: efter vad man håller på med, så att varje flik ryms utan att rulla.
    enum Tab: String, CaseIterable, Identifiable {
        case style, motion, layers, speech, privacy
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .style: "paintpalette"
            case .motion: "cursorarrow.motionlines"
            case .layers: "square.stack.3d.up"
            case .speech: "waveform"
            case .privacy: "eye.slash"
            }
        }
        var title: LocalizedStringKey {
            switch self {
            case .style: "Stil"
            case .motion: "Rörelse"
            case .layers: "Lager"
            case .speech: "Tal"
            case .privacy: "Dölj"
            }
        }
    }

    @AppStorage("inspectorTab") private var tab: Tab = .style
    /// Ökas när standardutseendet sparas eller glöms, så att avsnittet ritas om.
    @State private var styleRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Det markerade först, oavsett flik.
                    if let zoom = model.selectedZoom { zoomSection(zoom); Divider() }
                    if let seg = model.selectedSegment { segmentSection(seg); Divider() }
                    switch tab {
                    case .style:
                        backgroundSection
                        frameSection
                        transitionSection
                        if model.recording.hasCamera { cameraSection }
                        watermarkSection
                        standardStyleSection
                    case .motion:
                        autoZoomSection
                        cursorSection
                        if !model.plan.inkTrack.isEmpty { inkSection }
                        shortcutSection
                    case .layers:
                        LayersInspector(model: model)
                    case .speech:
                        if model.recording.hasMicrophone || model.recording.hasComputerAudio {
                            speechSection
                            audioSection
                        } else {
                            Text("Inspelningen har inget ljud.").foregroundStyle(.secondary)
                        }
                    case .privacy:
                        maskSection
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Markeras något i tidslinjen visas fliken där det hör hemma.
        .onChange(of: model.selectedMaskID) { _, id in if id != nil { tab = .privacy } }
        .onChange(of: model.selectedOverlayID) { _, id in if id != nil { tab = .layers } }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 15, weight: .medium))
                        Text(t.title).font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(tab == t ? Color.accentColor.opacity(0.12) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Markerat

    private func zoomSection(_ zoom: EditProject.ZoomSegment) -> some View {
        Section2("Markerad zoom", systemImage: "plus.magnifyingglass") {
            Picker("Sort", selection: Binding(get: { zoom.style }, set: { v in model.updateZoom(zoom.id) { $0.style = v } })) {
                Text("Kamera").tag(EditProject.ZoomSegment.Style.camera)
                Text("Lupp").tag(EditProject.ZoomSegment.Style.lens)
                Text("Strålkastare").tag(EditProject.ZoomSegment.Style.spotlight)
            }
            .pickerStyle(.segmented)
            .help("Kameran zoomar in, ett förstoringsglas följer markören, eller allt utom området runt markören dämpas.")
            if zoom.style != .spotlight {
                LabeledSlider("Förstoring", value: Binding(get: { zoom.scale }, set: { v in model.updateZoom(zoom.id) { $0.scale = v } }),
                              range: 1.1...5, format: "%.1f×")
            }
            if zoom.style == .camera {
                Toggle("Följ markören", isOn: Binding(get: { zoom.followsCursor },
                                                      set: { v in model.updateZoom(zoom.id) { $0.followsCursor = v } }))
                LabeledSlider("Mitt, sidled", value: Binding(get: { zoom.centerX }, set: { v in model.updateZoom(zoom.id) { $0.centerX = v } }),
                              range: 0...1, format: "%.2f")
                LabeledSlider("Mitt, höjdled", value: Binding(get: { zoom.centerY }, set: { v in model.updateZoom(zoom.id) { $0.centerY = v } }),
                              range: 0...1, format: "%.2f")
            }
            Text(zoom.isAuto ? "Föreslagen ur klicken. Ändrar du den blir den din och följer inte med när förslagen görs om."
                             : "Din egen zoom.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Ta bort zoomen", role: .destructive) { model.deleteZoom(zoom.id) }
        }
    }

    private func segmentSection(_ seg: EditProject.ClipSegment) -> some View {
        Section2("Markerad del", systemImage: "film") {
            Picker("Hastighet", selection: Binding(get: { seg.speed }, set: { model.setSpeed($0, for: seg.id) })) {
                ForEach([0.25, 0.5, 1, 1.5, 2, 4, 8], id: \.self) { Text(AppLocale.format("%g×", $0)).tag($0) }
            }
            if model.recording.hasCamera {
                Picker("Kamera", selection: Binding(get: { seg.cameraLayout?.rawValue ?? "standard" }, set: { v in
                    model.setCameraLayout(EditProject.CameraLayout(rawValue: v), for: seg.id)
                })) {
                    Text("Som standard").tag("standard")
                    Text("Bubbla").tag(EditProject.CameraLayout.bubble.rawValue)
                    Text("Stor").tag(EditProject.CameraLayout.large.rawValue)
                    Text("Sida vid sida").tag(EditProject.CameraLayout.split.rawValue)
                    Text("Dold").tag(EditProject.CameraLayout.hidden.rawValue)
                }
                .help("Hur kameran visas i den här delen. Bytet mellan delar glider på en halv sekund.")
            }
            Text("\(AppLocale.format("%.1f", seg.duration)) s i inspelningen").font(.caption).foregroundStyle(.secondary)
            Text("Dra i ändarna i tidslinjen för att trimma (⌥ ändrar farten), dra delen för att flytta den. Q och W trimmar början och slutet till spelhuvudet.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Övergången in i delen (inte för den första).
            if model.project.segments.first?.id != seg.id {
                Picker("Övergång in", selection: Binding(
                    get: { seg.transitionIn?.kind.rawValue ?? "standard" },
                    set: { v in
                        if v == "standard" { model.setTransition(nil, for: seg.id) }
                        else if let k = EditProject.Transition.Kind(rawValue: v) {
                            model.setTransition(.init(kind: k, duration: seg.transitionIn?.duration ?? model.project.transition.duration), for: seg.id)
                        }
                    })) {
                    Text("Standard").tag("standard")
                    Text("Ingen").tag(EditProject.Transition.Kind.none.rawValue)
                    Text("Via svart").tag(EditProject.Transition.Kind.dip.rawValue)
                    Text("Oskärpa").tag(EditProject.Transition.Kind.blur.rawValue)
                    Text("Blixt").tag(EditProject.Transition.Kind.flash.rawValue)
                    Text("Övertoning").tag(EditProject.Transition.Kind.crossfade.rawValue)
                }
                if let tr = seg.transitionIn, tr.kind != .none {
                    LabeledSlider("Längd", value: Binding(get: { tr.duration }, set: { v in
                        model.setTransition(.init(kind: tr.kind, duration: v), for: seg.id)
                    }), range: 0.2...2, format: "%.1f s")
                }
            }
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
            HStack(spacing: 6) {
                Text("Snabbval").foregroundStyle(.secondary)
                Button("YouTube") { model.update { $0.apply(platform: .youtube) } }
                    .help("16:9, hela inspelningen, undertexter på platta nere")
                Button("Reel / Shorts") { model.update { $0.apply(platform: .reel) } }
                    .help("9:16 som fyller bilden och följer markören, undertexter med kontur mitt i")
                Button("Kvadrat") { model.update { $0.apply(platform: .square) } }
                    .help("1:1, hela inspelningen, undertexter med kontur nere")
            }
            .controlSize(.small)
            Picker("Format", selection: binding(\.aspect)) {
                Text("Inspelningens").tag(EditProject.Aspect.source)
                Text("16:9 bred").tag(EditProject.Aspect.wide)
                Text("9:16 stående").tag(EditProject.Aspect.vertical)
                Text("1:1 kvadrat").tag(EditProject.Aspect.square)
                Text("4:3").tag(EditProject.Aspect.classic)
            }
            if model.project.aspect != .source {
                Picker("Innehåll", selection: binding(\.framing)) {
                    Text("Hela inspelningen").tag(EditProject.Framing.fit)
                    Text("Fyll och följ markören").tag(EditProject.Framing.fill)
                }
            }
            let fills = model.project.framing == .fill && model.project.aspect != .source
            Group {
                LabeledSlider("Marginal", value: binding(\.padding), range: 0...0.25, format: "%.0f %%", scale: 100)
                LabeledSlider("Hörn", value: binding(\.cornerRadius), range: 0...0.06, format: "%.1f %%", scale: 100)
                LabeledSlider("Skugga", value: binding(\.shadow), range: 0...1, format: "%.0f %%", scale: 100)
                Picker("Fönsterram", selection: binding(\.chrome.kind)) {
                    Text("Ingen").tag(EditProject.ChromeStyle.Kind.none)
                    Text("macOS-fönster").tag(EditProject.ChromeStyle.Kind.mac)
                    Text("Webbläsare").tag(EditProject.ChromeStyle.Kind.browser)
                }
                .help("En ritad titelrad ovanför inspelningen — bra för ett område, som annars saknar fönsterram.")
                if model.project.chrome.kind != .none {
                    Toggle("Mörk titelrad", isOn: binding(\.chrome.dark))
                    if model.project.chrome.kind == .mac {
                        TextField("Titel", text: binding(\.chrome.title), prompt: Text("Ingen titel"))
                    } else {
                        TextField("Adress", text: binding(\.chrome.address), prompt: Text(verbatim: "example.com"))
                    }
                }
            }
            .disabled(fills)
            if fills {
                Text("Inspelningen fyller bilden och beskärs. Bilden följer markören, även utan zoom.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var transitionSection: some View {
        Section2("Övergångar", systemImage: "rectangle.2.swap") {
            Picker("I snitten", selection: binding(\.transition.kind)) {
                Text("Ingen").tag(EditProject.Transition.Kind.none)
                Text("Via svart").tag(EditProject.Transition.Kind.dip)
                Text("Oskärpa").tag(EditProject.Transition.Kind.blur)
                Text("Blixt").tag(EditProject.Transition.Kind.flash)
                Text("Övertoning").tag(EditProject.Transition.Kind.crossfade)
            }
            if model.project.transition.kind != .none {
                LabeledSlider("Längd", value: binding(\.transition.duration), range: 0.2...1.5, format: "%.1f s")
            }
            Toggle("Tona in och ut i början och slutet", isOn: binding(\.fadeInOut))
            if model.project.segments.count < 2 && model.project.transition.kind != .none {
                Text("Övergångarna syns där du klippt; filmen har inga snitt än.").font(.caption).foregroundStyle(.secondary)
            }
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
                Button("Ny lupp") { model.addLensAtPlayhead() }
                    .help("Ett förstoringsglas som följer markören i 3 s från spelhuvudet.")
            }
            .controlSize(.small)
            Toggle("Rörelseoskärpa", isOn: binding(\.motionBlur))
                .help("Oskärpa längs kamerans rörelse när den zoomar och panorerar, som med en riktig kamera.")
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
            Toggle("Markera markören", isOn: binding(\.cursor.highlight))
                .help("En mjuk färgad cirkel under markören, så att den syns även i en liten bild.")
            if model.project.cursor.highlight {
                Picker("Färg", selection: binding(\.cursor.highlightColor)) {
                    Text("Gul").tag("#FFD60A")
                    Text("Röd").tag("#FF453A")
                    Text("Blå").tag("#0A84FF")
                    Text("Grön").tag("#30D158")
                    Text("Vit").tag("#FFFFFF")
                }
            }
            Toggle("Klickljud", isOn: binding(\.cursor.clickSound))
                .help("Ett kort, mjukt klick vid varje musklick i filmen.")
            if model.project.cursor.clickSound {
                LabeledSlider("Klickljudets volym", value: binding(\.cursor.clickVolume), range: 0.05...1, format: "%.0f %%", scale: 100)
            }
            if !model.plan.cursorPath.hasData {
                Text("Ingen markördata i den här inspelningen.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Det som ritades med pennan under inspelningen (bara när det finns något).
    private var inkSection: some View {
        Section2("Pennan", systemImage: "pencil.tip") {
            Toggle("Visa det som ritades", isOn: binding(\.showsInk))
            if model.project.showsInk {
                LabeledSlider("Ligger kvar", value: binding(\.inkHold), range: 0.5...15, format: "%.1f s")
            }
            Text("\(model.plan.inkTrack.strokes.count) streck, ritade under inspelningen. De zoomar med bilden och tonas bort.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var shortcutSection: some View {
        Section2("Kortkommandon", systemImage: "command") {
            if model.recording.meta.keystrokesRecorded {
                Toggle("Visa kortkommandon", isOn: binding(\.shortcuts.visible))
                Picker("Placering", selection: binding(\.shortcuts.position)) {
                    Text("Nere").tag(EditProject.ShortcutStyle.Position.bottom)
                    Text("Uppe").tag(EditProject.ShortcutStyle.Position.top)
                }
                .pickerStyle(.segmented)
                LabeledSlider("Storlek", value: binding(\.shortcuts.size), range: 0.6...1.8, format: "%.0f %%", scale: 100)
            } else {
                Text("Inga kortkommandon i den här inspelningen. Slå på «Kortkommandon och skrivande» i menyn före nästa inspelning; det kräver Indataövervakning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @State private var deadMinimum = 2.0
    @AppStorage("maskKinds") private var maskKindsRaw = "email,phone,personalNumber,card,secret"

    private var maskKinds: Set<SensitiveText.Kind> {
        Set(maskKindsRaw.split(separator: ",").compactMap { SensitiveText.Kind(rawValue: String($0)) })
    }

    private func kindName(_ k: SensitiveText.Kind) -> LocalizedStringKey {
        switch k {
        case .email: "E-post"
        case .phone: "Telefonnummer"
        case .personalNumber: "Personnummer"
        case .card: "Kortnummer"
        case .secret: "Nycklar och lösenord"
        case .manual: "Eget område"
        }
    }

    private var maskSection: some View {
        Section2("Dölj känsligt", systemImage: "eye.slash") {
            ForEach(SensitiveText.Kind.allCases.filter { $0 != .manual }, id: \.self) { k in
                Toggle(kindName(k), isOn: Binding(get: { maskKinds.contains(k) }, set: { on in
                    var set = maskKinds
                    if on { set.insert(k) } else { set.remove(k) }
                    maskKindsRaw = SensitiveText.Kind.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
                }))
            }
            HStack {
                if let p = model.scanning {
                    ProgressView(value: p).frame(maxWidth: 120)
                    Button("Avbryt") { model.cancelScan() }
                } else {
                    Button("Sök i inspelningen") { model.scanForSensitiveText(kinds: maskKinds) }
                        .disabled(maskKinds.isEmpty)
                }
                Button("Eget område") { model.addMaskAtPlayhead() }
            }
            .controlSize(.small)
            if let note = model.scanNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            Text("Texten läses lokalt med Vision, oftare där bilden rör sig. Kontrollera resultatet innan du delar filmen.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.project.masks) { mask in
                maskRow(mask)
            }
        }
    }

    private func maskRow(_ mask: EditProject.Mask) -> some View {
        let selected = model.selectedMaskID == mask.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: Binding(get: { mask.enabled }, set: { v in model.updateMask(mask.id) { $0.enabled = v } }))
                    .labelsHidden()
                Text(kindName(mask.kind)).font(.callout)
                Text(mask.hint).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(AppLocale.format("%.1f–%.1f s", mask.start, mask.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectedMaskID = selected ? nil : mask.id
                if let t = model.timeMap.output(at: mask.start + 0.01) { model.scrub(to: t) }
            }
            if selected {
                Picker("Utseende", selection: Binding(get: { mask.style }, set: { v in model.updateMask(mask.id) { $0.style = v } })) {
                    Text("Oskärpa").tag(EditProject.Mask.Style.blur)
                    Text("Pixlar").tag(EditProject.Mask.Style.pixelate)
                    Text("Fylld").tag(EditProject.Mask.Style.solid)
                }
                .pickerStyle(.segmented)
                if mask.kind == .manual, let r = mask.keyframes.first?.rect {
                    LabeledSlider("Sidled", value: maskRect(mask.id, \.x, r), range: 0...1, format: "%.2f")
                    LabeledSlider("Höjdled", value: maskRect(mask.id, \.y, r), range: 0...1, format: "%.2f")
                    LabeledSlider("Bredd", value: maskRect(mask.id, \.width, r), range: 0.01...1, format: "%.2f")
                    LabeledSlider("Höjd", value: maskRect(mask.id, \.height, r), range: 0.01...1, format: "%.2f")
                }
                HStack {
                    Button("Börja här") { let s = model.sourceTimeAtPlayhead; model.updateMask(mask.id) { $0.start = min(s, $0.end - 0.1) } }
                    Button("Sluta här") { let s = model.sourceTimeAtPlayhead; model.updateMask(mask.id) { $0.end = max(s, $0.start + 0.1) } }
                    Spacer()
                    Button("Ta bort", role: .destructive) { model.deleteMask(mask.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.1) : .clear))
    }

    private func maskRect(_ id: UUID, _ key: WritableKeyPath<Rect, Double>, _ r: Rect) -> Binding<Double> {
        Binding(get: { r[keyPath: key] }, set: { v in
            model.updateMask(id) { m in
                for i in m.keyframes.indices { m.keyframes[i].rect[keyPath: key] = v }
            }
        })
    }

    private var speechSection: some View {
        Section2("Tal", systemImage: "captions.bubble") {
            if model.words.isEmpty {
                if let p = model.transcribing {
                    ProgressView(value: p) { Text("Transkriberar …") }
                } else {
                    Button("Transkribera") { model.transcribe() }
                    Text("Ger undertexter, redigering via texten och bortklippning av pauser. Görs lokalt med whisper.cpp.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Toggle("Undertexter i filmen", isOn: binding(\.captions.visible))
                LabeledSlider("Textstorlek", value: binding(\.captions.size), range: 0.6...1.6, format: "%.0f %%", scale: 100)
                    .disabled(!model.project.captions.visible)
                let languages = model.recording.bundle.translationLanguages
                if !languages.isEmpty {
                    Picker("Språk i bild", selection: binding(\.captions.language)) {
                        Text("Originalet").tag("")
                        ForEach(languages, id: \.self) { lang in
                            Text(verbatim: AppLocale.locale.localizedString(forLanguageCode: lang)?.capitalized ?? lang).tag(lang)
                        }
                    }
                    .disabled(!model.project.captions.visible)
                }
                if let p = model.translating {
                    HStack {
                        ProgressView(value: p) { Text("Översätter till engelska …") }
                        Button("Avbryt") { model.cancelTranslation() }.controlSize(.small)
                    }
                } else if model.recording.transcript?.language != "en", model.localTranslationModel != nil {
                    Button(languages.contains("en") ? "Översätt till engelska igen" : "Översätt till engelska") { model.translateLocally() }
                        .help("Görs på datorn med whisper och en flerspråkig modell. Andra språk: be producenten i Claude Code.")
                }
                if let e = model.translationError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
                let dubs = Dubbing.languages(model.project)
                if !dubs.isEmpty {
                    Picker("Röst", selection: binding(\.audio.voice)) {
                        Text("Originalet").tag("")
                        ForEach(dubs, id: \.self) { lang in
                            Text("\(AppLocale.locale.localizedString(forLanguageCode: lang)?.capitalized ?? lang) (dubbad)").tag(lang)
                        }
                    }
                    .help("Dubbad: mikrofonen tystas och den inlästa rösten hörs. Exporten får båda som ljudspår med språkkod.")
                }
                if languages.isEmpty && model.translating == nil {
                    Text(model.localTranslationModel != nil
                         ? "Andra språk än engelska: be producenten i Claude Code att översätta undertexterna."
                         : "Undertexter på fler språk: be producenten i Claude Code att översätta dem (till exempel «översätt undertexterna till engelska»).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Markera ordet som sägs", isOn: binding(\.captions.highlightWord))
                    .disabled(!model.project.captions.visible)
                    .help("Ordet som sägs just nu lyser gult, som i undertexter på sociala medier.")
                Group {
                    Picker("Placering", selection: binding(\.captions.position)) {
                        Text("Nere").tag(EditProject.CaptionStyle.Position.bottom)
                        Text("Mitt i").tag(EditProject.CaptionStyle.Position.middle)
                        Text("Uppe").tag(EditProject.CaptionStyle.Position.top)
                    }
                    .pickerStyle(.segmented)
                    Picker("Utseende", selection: binding(\.captions.look)) {
                        Text("Platta").tag(EditProject.CaptionStyle.Look.box)
                        Text("Kontur").tag(EditProject.CaptionStyle.Look.outline)
                    }
                    .pickerStyle(.segmented)
                    .help("Vit text på en mörk platta, eller fet text med svart kontur som i sociala medier.")
                }
                .disabled(!model.project.captions.visible)
                if model.recording.hasComputerAudio && model.recording.hasMicrophone {
                    Toggle("Sänk datorljudet när du pratar", isOn: binding(\.audio.duckSystem))
                }
                let fillers = model.fillerWords
                if !fillers.isEmpty {
                    Button("Klipp bort \(fillers.count) eh och öh") { model.removeFillerWords() }
                }
                Button("Transkribera om") { model.transcribe() }
                    .controlSize(.small)
                    .disabled(model.transcribing != nil)
            }
            if let e = model.transcriptionError, model.words.isEmpty == false || model.transcribing == nil {
                Text(e).font(.caption).foregroundStyle(.red)
            }

            Divider()
            // Dödtid: utan transkript räknas pauser i talet som dödtid, så det krävs om det finns mikrofon.
            let canFind = !model.recording.hasMicrophone || !model.words.isEmpty
            LabeledSlider("Dödtid längre än", value: $deadMinimum, range: 1...8, format: "%.1f s")
            let dead = canFind ? model.deadTime(minimum: deadMinimum) : []
            let total = dead.map { $0.upperBound - $0.lowerBound }.reduce(0, +)
            HStack {
                Button(dead.isEmpty ? String(localized: "Ingen dödtid") :
                        String(localized: "Klipp bort \(dead.count) pauser (\(AppLocale.format("%.1f", total)) s)")) {
                    model.removeDeadTime(minimum: deadMinimum)
                }
                .disabled(dead.isEmpty)
                if !dead.isEmpty {
                    Button("Snabba upp 4×") { model.speedUpDeadTime(minimum: deadMinimum) }
                        .help("Pauserna går i fyrdubbel fart i stället för att klippas bort — man ser vad som hände, men det går fort.")
                }
            }
            Text(canFind ? "Stunder då ingen talar och varken mus eller tangentbord används."
                         : "Transkribera först, så att pauser när du pratar inte räknas som dödtid.")
                .font(.caption).foregroundStyle(.secondary)
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
            Picker("Bakgrund", selection: binding(\.camera.backdrop)) {
                Text("Som den är").tag(EditProject.CameraStyle.Backdrop.original)
                Text("Suddig").tag(EditProject.CameraStyle.Backdrop.blur)
                Text("Borttagen").tag(EditProject.CameraStyle.Backdrop.remove)
            }
            .help("Bakgrunden bakom dig i bubblan, med Apples personsegmentering på datorn.")
            HStack {
                Toggle("Håll ansiktet i mitten", isOn: Binding(get: { model.project.camera.followFace },
                                                              set: { model.setFollowFace($0) }))
                    .disabled(model.analyzingFaces != nil)
                if let p = model.analyzingFaces {
                    ProgressView(value: p).frame(width: 60)
                }
            }
            .help("Utsnittet i bubblan följer ditt ansikte (Vision, på datorn), så att du inte hamnar i kanten. Räknas fram en gång.")
            if let note = model.faceNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var audioSection: some View {
        Section2("Ljud", systemImage: "waveform") {
            if model.recording.hasMicrophone {
                HStack {
                    Toggle("", isOn: Binding(get: { !model.project.audio.microphoneMuted },
                                             set: { v in model.update { $0.audio.microphoneMuted = !v } }))
                        .labelsHidden()
                    LabeledSlider("Mikrofon", value: decibels(\.audio.microphoneVolume), range: -30...20, format: "%+.1f dB")
                }
                HStack {
                    Toggle("Ta bort bakgrundsljud", isOn: Binding(get: { model.project.audio.voiceIsolation },
                                                                 set: { model.setVoiceIsolation($0) }))
                        .disabled(model.isolating != nil)
                    if let p = model.isolating { ProgressView(value: p).frame(maxWidth: 80) }
                }
                .help("Apples röstisolering: brus, fläktar och tangentbord tas bort, rösten blir kvar.")
                HStack {
                    Button("Jämna ut till \(Int(Loudness.target)) LUFS") { model.normalizeMicrophone() }
                        .controlSize(.small)
                        .disabled(model.measuringLoudness)
                    if model.measuringLoudness { ProgressView().controlSize(.small) }
                }
                if let note = model.loudnessNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.recording.hasSystemAudio {
                HStack {
                    Toggle("", isOn: Binding(get: { !model.project.audio.systemMuted },
                                             set: { v in model.update { $0.audio.systemMuted = !v } }))
                        .labelsHidden()
                    LabeledSlider(model.recording.apps.isEmpty ? "Datorljud" : "Övrigt datorljud",
                                  value: decibels(\.audio.systemVolume), range: -30...20, format: "%+.1f dB")
                }
            }
            // Apparna med eget spår: volym och tystning var för sig.
            ForEach(model.recording.apps, id: \.id) { app in
                HStack {
                    Toggle("", isOn: Binding(get: { !model.project.audio.isAppMuted(app.id) }, set: { on in
                        model.update { p in
                            p.audio.appMuted.removeAll { $0 == app.id }
                            if !on { p.audio.appMuted.append(app.id) }
                        }
                    }))
                    .labelsHidden()
                    LabeledSlider(LocalizedStringKey(app.name), value: appDecibels(app.id), range: -30...20, format: "%+.1f dB")
                }
            }
        }
    }

    /// En apps volym visad och ändrad i dB.
    private func appDecibels(_ id: String) -> Binding<Double> {
        Binding(get: { 20 * log10(max(model.project.audio.appVolume(id), 0.0316)) },
                set: { db in model.update { $0.audio.appVolumes[id] = pow(10, db / 20) } })
    }

    /// Standardutseendet: det här projektets stil för nya inspelningar, eller standarden hit.
    /// Logotypen i hörnet (följer med i standardutseendet).
    private var watermarkSection: some View {
        Section2("Logotyp", systemImage: "seal") {
            HStack {
                if let image = NSImage(contentsOfFile: model.project.watermark.file) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 80, maxHeight: 32)
                }
                Button(model.project.watermark.file.isEmpty ? "Välj bild …" : "Byt bild …") { chooseWatermark() }
                    .controlSize(.small)
                Spacer()
            }
            if !model.project.watermark.file.isEmpty {
                Toggle("Visa logotypen", isOn: binding(\.watermark.visible))
                Picker("Hörn", selection: binding(\.watermark.corner)) {
                    Text("Uppe till höger").tag(EditProject.CameraStyle.Corner.topRight)
                    Text("Uppe till vänster").tag(EditProject.CameraStyle.Corner.topLeft)
                    Text("Nere till höger").tag(EditProject.CameraStyle.Corner.bottomRight)
                    Text("Nere till vänster").tag(EditProject.CameraStyle.Corner.bottomLeft)
                }
                LabeledSlider("Storlek", value: binding(\.watermark.size), range: 0.03...0.2, format: "%.0f %%", scale: 100)
                LabeledSlider("Synlighet", value: binding(\.watermark.opacity), range: 0.2...1, format: "%.0f %%", scale: 100)
            }
        }
    }

    /// Bilden kopieras till appens stödmapp, så att den finns kvar för standardutseendet.
    private func chooseWatermark() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.message = String(localized: "En PNG med genomskinlig bakgrund blir finast.")
        guard panel.runModal() == .OK, let url = panel.url, let stored = Watermarks.store(url) else { return }
        model.update { $0.watermark.file = stored.path; $0.watermark.visible = true }
    }

    private var standardStyleSection: some View {
        Section2("Standardutseende", systemImage: "star") {
            let standard = EditProject.standardStyle
            let same = standard.map { model.project.hasSameStyle(as: $0) } ?? false
            Text(standard == nil ? "Nya inspelningar får appens eget utseende."
                                 : (same ? "Det här projektet har standardutseendet." : "Nya inspelningar får det sparade utseendet."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Spara som standard") { StandardStyle.save(model.project); styleRevision += 1 }
                    .disabled(same)
                    .help("Bakgrund, ram, format, markör, kamera, kortkommandon, undertexter, övergångar och zoomnivå blir standard för nya inspelningar.")
                Button("Använd här") { if let s = EditProject.standardStyle { model.update { $0.adoptStyle(of: s) } } }
                    .disabled(standard == nil || same)
            }
            .controlSize(.small)
            if standard != nil {
                Button("Glöm standardutseendet") { StandardStyle.forget(); styleRevision += 1 }
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
        }
        .id(styleRevision)
    }

    /// En linjär volym visad och ändrad i dB.
    private func decibels(_ keyPath: WritableKeyPath<EditProject, Double>) -> Binding<Double> {
        Binding(get: { 20 * log10(max(model.project[keyPath: keyPath], 0.0316)) },
                set: { db in model.update { $0[keyPath: keyPath] = pow(10, db / 20) } })
    }

    private func hexBinding(_ keyPath: WritableKeyPath<EditProject, String>) -> Binding<Color> {
        Binding(get: { Color(hex: model.project[keyPath: keyPath]) },
                set: { c in model.update { $0[keyPath: keyPath] = c.hexString } })
    }
}

// MARK: - Byggstenar

struct Section2<Content: View>: View {
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

struct LabeledSlider: View {
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
                Text(AppLocale.format(format, value * scale)).monospacedDigit().foregroundStyle(.secondary)
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
