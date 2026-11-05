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

    private var preset: ExportPreset { ExportPreset.all.first { $0.id == presetID } ?? ExportPreset.all[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exportera").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(ExportPreset.all) { p in
                    let canvas = p.canvas(aspect: model.project.aspect, source: model.recording.sourceSize)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: p.id == presetID ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(p.id == presetID ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.headline)
                            Text(p.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(canvas.width))×\(Int(canvas.height)), \(p.fps) bilder/s")
                            Text("≈ " + ByteCountFormatter.string(fromByteCount: p.estimatedBytes(canvas: canvas, duration: model.duration),
                                                                 countStyle: .file))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if progress == nil { presetID = p.id } }
                }
            }

            if model.recording.meta.fps > 60 && presetID != "gif" {
                Toggle("\(model.recording.meta.fps) bilder/s, som inspelningen", isOn: $fullFrameRate)
                    .disabled(progress != nil)
            }
            if model.plan.captions != nil && presetID != "gif" {
                Toggle("Spara undertexter (.srt) bredvid filmen", isOn: $subtitles)
                    .disabled(progress != nil)
            }

            if let progress {
                ProgressView(value: progress) {
                    Text(finishedURL == nil ? "Exporterar …" : "Klart")
                } currentValueLabel: {
                    Text("\(Int(progress * 100)) %").monospacedDigit()
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            HStack {
                if progress == nil && finishedURL == nil {
                    Button("Felrapport …") { makeBugReport() }
                        .help("Film, steg för att återskapa, miljö och systemlogg i en mapp och en zip.")
                    Button("Steg-för-steg-guide …") { makeGuide() }
                        .help("En bild per klick och kortkommando, med det du sa som text. Markdown och HTML.")
                }
                if let finishedURL {
                    if let sharedURL {
                        Text(sharedURL.absoluteString).font(.caption).textSelection(.enabled).lineLimit(1)
                    } else if let uploading {
                        ProgressView(value: uploading).frame(width: 120)
                    } else if SharingStore.isReady {
                        Button("Ladda upp och kopiera länk") { upload(finishedURL) }
                    }
                    Button("Visa i Finder") { NSWorkspace.shared.activateFileViewerSelecting([finishedURL]) }
                }
                Spacer()
                if progress != nil && finishedURL == nil {
                    Button("Avbryt export", role: .cancel) { exporter?.cancel() }
                } else {
                    Button(finishedURL == nil ? "Avbryt" : "Stäng", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if finishedURL == nil {
                        Button("Exportera …") { chooseAndExport() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func chooseAndExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.recording.bundle.name + "." + preset.fileExtension
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        if let type = UTType(filenameExtension: preset.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(url)
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

    private func start(_ url: URL) {
        error = nil
        progress = 0
        model.player.pause()
        let fps = model.recording.meta.fps > 60 && fullFrameRate ? model.recording.meta.fps : nil
        let exporter = Exporter(recording: model.recording, project: model.project, preset: preset, fps: fps)
        self.exporter = exporter
        Task {
            do {
                try await exporter.run(to: url) { p in
                    Task { @MainActor in progress = p }
                }
                if subtitles, presetID != "gif", let srt = model.plan.captions?.srt {
                    try? srt.write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                }
                finishedURL = url
                progress = 1
            } catch Exporter.ExportError.cancelled {
                progress = nil
            } catch {
                self.error = error.localizedDescription
                progress = nil
            }
        }
    }
}
