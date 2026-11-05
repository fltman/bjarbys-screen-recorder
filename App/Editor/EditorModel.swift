import Foundation
import AVFoundation
import SwiftUI
import RecorderKit

/// Redigerarens tillstånd: projektet, förhandsvisningen och underlaget för tidslinjen.
///
/// Varje ändring av projektet ger en ny renderplan. Ändras bara utseendet byts
/// videokompositionen på den spelare som redan finns; ändras klippen byggs kompositionen om.
@MainActor
final class EditorModel: ObservableObject {
    private(set) var recording: LoadedRecording
    let player = AVPlayer()
    static let previewShortSide = 1080
    static let previewFPS = 60

    @Published private(set) var project: EditProject
    @Published var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var selectedZoomID: UUID? { didSet { if selectedZoomID != nil { wordSelection = nil } } }
    @Published var selectedSegmentID: UUID? { didSet { if selectedSegmentID != nil { wordSelection = nil } } }
    @Published private(set) var plan: RenderPlan
    @Published private(set) var thumbnails: [(t: Double, image: CGImage)] = []
    @Published private(set) var micWave: [Float] = []
    @Published private(set) var systemWave: [Float] = []
    @Published var exportPresented = false
    @Published private(set) var loadError: String?
    /// Transkriberingens förlopp 0–1 medan den pågår.
    @Published private(set) var transcribing: Double?
    @Published private(set) var transcriptionError: String?
    /// Markerade ord i texten (index i transkriptet).
    @Published var wordSelection: ClosedRange<Int>?
    @Published var transcriptShown = true
    private var transcriptionTask: Task<Void, Never>?

    private var built: CompositionBuilder.Result?
    private var builtSegments: [EditProject.ClipSegment] = []
    private var builtIsolation = false
    private var builtClips: [String] = []
    private var rebuildTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var undoStack: [EditProject] = []
    private var redoStack: [EditProject] = []
    private var lastUndoPush = Date.distantPast

    var duration: Double { plan.outputDuration }
    var timeMap: TimeMap { plan.timeMap }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(recording: LoadedRecording) {
        self.recording = recording
        let hadProject = FileManager.default.fileExists(atPath: recording.bundle.projectURL.path)
        var project = recording.bundle.loadProject(duration: recording.meta.duration)
        if !hadProject && project.autoZoom {
            project.zooms = AutoZoom.generate(events: recording.events, mapping: recording.mapping,
                                              duration: recording.meta.duration, scale: project.zoomScale)
        }
        self.project = project
        plan = recording.makePlan(project: project, canvas: Self.canvas(for: project, recording: recording))
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) {
            [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds
                self.isPlaying = self.player.rate != 0
            }
        }
        Task { await rebuild(full: true) }
        Task { await loadPreviews() }
    }

    static func canvas(for project: EditProject, recording: LoadedRecording) -> CGSize {
        RenderPlan.canvasSize(aspect: project.aspect, source: recording.sourceSize, shortSide: previewShortSide)
    }

    // MARK: - Ändringar

    /// Ändrar projektet. Ändringar tätare än 0,6 s slås ihop till ett ångra-steg, så att ett
    /// reglage som dras blir ett steg och inte hundra.
    func update(_ change: (inout EditProject) -> Void) {
        var next = project
        change(&next)
        guard next != project else { return }
        if Date().timeIntervalSince(lastUndoPush) > 0.6 {
            undoStack.append(project)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastUndoPush = Date()
        project = next
        projectChanged()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        lastUndoPush = .distantPast
        projectChanged()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        lastUndoPush = .distantPast
        projectChanged()
    }

    private func projectChanged() {
        rebuildTask?.cancel()
        let full = project.segments != builtSegments || project.audio.voiceIsolation != builtIsolation
            || project.audioClips.map { "\($0.id)\($0.at)\($0.file)" } != builtClips
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(full ? 120 : 30))
            guard !Task.isCancelled else { return }
            await rebuild(full: full)
        }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? recording.bundle.saveProject(project)
        }
    }

    /// Sparar direkt (när fönstret stängs).
    func saveNow() {
        saveTask?.cancel()
        try? recording.bundle.saveProject(project)
    }

    // MARK: - Förhandsvisning

    private func rebuild(full: Bool) async {
        let project = self.project
        let canvas = Self.canvas(for: project, recording: recording)
        let newPlan = recording.makePlan(project: project, canvas: canvas)
        if full || built == nil {
            let sourceTime = plan.timeMap.source(at: currentTime)
            do {
                let result = try await CompositionBuilder.build(recording, plan: newPlan, fps: Self.previewFPS)
                built = result
                builtSegments = project.segments
                builtIsolation = project.audio.voiceIsolation
                builtClips = project.audioClips.map { "\($0.id)\($0.at)\($0.file)" }
                plan = newPlan
                let item = AVPlayerItem(asset: result.composition)
                item.videoComposition = result.videoComposition
                item.audioMix = result.audioMix
                item.audioTimePitchAlgorithm = .spectral
                let wasPlaying = isPlaying
                player.replaceCurrentItem(with: item)
                let t = newPlan.timeMap.output(at: sourceTime) ?? min(currentTime, newPlan.outputDuration)
                await seek(to: t)
                if wasPlaying { player.play() }
            } catch {
                loadError = error.localizedDescription
            }
        } else if let built, let item = player.currentItem {
            plan = newPlan
            item.videoComposition = CompositionBuilder.videoComposition(
                plan: newPlan, duration: built.duration, fps: Self.previewFPS, hasCamera: recording.hasCamera)
            item.audioMix = CompositionBuilder.audioMix(for: built.composition, plan: newPlan)
            if !isPlaying { await seek(to: currentTime) }
        }
    }

    private func loadPreviews() async {
        let d = recording.meta.duration
        if let screen = recording.asset(.screen) {
            let count = max(8, min(60, Int(d / 2)))
            thumbnails = await MediaPreviews.thumbnails(screen, duration: d, count: count, height: 90)
        }
        if let mic = recording.asset(.microphone) {
            micWave = await MediaPreviews.waveform(mic, duration: d, buckets: 1600)
        }
        if let sys = recording.asset(.system) {
            systemWave = await MediaPreviews.waveform(sys, duration: d, buckets: 1600)
        }
    }

    // MARK: - Uppspelning

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { Task { await seek(to: 0); player.play() } } else { player.play() }
        }
    }

    func seek(to t: Double) async {
        let clamped = max(0, min(t, duration))
        currentTime = clamped
        await player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func scrub(to t: Double) {
        let clamped = max(0, min(t, duration))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Klipp

    var sourceTimeAtPlayhead: Double { plan.timeMap.source(at: currentTime) }

    /// Delar delen under spelhuvudet i två.
    func split() {
        let s = sourceTimeAtPlayhead
        update { p in
            guard let i = p.segments.firstIndex(where: { s > $0.start + 0.05 && s < $0.end - 0.05 }) else { return }
            let seg = p.segments[i]
            p.segments[i].end = s
            p.segments.insert(.init(start: s, end: seg.end, speed: seg.speed), at: i + 1)
        }
    }

    func segment(atOutput t: Double) -> EditProject.ClipSegment? {
        for (seg, piece) in zip(project.segments.filter { $0.duration > 0.001 }, plan.timeMap.pieces)
        where t >= piece.outputStart && t < piece.outputEnd {
            return seg
        }
        return nil
    }

    func deleteSegment(_ id: UUID) {
        update { p in
            guard p.segments.count > 1 else { return }
            p.segments.removeAll { $0.id == id }
        }
        selectedSegmentID = nil
    }

    func setSpeed(_ speed: Double, for id: UUID) {
        update { p in
            if let i = p.segments.firstIndex(where: { $0.id == id }) { p.segments[i].speed = speed }
        }
    }

    // MARK: - Zoom

    func regenerateAutoZooms() {
        update { p in
            let manual = p.zooms.filter { !$0.isAuto }
            let generated = p.autoZoom
                ? AutoZoom.generate(events: recording.events, mapping: recording.mapping,
                                    duration: recording.meta.duration, scale: p.zoomScale)
                    .filter { g in !manual.contains { $0.start < g.end && g.start < $0.end } }
                : []
            p.zooms = (manual + generated).sorted { $0.start < $1.start }
        }
    }

    func addZoomAtPlayhead() {
        let s = sourceTimeAtPlayhead
        let c = plan.cursorPath.hasData ? plan.cursorPath.position(at: s) : CGPoint(x: 0.5, y: 0.5)
        let zoom = EditProject.ZoomSegment(start: s, end: min(s + 3, recording.meta.duration),
                                           scale: project.zoomScale, centerX: c.x, centerY: c.y)
        update { $0.zooms.append(zoom); $0.zooms.sort { $0.start < $1.start } }
        selectedZoomID = zoom.id
    }

    func updateZoom(_ id: UUID, _ change: (inout EditProject.ZoomSegment) -> Void) {
        update { p in
            guard let i = p.zooms.firstIndex(where: { $0.id == id }) else { return }
            change(&p.zooms[i])
            // En ändrad zoom är användarens: den överlever när de automatiska skapas om.
            p.zooms[i].isAuto = false
            let z = p.zooms[i]
            p.zooms[i].start = max(0, min(z.start, z.end - 0.3))
            p.zooms[i].end = min(recording.meta.duration, max(z.end, p.zooms[i].start + 0.3))
        }
    }

    func deleteZoom(_ id: UUID) {
        update { $0.zooms.removeAll { $0.id == id } }
        if selectedZoomID == id { selectedZoomID = nil }
    }

    func deleteSelection() {
        if let z = selectedZoomID { deleteZoom(z) }
        else if let w = wordSelection { cutWords(w) }
        else if let s = selectedSegmentID { deleteSegment(s) }
    }

    // MARK: - Tal

    var words: [Transcript.Word] { recording.transcript?.words ?? [] }

    func transcribe() {
        guard transcribing == nil else { return }
        transcriptionError = nil
        guard let setup = AppModel.shared.settings.whisperSetup else {
            transcriptionError = String(localized: "Hittar inte whisper.cpp. Välj mappen med build/bin/whisper-cli och models/.")
            return
        }
        transcribing = 0
        let rec = recording
        transcriptionTask = Task {
            do {
                let transcript = try await Transcriber.run(rec, setup: setup) { p in
                    Task { @MainActor [weak self] in if self?.transcribing != nil { self?.transcribing = p } }
                }
                try rec.bundle.saveTranscript(transcript)
                recording.transcript = transcript
                wordSelection = nil
                transcribing = nil
                await rebuild(full: false)
            } catch {
                transcribing = nil
                if !Task.isCancelled { transcriptionError = error.localizedDescription }
            }
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcribing = nil
    }

    /// Källintervallet orden täcker, utvidgat till mitten av pauserna mot grannarna, så att
    /// ett klipp inte kapar början eller slutet på orden intill (ordtiderna är ±0,1 s).
    func sourceRange(ofWords r: ClosedRange<Int>) -> ClosedRange<Double>? {
        let w = words
        guard r.lowerBound >= 0, r.upperBound < w.count else { return nil }
        let first = w[r.lowerBound], last = w[r.upperBound]
        let a = r.lowerBound > 0 ? (w[r.lowerBound - 1].end + first.start) / 2 : max(0, first.start - 0.15)
        let b = r.upperBound + 1 < w.count ? (last.end + w[r.upperBound + 1].start) / 2
                                           : min(recording.meta.duration, last.end + 0.15)
        return min(a, first.start)...max(b, last.end)
    }

    func cutWords(_ r: ClosedRange<Int>) {
        guard let range = sourceRange(ofWords: r) else { return }
        update { $0.cut(range) }
        wordSelection = nil
    }

    func restoreWords(_ r: ClosedRange<Int>) {
        guard let range = sourceRange(ofWords: r) else { return }
        update { $0.restore(range) }
    }

    func isWordKept(_ i: Int) -> Bool {
        let w = words[i]
        return project.isKept((w.start + w.end) / 2)
    }

    /// Ordet som sägs vid spelhuvudet.
    var wordAtPlayhead: Int? {
        let s = sourceTimeAtPlayhead
        let w = words
        var lo = 0, hi = w.count
        while lo < hi { let m = (lo + hi) / 2; if w[m].start <= s { lo = m + 1 } else { hi = m } }
        guard lo > 0, s <= w[lo - 1].end + 0.15 else { return nil }
        return lo - 1
    }

    func seek(toWord i: Int) {
        guard i < words.count, let t = timeMap.output(at: (words[i].start + words[i].end) / 2) else { return }
        scrub(to: max(0, t - (words[i].end - words[i].start) / 2))
    }

    /// Dödtiden som skulle tas bort: inget tal, ingen mus, inga tangenter.
    func deadTime(minimum: Double) -> [ClosedRange<Double>] {
        // Inspektören ritas om i takt med spelhuvudet; sökningen går igenom alla mushändelser.
        let key = "\(minimum)|\(words.count)"
        let found: [ClosedRange<Double>]
        if let cached = deadTimeCache, cached.key == key {
            found = cached.ranges
        } else {
            found = DeadTime.find(events: recording.events, speech: recording.transcript?.speech() ?? [],
                                  duration: recording.meta.duration, minimum: minimum)
            deadTimeCache = (key, found)
        }
        return found.filter { r in project.isKept((r.lowerBound + r.upperBound) / 2) }
    }
    private var deadTimeCache: (key: String, ranges: [ClosedRange<Double>])?

    func removeDeadTime(minimum: Double) {
        let ranges = deadTime(minimum: minimum)
        guard !ranges.isEmpty else { return }
        update { p in for r in ranges { p.cut(r) } }
    }

    // MARK: - Lager, kapitel och ljudklipp

    @Published var selectedOverlayID: UUID? {
        didSet { if selectedOverlayID != nil { selectedZoomID = nil; selectedSegmentID = nil; wordSelection = nil } }
    }

    /// Producentens brev (leverans.md), om det finns.
    var deliveryNote: String? { try? String(contentsOf: recording.bundle.deliveryNoteURL, encoding: .utf8) }

    func addOverlay(_ kind: Overlay.Kind) {
        let s = sourceTimeAtPlayhead
        var o = Overlay(kind: kind, at: s, duration: kind == .title ? 2.5 : 4)
        switch kind {
        case .title: o.title = String(localized: "Rubrik")
        case .fact: o.title = String(localized: "Faktaruta"); o.lines = [String(localized: "En rad text")]
        case .qr: o.title = String(localized: "Läs mer"); o.url = "https://"; o.corner = .bottomRight
        case .callout:
            if let hit = Producer.clickTarget(recording, near: s) {
                o.target = Rect(hit.rect)
                o.title = hit.label.flatMap { $0.split(separator: "«").last.map { String($0).replacingOccurrences(of: "»", with: "") } } ?? ""
            } else {
                let c = plan.cursorPath.hasData ? plan.cursorPath.position(at: s) : CGPoint(x: 0.5, y: 0.5)
                o.target = Rect(x: max(0, c.x - 0.05), y: max(0, c.y - 0.025), width: 0.1, height: 0.05)
            }
        }
        update { $0.overlays.append(o); $0.overlays.sort { $0.at < $1.at } }
        selectedOverlayID = o.id
    }

    func updateOverlay(_ id: UUID, _ change: (inout Overlay) -> Void) {
        update { p in if let i = p.overlays.firstIndex(where: { $0.id == id }) { change(&p.overlays[i]) } }
    }

    func deleteOverlay(_ id: UUID) {
        update { $0.overlays.removeAll { $0.id == id } }
        if selectedOverlayID == id { selectedOverlayID = nil }
    }

    func addChapter() {
        let c = Chapter(at: sourceTimeAtPlayhead, title: String(localized: "Nytt kapitel"))
        update { $0.chapters.append(c); $0.chapters.sort { $0.at < $1.at } }
    }

    func updateChapter(_ id: UUID, _ change: (inout Chapter) -> Void) {
        update { p in
            if let i = p.chapters.firstIndex(where: { $0.id == id }) { change(&p.chapters[i]) }
            p.chapters.sort { $0.at < $1.at }
        }
    }

    func deleteChapter(_ id: UUID) { update { $0.chapters.removeAll { $0.id == id } } }

    /// Kopierar en ljudfil in i paketet och lägger den vid spelhuvudet.
    func addAudio(from url: URL, role: AudioClip.Role) {
        let at = sourceTimeAtPlayhead
        let bundle = recording.bundle
        Task {
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first,
                  let range = try? await track.load(.timeRange) else { return }
            let name = "\(role.rawValue)-\(UUID().uuidString.prefix(6)).\(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)"
            do {
                try FileManager.default.createDirectory(at: bundle.mediaDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: bundle.mediaDir.appendingPathComponent(name))
            } catch { return }
            let clip = AudioClip(role: role, at: role == .music ? 0 : at, file: name, duration: range.duration.seconds,
                                 volume: role == .music ? 0.35 : 1, fadeIn: role == .music ? 1.5 : 0, fadeOut: role == .music ? 2.5 : 0)
            update { $0.audioClips.append(clip); $0.audioClips.sort { $0.at < $1.at } }
        }
    }

    func updateAudio(_ id: UUID, _ change: (inout AudioClip) -> Void) {
        update { p in if let i = p.audioClips.firstIndex(where: { $0.id == id }) { change(&p.audioClips[i]) } }
    }

    func deleteAudio(_ id: UUID) { update { $0.audioClips.removeAll { $0.id == id } } }

    // MARK: - Masker

    @Published private(set) var scanning: Double?
    @Published private(set) var scanNote: String?
    @Published var selectedMaskID: UUID?
    private var scanTask: Task<Void, Never>?

    /// Läser all text i inspelningen och lägger masker över det känsliga. Tidigare automatiska
    /// masker ersätts; egna och ändrade behålls.
    func scanForSensitiveText(kinds: Set<SensitiveText.Kind>) {
        guard scanning == nil else { return }
        scanning = 0
        scanNote = nil
        let rec = recording
        scanTask = Task {
            do {
                let found = try await MaskScanner.scan(rec, kinds: kinds) { p in
                    Task { @MainActor [weak self] in if self?.scanning != nil { self?.scanning = p } }
                }
                update { p in p.masks = p.masks.filter { $0.kind == .manual } + found }
                scanNote = found.isEmpty ? String(localized: "Inget känsligt hittades.")
                                         : String(localized: "\(found.count) områden döljs.")
            } catch {
                if !Task.isCancelled { scanNote = error.localizedDescription }
            }
            scanning = nil
        }
    }

    func cancelScan() { scanTask?.cancel(); scanTask = nil; scanning = nil }

    func addMaskAtPlayhead() {
        let s = sourceTimeAtPlayhead
        let c = plan.cursorPath.hasData ? plan.cursorPath.position(at: s) : CGPoint(x: 0.5, y: 0.5)
        let rect = Rect(x: min(max(0, c.x - 0.1), 0.8), y: min(max(0, c.y - 0.03), 0.94), width: 0.2, height: 0.06)
        let mask = EditProject.Mask(start: s, end: min(s + 3, recording.meta.duration),
                                    keyframes: [.init(t: s, rect: rect)], style: .blur, kind: .manual,
                                    hint: String(localized: "Eget område"))
        update { $0.masks.append(mask) }
        selectedMaskID = mask.id
    }

    func updateMask(_ id: UUID, _ change: (inout EditProject.Mask) -> Void) {
        update { p in
            guard let i = p.masks.firstIndex(where: { $0.id == id }) else { return }
            change(&p.masks[i])
        }
    }

    func deleteMask(_ id: UUID) {
        update { $0.masks.removeAll { $0.id == id } }
        if selectedMaskID == id { selectedMaskID = nil }
    }

    @Published private(set) var isolating: Double?

    /// Slår på eller av röstisoleringen. Första gången körs den på mikrofonspåret (några
    /// sekunder för en lång inspelning) och sparas i paketet.
    func setVoiceIsolation(_ on: Bool) {
        guard on else { update { $0.audio.voiceIsolation = false }; return }
        if recording.isolatedMicrophone != nil { update { $0.audio.voiceIsolation = true }; return }
        guard let mic = recording.asset(.microphone), isolating == nil else { return }
        isolating = 0
        let url = recording.bundle.isolatedMicrophoneURL
        Task {
            do {
                _ = try await VoiceIsolation.process(mic, to: url) { p in
                    Task { @MainActor [weak self] in if self?.isolating != nil { self?.isolating = p } }
                }
                recording.isolatedMicrophone = AVURLAsset(url: url)
                update { $0.audio.voiceIsolation = true }
            } catch {
                loudnessNote = error.localizedDescription
            }
            isolating = nil
        }
    }

    @Published private(set) var measuringLoudness = false
    @Published private(set) var loudnessNote: String?

    /// Mäter mikrofonen (EBU R128) och sätter volymen så att filmen hamnar på −16 LUFS,
    /// utan att topparna går över −1 dBFS. Volymen går att ändra efteråt som vanligt.
    func normalizeMicrophone() {
        let isolated = project.audio.voiceIsolation ? recording.isolatedMicrophone : nil
        guard let mic = isolated ?? recording.asset(.microphone), !measuringLoudness else { return }
        measuringLoudness = true
        Task {
            defer { measuringLoudness = false }
            guard let m = try? await Loudness.measure(mic) else {
                loudnessNote = String(localized: "Mikrofonspåret är tyst.")
                return
            }
            let (gain, limited) = Loudness.gain(for: m)
            update { $0.audio.microphoneVolume = gain; $0.audio.microphoneMuted = false }
            let db = AppLocale.format("%+.1f", 20 * log10(gain))
            let measured = AppLocale.format("%.1f", m.integrated)
            loudnessNote = limited
                ? String(localized: "Mikrofonen låg på \(measured) LUFS. Höjd \(db) dB, mindre än målet så att topparna inte klipps.")
                : String(localized: "Mikrofonen låg på \(measured) LUFS. Ändrad \(db) dB.")
        }
    }

    var fillerWords: [Int] {
        words.indices.filter { FillerWords.isFiller(words[$0].text) && isWordKept($0) }
    }

    func removeFillerWords() {
        let ranges = fillerWords.compactMap { sourceRange(ofWords: $0...$0) }
        guard !ranges.isEmpty else { return }
        update { p in for r in ranges { p.cut(r) } }
    }

    var selectedZoom: EditProject.ZoomSegment? {
        selectedZoomID.flatMap { id in project.zooms.first { $0.id == id } }
    }

    var selectedSegment: EditProject.ClipSegment? {
        selectedSegmentID.flatMap { id in project.segments.first { $0.id == id } }
    }
}
