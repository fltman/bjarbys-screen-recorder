import Foundation

/// `recording/meta.json`. Skrivs när inspelningen startar (så att en krasch lämnar ett
/// identifierbart paket) och skrivs om när den stoppas med `finished = true`.
public struct RecordingMeta: Codable, Equatable, Sendable {
    public enum SourceKind: String, Codable, Sendable {
        case display, window, area, application
    }

    /// Vad som spelades in och var det låg på skärmen.
    public struct Source: Codable, Equatable, Sendable {
        public var kind: SourceKind
        /// Läsbar beskrivning, t.ex. "Inbyggd Retina-skärm" eller "Safari — Startsida".
        public var title: String
        public var displayID: UInt32
        public var windowID: UInt32?
        /// Innehållets ram i globala punkter (CoreGraphics: origo uppe till vänster på
        /// huvudskärmen). För fönster: ramen när inspelningen startade; ändringar loggas som
        /// `frame`-händelser.
        public var contentRect: Rect
        /// Pixlar per punkt i inspelningen (2 på Retina).
        public var pixelScale: Double
        /// Storleken på skärmspåret i pixlar.
        public var pixelWidth: Int
        public var pixelHeight: Int

        public init(kind: SourceKind, title: String, displayID: UInt32, windowID: UInt32?,
                    contentRect: Rect, pixelScale: Double, pixelWidth: Int, pixelHeight: Int) {
            self.kind = kind; self.title = title; self.displayID = displayID; self.windowID = windowID
            self.contentRect = contentRect; self.pixelScale = pixelScale
            self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        }

        public static let empty = Source(kind: .display, title: "", displayID: 0, windowID: nil,
                                         contentRect: .zero, pixelScale: 1, pixelWidth: 0, pixelHeight: 0)

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Source.empty
            kind = c.value(.kind, d.kind)
            title = c.value(.title, d.title)
            displayID = c.value(.displayID, d.displayID)
            windowID = c.value(.windowID, d.windowID)
            contentRect = c.value(.contentRect, d.contentRect)
            pixelScale = c.value(.pixelScale, d.pixelScale)
            pixelWidth = c.value(.pixelWidth, d.pixelWidth)
            pixelHeight = c.value(.pixelHeight, d.pixelHeight)
        }
    }

    public enum TrackKind: String, Codable, Sendable, CaseIterable {
        case screen, microphone, system, camera
    }

    public struct Track: Codable, Equatable, Sendable {
        public var kind: TrackKind
        /// Sökväg relativt `recording/`.
        public var file: String
        /// Läsbart namn på källan, t.ex. mikrofonens namn.
        public var deviceName: String
        public var failed: Bool

        public init(kind: TrackKind, file: String, deviceName: String = "", failed: Bool = false) {
            self.kind = kind; self.file = file; self.deviceName = deviceName; self.failed = failed
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = c.value(.kind, .screen)
            file = c.value(.file, "")
            deviceName = c.value(.deviceName, "")
            failed = c.value(.failed, false)
        }
    }

    /// Ett avbrott i strömmen (vakthunden startade om den). Tider i sekunder på
    /// inspelningens tidslinje.
    public struct Gap: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var reason: String

        public init(start: Double, end: Double, reason: String) {
            self.start = start; self.end = end; self.reason = reason
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = c.value(.start, 0); end = c.value(.end, 0); reason = c.value(.reason, "")
        }
    }

    public var schemaVersion: Int
    public var appVersion: String
    public var createdAt: Date
    public var source: Source
    public var fps: Int
    public var tracks: [Track]
    /// Inspelningens längd i sekunder (pauser borträknade). Sätts vid stopp eller återställning.
    public var duration: Double
    public var finished: Bool
    /// Sant om paketet räddades efter en krasch i stället för att stoppas normalt.
    public var recovered: Bool
    public var gaps: [Gap]
    /// Sant om tangenttryck spelades in (bara kortkommandon, aldrig vanlig text).
    public var keystrokesRecorded: Bool
    public var droppedFrames: Int
    /// Tidslinjens nollpunkt i värdklockan (s), så att delar från olika sessioner kan läggas
    /// i rätt förhållande till varandra (flashback-bufferten). 0 = okänd.
    public var startHostTime: Double

    public init(source: Source, fps: Int, appVersion: String) {
        self.schemaVersion = RecorderKit.formatVersion
        self.appVersion = appVersion
        self.createdAt = Date()
        self.source = source
        self.fps = fps
        self.tracks = []
        self.duration = 0
        self.finished = false
        self.recovered = false
        self.gaps = []
        self.keystrokesRecorded = false
        self.droppedFrames = 0
        self.startHostTime = 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, RecorderKit.formatVersion)
        appVersion = c.value(.appVersion, "")
        createdAt = c.value(.createdAt, Date(timeIntervalSince1970: 0))
        source = c.value(.source, .empty)
        fps = c.value(.fps, 60)
        tracks = c.value(.tracks, [])
        duration = c.value(.duration, 0)
        finished = c.value(.finished, false)
        recovered = c.value(.recovered, false)
        gaps = c.value(.gaps, [])
        keystrokesRecorded = c.value(.keystrokesRecorded, false)
        droppedFrames = c.value(.droppedFrames, 0)
        startHostTime = c.value(.startHostTime, 0)
    }

    public func track(_ kind: TrackKind) -> Track? {
        tracks.first { $0.kind == kind && !$0.failed }
    }
}
