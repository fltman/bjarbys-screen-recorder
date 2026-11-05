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
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Samma ram för alla, oavsett inspelningens format; bilden fyller och beskärs.
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(Thumbnail(url: item.bundle.thumbnailURL))
                .overlay {
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.25)
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.white, .black.opacity(0.35))
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let meta = item.meta {
                        Text(RecordingController.duration(meta.duration))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(7)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(hovering ? 0.22 : 0.08), radius: hovering ? 10 : 4, y: hovering ? 5 : 2)
                .scaleEffect(hovering ? 1.015 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)

            HStack(spacing: 6) {
                Text(Self.title(for: item))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if item.meta?.recovered == true {
                    Text("Återställd")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                        .help("Inspelningen stoppades aldrig normalt och har räddats fram till sista sparade biten.")
                }
                Spacer(minLength: 0)
                badges
            }
            Group {
                if let title = item.meta?.source.title { Text(verbatim: title) } else { Text("Oläslig meta.json") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Små ikoner för det inspelningen har: mikrofon, kamera, transkript.
    private var badges: some View {
        HStack(spacing: 5) {
            let kinds = Set(item.meta?.tracks.filter { !$0.failed }.map(\.kind) ?? [])
            if kinds.contains(.microphone) { Image(systemName: "mic.fill").help("Mikrofon") }
            if kinds.contains(.camera) { Image(systemName: "video.fill").help("Kamera") }
            if FileManager.default.fileExists(atPath: item.bundle.transcriptURL.path) {
                Image(systemName: "text.quote").help("Transkriberad")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    /// "Idag kl. 02.04", "Igår kl. 22.27", "4 nov. kl. 22.27" — ur inspelningens tid.
    static func title(for item: RecordingLibrary.Item) -> String {
        guard let date = item.meta?.createdAt, date.timeIntervalSince1970 > 0 else {
            return item.bundle.name.replacingOccurrences(of: "Inspelning ", with: "")
        }
        let time = date.formatted(Date.FormatStyle(locale: AppLocale.locale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .replacingOccurrences(of: ":", with: ".")
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Idag kl. \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Igår kl. \(time)") }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        let style = Date.FormatStyle(locale: AppLocale.locale)
        let day = sameYear ? date.formatted(style.day().month(.abbreviated))
                           : date.formatted(style.day().month(.abbreviated).year())
        return String(localized: "\(day) kl. \(time)")
    }
}

private struct Thumbnail: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill().allowsHitTesting(false)
        } else {
            Rectangle().fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
        }
    }
}
