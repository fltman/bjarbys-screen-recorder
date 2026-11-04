import SwiftUI
import RecorderKit

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            RecordBar(recorder: app.recorder, settings: app.settings)
                .padding(.horizontal, 20)
                .padding(.top, 36)
                .padding(.bottom, 14)
            Divider()
            LibraryGrid(library: app.library)
        }
        .frame(minWidth: 860, minHeight: 420)
    }
}

/// Knapparna för att starta en inspelning och valen av spår.
private struct RecordBar: View {
    @ObservedObject var recorder: RecordingController
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                Button { recorder.recordDisplayUnderMouse() } label: {
                    Label("Skärm", systemImage: "display")
                }
                .help("Hela skärmen under pekaren (⌃⌥⌘R)")
                Button { recorder.recordWindow() } label: { Label("Fönster", systemImage: "macwindow") }
                Button { recorder.recordApplication() } label: { Label("Program", systemImage: "app.dashed") }
                Button { recorder.recordArea() } label: { Label("Område", systemImage: "rectangle.dashed") }
                    .help("Dra upp ett område (⌃⌥⌘A)")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .fixedSize()
            .disabled(recorder.isBusy)

            Spacer(minLength: 16)

            Picker(selection: $settings.micID) {
                Text("Ingen mikrofon").tag("")
                Text("Standardmikrofonen").tag("standard")
                Divider()
                ForEach(settings.microphones) { Text($0.name).tag($0.id) }
            } label: {
                Image(systemName: settings.micID.isEmpty ? "mic.slash" : "mic.fill")
            }
            .frame(maxWidth: 190)
            .help("Mikrofon")

            Picker(selection: $settings.cameraID) {
                Text("Ingen kamera").tag("")
                Divider()
                ForEach(settings.cameras) { Text($0.name).tag($0.id) }
            } label: {
                Image(systemName: settings.cameraID.isEmpty ? "video.slash" : "video.fill")
            }
            .frame(maxWidth: 170)
            .help("Kamera")

            Toggle(isOn: $settings.systemAudio) {
                Image(systemName: settings.systemAudio ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .toggleStyle(.button)
            .help("Datorljud")
        }
        .onAppear { settings.refreshDevices() }
    }
}

private struct LibraryGrid: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var library: LibraryModel

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18)]

    var body: some View {
        if library.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "record.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Inga inspelningar än")
                    .font(.title3.weight(.medium))
                Text("Tryck ⌃⌥⌘R för att spela in skärmen under pekaren.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(library.items) { item in
                        RecordingCard(item: item)
                            .onTapGesture(count: 2) { app.openEditor(item.bundle) }
                            .contextMenu {
                                Button("Öppna") { app.openEditor(item.bundle) }
                                Button("Visa i Finder") { library.revealInFinder(item) }
                                Divider()
                                Button("Flytta till papperskorgen", role: .destructive) { library.moveToTrash(item) }
                            }
                    }
                }
                .padding(20)
            }
        }
    }
}

private struct RecordingCard: View {
    let item: RecordingLibrary.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Thumbnail(url: item.bundle.thumbnailURL)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let meta = item.meta {
                    Text(RecordingController.duration(meta.duration))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            HStack(spacing: 6) {
                Text(item.bundle.name.replacingOccurrences(of: "Inspelning ", with: ""))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if item.meta?.recovered == true {
                    Text("Återställd")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                        .help("Inspelningen stoppades aldrig normalt och har räddats fram till sista sparade biten.")
                }
            }
            Text(item.meta?.source.title ?? "Oläslig meta.json")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

private struct Thumbnail: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
        }
    }
}
