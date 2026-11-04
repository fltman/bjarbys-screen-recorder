import Foundation
import AVFoundation

/// Ett `.bsrec`-paket på disk. Se `docs/FORMAT.md`.
public struct RecordingBundle: Hashable, Identifiable, Sendable {
    public let url: URL
    public var id: URL { url }

    public init(url: URL) { self.url = url }

    public var recordingDir: URL { url.appendingPathComponent("recording", isDirectory: true) }
    public var metaURL: URL { recordingDir.appendingPathComponent("meta.json") }
    public var eventsURL: URL { recordingDir.appendingPathComponent("events.jsonl") }
    public var cursorsDir: URL { recordingDir.appendingPathComponent("cursors", isDirectory: true) }
    public var cursorCatalogURL: URL { recordingDir.appendingPathComponent("cursors.json") }
    public var projectURL: URL { url.appendingPathComponent("project.json") }
    public var thumbnailURL: URL { url.appendingPathComponent("thumbnail.jpg") }

    public static func fileName(for kind: RecordingMeta.TrackKind) -> String {
        switch kind {
        case .screen: "screen-0.mov"
        case .microphone: "mic-0.mov"
        case .system: "system-0.mov"
        case .camera: "camera-0.mov"
        }
    }

    public func trackURL(_ kind: RecordingMeta.TrackKind) -> URL {
        recordingDir.appendingPathComponent(Self.fileName(for: kind))
    }

    public func url(for track: RecordingMeta.Track) -> URL {
        recordingDir.appendingPathComponent(track.file)
    }

    /// Visningsnamnet: paketets namn utan ändelse.
    public var name: String { url.deletingPathExtension().lastPathComponent }

    // MARK: - Läsa

    public func readMeta() throws -> RecordingMeta {
        try BundleJSON.read(RecordingMeta.self, from: metaURL)
    }

    public func writeMeta(_ meta: RecordingMeta) throws {
        try BundleJSON.write(meta, to: metaURL)
    }

    public func readEvents() -> [InputEvent] {
        EventLogReader.read(eventsURL)
    }

    public func readCursors() -> CursorCatalog {
        (try? BundleJSON.read(CursorCatalog.self, from: cursorCatalogURL)) ?? CursorCatalog()
    }

    // MARK: - Skapa

    /// Skapar ett nytt tomt paket i `directory` med datum och tid som namn.
    public static func create(in directory: URL, date: Date = Date()) throws -> RecordingBundle {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "sv_SE")
        f.dateFormat = "yyyy-MM-dd 'kl.' HH.mm.ss"
        let base = "Inspelning \(f.string(from: date))"
        var url = directory.appendingPathComponent(base).appendingPathExtension(RecorderKit.bundleExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(n))").appendingPathExtension(RecorderKit.bundleExtension)
            n += 1
        }
        let bundle = RecordingBundle(url: url)
        try FileManager.default.createDirectory(at: bundle.cursorsDir, withIntermediateDirectories: true)
        return bundle
    }
}

/// Mappen där inspelningarna bor och genomsökningen av den.
public enum RecordingLibrary {
    public static var defaultDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("Bjarbys skärminspelare", isDirectory: true)
    }

    public struct Item: Identifiable, Hashable, Sendable {
        public let bundle: RecordingBundle
        public let meta: RecordingMeta?
        public var id: URL { bundle.url }

        public static func == (a: Item, b: Item) -> Bool { a.bundle == b.bundle && a.meta == b.meta }
        public func hash(into h: inout Hasher) { h.combine(bundle) }
    }

    /// Alla paket i mappen, nyast först. Ett paket med oläslig meta.json listas ändå
    /// (med `meta == nil`) i stället för att försvinna.
    public static func scan(_ directory: URL = defaultDirectory) -> [Item] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == RecorderKit.bundleExtension }
            .map { url in
                let b = RecordingBundle(url: url)
                return Item(bundle: b, meta: try? b.readMeta())
            }
            .sorted { a, b in
                (a.meta?.createdAt ?? .distantPast) > (b.meta?.createdAt ?? .distantPast)
            }
    }
}

/// Räddar paket som aldrig stoppades normalt (krasch, strömavbrott, `kill -9`).
/// Spåren är fragmenterade var 2:a sekund och går att spela upp till sista fragmentet;
/// det som saknas är bara en avslutad meta.json.
public enum Recovery {
    /// Paket i mappen med `finished == false`, utom det som spelas in just nu.
    public static func unfinished(in directory: URL = RecordingLibrary.defaultDirectory,
                                  excluding active: URL? = nil) -> [RecordingBundle] {
        RecordingLibrary.scan(directory).compactMap { item in
            guard item.bundle.url != active, let meta = item.meta, !meta.finished else { return nil }
            return item.bundle
        }
    }

    /// Markerar paketet som återställt och räknar ut längden ur skärmspåret.
    @discardableResult
    public static func recover(_ bundle: RecordingBundle) async throws -> RecordingMeta {
        var meta = try bundle.readMeta()
        var longest = 0.0
        for track in meta.tracks {
            let asset = AVURLAsset(url: bundle.url(for: track))
            if let d = try? await asset.load(.duration), d.isNumeric {
                if track.kind == .screen { longest = max(longest, d.seconds) }
            } else {
                // Spåret gick inte att öppna alls; markera det hellre än att låtsas.
                if let i = meta.tracks.firstIndex(of: track) { meta.tracks[i].failed = true }
            }
        }
        meta.duration = longest
        meta.finished = true
        meta.recovered = true
        try bundle.writeMeta(meta)
        return meta
    }
}
