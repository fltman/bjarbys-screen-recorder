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
                .help("Hela skärmen under pekaren (\(HotKeys.shared.binding(.toggleRecording).display))")
                Button { recorder.recordWindow() } label: { Label("Fönster", systemImage: "macwindow") }
                Button { recorder.recordApplication() } label: { Label("Program", systemImage: "app.dashed") }
                Button { recorder.recordArea() } label: { Label("Område", systemImage: "rectangle.dashed") }
                    .help("Dra upp ett område (\(HotKeys.shared.binding(.area).display))")
                Menu { DeviceMenuItems(recorder: recorder) } label: { Label("Enhet", systemImage: "iphone") }
                    .help("En kamera, eller en iPhone/iPad via kabel")
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
    /// Ihopslagningen: vilka som är valda (nil = rutan stängd).
    @State private var merging: Set<URL>?
    /// Inspelningen som byter namn, och det nya namnet.
    @State private var renaming: RecordingLibrary.Item?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18)]

    var body: some View {
        content
            .sheet(isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
                MergeSheet(library: library, selected: merging ?? []) { merged in
                    merging = nil
                    library.reload()
                    if let merged { app.openEditor(merged) }
                }
            }
            .alert("Byt namn", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Namn", text: $newName)
                Button("Byt namn") { if let item = renaming { library.rename(item, to: newName) }; renaming = nil }
                    .keyboardShortcut(.defaultAction)
                Button("Avbryt", role: .cancel) { renaming = nil }
            } message: {
                Text("Tomt namn visar datumet igen.")
            }
    }

    @ViewBuilder private var content: some View {
        if library.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "record.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Inga inspelningar än")
                    .font(.title3.weight(.medium))
                Text("Tryck \(HotKeys.shared.binding(.toggleRecording).display) för att spela in skärmen under pekaren.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Sök i namn och i det som sades", text: $library.query)
                            .textFieldStyle(.plain)
                        if !library.query.isEmpty {
                            Button { library.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .frame(width: 320)
                }
                .padding(.horizontal, 20).padding(.top, 14)
                grid
            }
        }
    }

    private var grid: some View {
        let found = library.filtered
        return Group {
            if found.isEmpty {
                Text("Inget hittades för «\(library.query)».")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(found, id: \.item.id) { entry in
                        let item = entry.item
                        RecordingCard(item: item, quote: { if case .speech(let s) = entry.match { return s } else { return nil } }())
                            .onTapGesture(count: 2) { app.openEditor(item.bundle) }
                            .contextMenu {
                                Button("Öppna") { app.openEditor(item.bundle) }
                                Button("Visa i Finder") { library.revealInFinder(item) }
                                Button("Byt namn …") { newName = item.meta?.name ?? ""; renaming = item }
                                Button("Slå ihop med andra …") { merging = [item.bundle.url] }
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
}

struct RecordingCard: View {
    let item: RecordingLibrary.Item
    /// Ett citat ur talet, när sökningen träffade där.
    var quote: String? = nil
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
                if let meta = item.meta {
                    // Med eget namn står datumet här, före källan.
                    Text(verbatim: meta.name.isEmpty ? meta.source.title : "\(Self.dateTitle(for: item)) · \(meta.source.title)")
                } else {
                    Text("Oläslig meta.json")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let quote {
                Text(verbatim: "«\(quote)»")
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
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
            if kinds.contains(.app) { Image(systemName: "app.badge.fill").help("Ljud per app") }
            if item.meta?.hdr == true {
                Text(verbatim: "HDR").font(.caption2.weight(.bold)).help("Inspelad i HDR (10 bit)")
            }
            if FileManager.default.fileExists(atPath: item.bundle.transcriptURL.path) {
                Image(systemName: "text.quote").help("Transkriberad")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    /// Namnet användaren gett inspelningen, annars datumet.
    static func title(for item: RecordingLibrary.Item) -> String {
        if let name = item.meta?.name, !name.isEmpty { return name }
        return dateTitle(for: item)
    }

    /// "Idag kl. 02.04", "Igår kl. 22.27", "4 nov. kl. 22.27" — ur inspelningens tid.
    static func dateTitle(for item: RecordingLibrary.Item) -> String {
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

/// Slå ihop inspelningar: välj vilka, i tidsordning (äldst först), och få en ny inspelning.
struct MergeSheet: View {
    @ObservedObject var library: LibraryModel
    @State var selected: Set<URL>
    let done: (RecordingBundle?) -> Void
    @State private var working = false
    @State private var error: String?

    private var items: [RecordingLibrary.Item] {
        library.items.filter { $0.meta?.finished == true }
            .sorted { ($0.meta?.createdAt ?? .distantPast) < ($1.meta?.createdAt ?? .distantPast) }
    }

    /// Upplösningarna bland de valda (ihopslagningen kodar inte om, så de måste vara lika).
    private var sizes: [String] {
        Set(items.filter { selected.contains($0.bundle.url) }.compactMap { $0.meta.map { "\($0.source.pixelWidth)×\($0.source.pixelHeight)" } }).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Slå ihop inspelningar").font(.title2.weight(.semibold))
            Text("De valda läggs efter varandra i tidsordning i en ny inspelning. Originalen rörs inte. Upplösningen måste vara densamma.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(items) { item in
                Toggle(isOn: Binding(get: { selected.contains(item.bundle.url) }, set: { on in
                    if on { selected.insert(item.bundle.url) } else { selected.remove(item.bundle.url) }
                })) {
                    HStack {
                        Text(verbatim: RecordingCard.title(for: item))
                        Spacer()
                        if let m = item.meta {
                            Text(verbatim: "\(m.source.pixelWidth)×\(m.source.pixelHeight)").font(.caption).foregroundStyle(.secondary)
                            Text(RecordingController.duration(m.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 280)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if sizes.count > 1 {
                Label("Olika upplösning (\(sizes.joined(separator: ", "))) — välj inspelningar av samma storlek.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Slår ihop …").foregroundStyle(.secondary) }
                Spacer()
                Button("Avbryt", role: .cancel) { done(nil) }.disabled(working)
                Button("Slå ihop \(selected.count)") { merge() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.count < 2 || sizes.count > 1 || working)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func merge() {
        let bundles = items.filter { selected.contains($0.bundle.url) }.map(\.bundle)
        working = true
        error = nil
        Task {
            do {
                let merged = try await RecordingMerger.merge(bundles, into: library.directory)
                done(merged)
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}
