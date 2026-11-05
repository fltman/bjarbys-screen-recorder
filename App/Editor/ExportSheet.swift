import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RecorderKit

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var presetID = ExportPreset.all[0].id
    @State private var progress: Double?
    @State private var exporter: Exporter?
    @State private var finishedURL: URL?
    @State private var error: String?
    @AppStorage("exportSubtitles") private var subtitles = true
    @State private var uploading: Double?
    @State private var fullFrameRate = true
    @State private var sharedURL: URL?
    /// Kapitlen som YouTube-text för det som exporterades (nil utan kapitel).
    @State private var finishedChapters: String?
    /// Fler förval i samma svep (⌘-klick), utöver `presetID`.
    @State private var extraIDs: Set<String> = []
    /// Alla filer som blev klara (flera vid ett svep).
    @State private var finishedAll: [URL] = []
    /// Vilket förval som exporteras just nu, vid flera ("MP4 1080p, 2 av 3").
    @State private var batchLabel: String?

    init(model: EditorModel, extra: Set<String> = []) {
        self.model = model
        _extraIDs = State(initialValue: extra)
    }

    /// Förvalen som exporteras, i listans ordning.
    private var selectedPresets: [ExportPreset] {
        ExportPreset.all.filter { $0.id == presetID || extraIDs.contains($0.id) }
    }

    /// Klick väljer ett förval; ⌘-klick lägger till eller tar bort fler i samma svep.
    private func choose(_ p: ExportPreset) {
        guard progress == nil else { return }
        if NSEvent.modifierFlags.contains(.command) {
            if p.id == presetID {
                if let next = extraIDs.first { presetID = next; extraIDs.remove(next) }
            } else if extraIDs.contains(p.id) {
                extraIDs.remove(p.id)
            } else {
                extraIDs.insert(p.id)
            }
        } else {
            presetID = p.id
            extraIDs = []
        }
    }
    /// Bara det markerade utsnittet (I–O), när det finns ett.
    @State private var onlyMarked = true
    /// Hela ljudets ljudstyrka i filmen: 0 = som det är, annars målet i LUFS.
    @AppStorage("exportLoudness") private var loudness = 0.0
    /// Kvaliteten för MP4 (bitraten): liten fil, normal eller hög.
    @AppStorage("exportQuality") private var qualityRaw = Exporter.Quality.normal.rawValue
    private var quality: Exporter.Quality { Exporter.Quality(rawValue: qualityRaw) ?? .normal }

    /// Längden som exporteras: utsnittet om det är valt, annars hela filmen.
    private var exportedDuration: Double {
        if onlyMarked, let r = model.markedRange { return r.upperBound - r.lowerBound }
        return model.duration
    }

    private var preset: ExportPreset { ExportPreset.all.first { $0.id == presetID } ?? ExportPreset.all[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exportera").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(ExportPreset.available(hdr: model.recording.isHDR).filter { !$0.isAudioOnly }) { p in
                    let canvas = p.canvas(aspect: model.project.aspect, source: model.recording.sourceSize)
                    let selected = p.id == presetID || extraIDs.contains(p.id)
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: Self.icon(p))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.headline)
                            Text(p.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(verbatim: "\(Int(canvas.width))×\(Int(canvas.height))")
                            Text("≈ " + ByteCountFormatter.string(fromByteCount: p.estimatedBytes(canvas: canvas, duration: exportedDuration, quality: quality),
                                                                 countStyle: .file))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
                    .contentShape(Rectangle())
                    // Dubbelklick först, annars hinner enkelklicket ta det.
                    .onTapGesture(count: 2) { if progress == nil { presetID = p.id; extraIDs = []; chooseAndExport() } }
                    .onTapGesture { choose(p) }
                }
            }

            // Bara ljudet: tre små kort på en rad.
            VStack(alignment: .leading, spacing: 6) {
                Text("Bara ljudet").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(ExportPreset.all.filter(\.isAudioOnly)) { p in
                        let selected = p.id == presetID || extraIDs.contains(p.id)
                        HStack(spacing: 8) {
                            Image(systemName: Self.icon(p))
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                                let size = ByteCountFormatter.string(fromByteCount: p.estimatedBytes(canvas: .zero, duration: exportedDuration),
                                                                     countStyle: .file)
                                Text(p.codec == .audioStems ? "≈ \(size) per spår" : "≈ \(size)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(selected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
                        .contentShape(Rectangle())
                        .help(p.detail)
                        .onTapGesture(count: 2) { if progress == nil { presetID = p.id; extraIDs = []; chooseAndExport() } }
                        .onTapGesture { choose(p) }
                    }
                }
                if preset.isAudioOnly && extraIDs.isEmpty {
                    Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                }
                Text(selectedPresets.count > 1
                     ? "\(selectedPresets.count) format i samma svep: \(selectedPresets.map(\.name).joined(separator: ", "))"
                     : "⌘-klicka för att exportera flera format i samma svep.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.recording.meta.fps > 60 && presetID != "gif" && !preset.isAudioOnly {
                Toggle("\(model.recording.meta.fps) bilder/s, som inspelningen", isOn: $fullFrameRate)
                    .disabled(progress != nil)
            }
            if let r = model.markedRange {
                Toggle("Bara det markerade, \(TransportTime.format(r.lowerBound))–\(TransportTime.format(r.upperBound)) (\(AppLocale.format("%.1f", r.upperBound - r.lowerBound)) s)",
                       isOn: $onlyMarked)
                    .disabled(progress != nil)
            }
            if selectedPresets.contains(where: \.usesQuality) {
                Picker("Kvalitet", selection: $qualityRaw) {
                    Text("Liten fil").tag(Exporter.Quality.small.rawValue)
                    Text("Normal").tag(Exporter.Quality.normal.rawValue)
                    Text("Hög").tag(Exporter.Quality.high.rawValue)
                }
                .pickerStyle(.segmented)
                .disabled(progress != nil)
                .help("Bitraten för MP4: halva (för mejl och chatt) eller nästan dubbla (snabb rörelse, mycket text).")
            }
            if presetID != "gif" {
                Picker("Ljudnivå", selection: $loudness) {
                    Text("Som den är").tag(0.0)
                    Text("−14 LUFS (YouTube, sociala medier)").tag(-14.0)
                    Text("−16 LUFS (podd, Apple)").tag(-16.0)
                }
                .disabled(progress != nil)
                .help("Hela filmens ljud mäts (BS.1770) och jämnas ut till nivån, utan att topparna går över −1 dBFS.")
            }
            if model.plan.captions != nil && presetID != "gif" {
                Toggle("Spara undertexter (.srt) bredvid filmen", isOn: $subtitles)
                    .disabled(progress != nil)
            }

            if let progress {
                ProgressView(value: progress) {
                    Text(finishedURL != nil ? "Klart" : batchLabel.map { "Exporterar \($0) …" } ?? "Exporterar …")
                } currentValueLabel: {
                    Text("\(Int(progress * 100)) %").monospacedDigit()
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            HStack {
                if progress == nil && finishedURL == nil {
                    Menu {
                        Button("Spara bild vid spelhuvudet …") { saveStill() }
                        Divider()
                        Button("Steg-för-steg-guide …") { makeGuide() }
                        Button("Felrapport …") { makeBugReport() }
                    } label: {
                        Label("Mer", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Steg-för-steg-guide (en bild per klick, med det du sa) eller felrapport (film, steg, miljö och systemlogg).")
                }
                if let finishedURL {
                    if let sharedURL {
                        Text(sharedURL.absoluteString).font(.caption).textSelection(.enabled).lineLimit(1)
                    } else if let uploading {
                        ProgressView(value: uploading).frame(width: 120)
                    } else if SharingStore.isReady && !preset.fileExtension.isEmpty && finishedAll.count <= 1 {
                        Button("Ladda upp och kopiera länk") { upload(finishedURL) }
                    }
                    if sharedURL == nil && uploading == nil && finishedAll.count <= 1 && !preset.fileExtension.isEmpty {
                        if CloudStore.isConnected(.youtube) && !preset.isAudioOnly && preset.codec != .gif {
                            Button("YouTube") { uploadCloud(.youtube, finishedURL) }
                                .help("Laddar upp som privat film (ändra synligheten i YouTube Studio) och kopierar länken.")
                        }
                        if CloudStore.isConnected(.dropbox) {
                            Button("Dropbox") { uploadCloud(.dropbox, finishedURL) }
                                .help("Laddar upp till \(CloudStore.dropboxFolder) och kopierar en delningslänk.")
                        }
                    }
                    ShareLink(items: finishedAll.isEmpty ? [finishedURL] : finishedAll) { Label("Dela …", systemImage: "square.and.arrow.up") }
                        .help("AirDrop, Mail, Meddelanden … (systemets Dela-meny)")
                    if let chapters = finishedChapters {
                        Button("Kopiera kapitel") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(chapters, forType: .string)
                        }
                        .help("Tidsstämplarna för en YouTube-beskrivning (\"0:00 Start\" …). Kapitlen ligger också i filmen.")
                    }
                    Button("Visa i Finder") { NSWorkspace.shared.activateFileViewerSelecting(finishedAll.isEmpty ? [finishedURL] : finishedAll) }
                }
                Spacer()
                if progress != nil && finishedURL == nil {
                    Button("Avbryt export", role: .cancel) { exporter?.cancel() }
                } else {
                    Button(finishedURL == nil ? "Avbryt" : "Stäng", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if finishedURL == nil {
                        Button(selectedPresets.count > 1 ? "Exportera \(selectedPresets.count) …" : "Exportera …") { chooseAndExport() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    /// Den färdiga rutan vid spelhuvudet som PNG, 4K på kortaste sidan (miniatyr till YouTube m.m.).
    private func saveStill() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.recording.bundle.name) \(TransportTime.format(model.currentTime).replacingOccurrences(of: ":", with: "."))"
        panel.allowedContentTypes = [.png]
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rec = model.recording, project = model.project, t = model.currentTime
        error = nil
        Task {
            do {
                let (images, _) = try await FrameGrabber.frames(rec, project: project, outputTimes: [t], shortSide: 2160)
                if let image = images.first { try FrameGrabber.writePNG(image, to: url) }
                finishedURL = url
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func chooseAndExport() {
        let presets = selectedPresets
        if presets.count > 1 {
            // Flera format: en mapp, filerna heter som inspelningen med förvalets namn.
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Exportera hit")
            panel.message = String(localized: "Mappen där de \(presets.count) filerna hamnar.")
            panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            start(presets.map { p in (p, Self.freeURL(in: dir, base: "\(model.recording.bundle.name) – \(p.name)", ext: p.fileExtension)) })
            return
        }
        let panel = NSSavePanel()
        // Ljudspåren var för sig hamnar i en mapp.
        panel.nameFieldStringValue = switch preset.codec {
        case .audioStems: String(localized: "\(model.recording.bundle.name) – ljudspår")
        case .editorPackage: String(localized: "\(model.recording.bundle.name) – Final Cut")
        default: model.recording.bundle.name + "." + preset.fileExtension
        }
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        if !preset.fileExtension.isEmpty, let type = UTType(filenameExtension: preset.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start([(preset, url)])
    }

    /// En fil- eller mappadress som inte finns än ("namn.mp4", "namn (2).mp4" …).
    static func freeURL(in dir: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL { ext.isEmpty ? dir.appendingPathComponent(name, isDirectory: true)
                                                       : dir.appendingPathComponent(name).appendingPathExtension(ext) }
        var url = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = make("\(base) (\(n))"); n += 1 }
        return url
    }

    /// YouTube (privat, med kapitlen i beskrivningen) eller Dropbox; länken hamnar i urklipp.
    private func uploadCloud(_ service: CloudStore.Service, _ file: URL) {
        uploading = 0
        error = nil
        let title = model.recording.meta.name.isEmpty ? model.recording.bundle.name : model.recording.meta.name
        let description = finishedChapters ?? ""
        Task {
            do {
                let report: @Sendable (Double) -> Void = { p in Task { @MainActor in uploading = p } }
                sharedURL = service == .youtube
                    ? try await CloudStore.uploadYouTube(file, title: title, description: description, progress: report)
                    : try await CloudStore.uploadDropbox(file, progress: report)
            } catch {
                self.error = error.localizedDescription
            }
            uploading = nil
        }
    }

    private func upload(_ file: URL) {
        uploading = 0
        Task {
            do {
                sharedURL = try await SharingStore.share(file) { p in Task { @MainActor in uploading = p } }
            } catch {
                self.error = error.localizedDescription
            }
            uploading = nil
        }
    }

    static func icon(_ p: ExportPreset) -> String {
        if p.matroska { return "shippingbox" }
        return switch p.codec {
        case .h264: "play.rectangle"
        case .hevc: "4k.tv"
        case .hevcHDR: "sun.max"
        case .av1: "film"
        case .prores: "film.stack"
        case .proresAlpha: "square.on.square.dashed"
        case .gif: "photo.on.rectangle.angled"
        case .audioAAC: "waveform"
        case .audioWAV: "waveform.badge.plus"
        case .audioStems: "slider.vertical.3"
        case .editorPackage: "film.stack.fill"
        }
    }

    private func makeBugReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Felrapport – \(model.recording.bundle.name)")
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        progress = 0
        model.player.pause()
        let rec = model.recording, project = model.project
        Task {
            do {
                let out = try await BugReport.make(rec, project: project, title: rec.bundle.name, app: nil, in: url)
                progress = 1
                finishedURL = out.zip ?? out.report
            } catch {
                self.error = error.localizedDescription
                progress = nil
            }
        }
    }

    private func makeGuide() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.recording.bundle.name) – guide"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        progress = 0
        model.player.pause()
        let rec = model.recording, project = model.project
        Task {
            do {
                let out = try await GuideMaker.make(rec, project: project, title: rec.bundle.name, in: url)
                progress = 1
                finishedURL = out.html
                if out.steps == 0 { error = String(localized: "Inga klick eller kortkommandon i de delar som är kvar.") }
            } catch {
                self.error = error.localizedDescription
                progress = nil
            }
        }
    }

    /// Exporterar ett eller flera förval i tur och ordning.
    private func start(_ jobs: [(preset: ExportPreset, url: URL)]) {
        guard !jobs.isEmpty else { return }
        error = nil
        progress = 0
        finishedAll = []
        model.player.pause()
        let fps = model.recording.meta.fps > 60 && fullFrameRate ? model.recording.meta.fps : nil
        let range = onlyMarked ? model.markedRange : nil
        Task {
            var done: [URL] = []
            for (i, job) in jobs.enumerated() {
                batchLabel = jobs.count > 1 ? String(localized: "\(job.preset.name), \(i + 1) av \(jobs.count)") : nil
                let isGIF = job.preset.codec == .gif
                let exporter = Exporter(recording: model.recording, project: model.project, preset: job.preset, fps: fps, range: range,
                                        loudnessTarget: loudness < 0 && !isGIF ? loudness : nil, quality: quality)
                self.exporter = exporter
                do {
                    try await exporter.run(to: job.url) { p in
                        Task { @MainActor in progress = (Double(i) + p) / Double(jobs.count) }
                    }
                    if subtitles, !isGIF, let captions = model.plan.captions {
                        let srt = range.map { captions.srt(in: $0) } ?? captions.srt
                        try? srt.write(to: job.url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                    }
                    done.append(job.url)
                } catch Exporter.ExportError.cancelled {
                    break
                } catch {
                    self.error = "\(job.preset.name): \(error.localizedDescription)"
                }
            }
            batchLabel = nil
            guard let first = done.first else { progress = nil; return }
            let span = range ?? 0...model.duration
            let chapters = model.plan.overlayTrack.youtubeChapters(in: span)
            finishedChapters = model.project.chapters.isEmpty || chapters.isEmpty ? nil : chapters
            finishedAll = done
            finishedURL = first
            progress = 1
        }
    }
}
