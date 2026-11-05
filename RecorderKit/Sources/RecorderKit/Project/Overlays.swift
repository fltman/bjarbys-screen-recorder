import Foundation

/// Bildlagret: det producenten (en människa eller en AI via MCP) lägger ovanpå filmen.
/// Som allt annat i `project.json` är det beslut, inte pixlar — renderaren ritar dem.
/// `at` är källtid (sitter kvar på innehållet när annat klipps bort); `duration` är sekunder
/// i den färdiga filmen, så att en ruta syns lika länge även i en snabbspolad del.
public struct Overlay: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Rubrikkort mitt i bilden (intro, avsnittsskifte).
        case title
        /// Markering runt ett gränssnittselement, med en etikett. Följer innehållet när det zoomas.
        case callout
        /// Faktaruta i ett hörn: rubrik och några rader.
        case fact
        /// QR-kod med rubrik och adress, i ett hörn.
        case qr
        /// Fri text var som helst i bilden (`frame`: mitt x/y och största bredd, 0–1 av bildytan).
        case text
        /// En bild ur `media/` (logotyp, produktbild), placerad fritt (`frame`, 0–1 av bildytan).
        case image
    }

    public enum Corner: String, Codable, Sendable, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    public var id: UUID
    public var kind: Kind
    public var at: Double
    public var duration: Double
    public var title: String
    public var lines: [String]
    /// QR-kodens adress.
    public var url: String
    /// Markeringens mål: elementets ram i innehållet (0–1, origo uppe till vänster).
    public var target: Rect?
    public var corner: Corner
    /// Fri placering i bildytan (0–1, origo uppe till vänster): text = mitt + bredd, bild = ram.
    public var frame: Rect?
    /// Bildens fil i `media/`.
    public var file: String
    /// Textens storlek relativt standard (1).
    public var size: Double
    /// Text på en mörk platta (annars skuggad text direkt på bilden).
    public var background: Bool

    public init(id: UUID = UUID(), kind: Kind, at: Double, duration: Double = 4, title: String = "",
                lines: [String] = [], url: String = "", target: Rect? = nil, corner: Corner = .topRight,
                frame: Rect? = nil, file: String = "", size: Double = 1, background: Bool = true) {
        self.id = id; self.kind = kind; self.at = at; self.duration = duration; self.title = title
        self.lines = lines; self.url = url; self.target = target; self.corner = corner
        self.frame = frame; self.file = file; self.size = size; self.background = background
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        kind = c.value(.kind, .fact)
        at = c.value(.at, 0)
        duration = c.value(.duration, 4)
        title = c.value(.title, "")
        lines = c.value(.lines, [])
        url = c.value(.url, "")
        target = c.value(.target, nil)
        corner = c.value(.corner, .topRight)
        frame = c.value(.frame, nil)
        file = c.value(.file, "")
        size = c.value(.size, 1)
        background = c.value(.background, true)
    }
}

/// Ett kapitel: rubrik från källtiden `at`. Visas som en kort kapitelrad i bild och blir
/// tidsstämplar i beskrivningen.
public struct Chapter: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var at: Double
    public var title: String

    public init(id: UUID = UUID(), at: Double, title: String) {
        self.id = id; self.at = at; self.title = title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); at = c.value(.at, 0); title = c.value(.title, "")
    }
}

/// Bildlagret i utdatatid: vad som syns när, med in- och uttoning.
public struct OverlayTrack: Sendable {
    public struct Placed: Sendable {
        public let overlay: Overlay
        public let start: Double
        public let end: Double
    }

    public static let fadeIn = 0.25
    public static let fadeOut = 0.3
    /// Så länge kapitelraden syns efter att ett kapitel börjat.
    public static let chapterHold = 3.0

    public let placed: [Placed]
    public let chapters: [(chapter: Chapter, start: Double, index: Int)]

    public init(overlays: [Overlay], chapters: [Chapter], timeMap: TimeMap) {
        placed = overlays.compactMap { o in
            guard let s = timeMap.output(at: o.at) else { return nil }
            return Placed(overlay: o, start: s, end: s + max(0.3, o.duration))
        }
        .sorted { $0.start < $1.start }
        self.chapters = chapters.sorted { $0.at < $1.at }.enumerated()
            .compactMap { i, c in timeMap.output(at: c.at).map { (c, $0, i) } }
    }

    /// Det som syns vid utdatatiden `t`, med opacitet och infadningens förlopp (0–1).
    public func visible(at t: Double) -> [(overlay: Overlay, opacity: Double, entrance: Double)] {
        placed.compactMap { p in
            guard t >= p.start, t < p.end else { return nil }
            let entrance = min(1, (t - p.start) / Self.fadeIn)
            let opacity = min(entrance, min(1, (p.end - t) / Self.fadeOut))
            return (p.overlay, opacity, entrance)
        }
    }

    /// Kapitelraden vid `t`: kapitlet, dess nummer (från 1), antalet och opacitet.
    public func chapterBanner(at t: Double) -> (title: String, number: Int, of: Int, opacity: Double)? {
        guard let current = chapters.last(where: { $0.start <= t }), t < current.start + Self.chapterHold else { return nil }
        let into = t - current.start
        let opacity = min(min(1, into / Self.fadeIn), min(1, (Self.chapterHold - into) / Self.fadeOut))
        return (current.chapter.title, current.index + 1, chapters.count, opacity)
    }

    /// "0:00 Intro\n1:23 Exportera …" för en YouTube-beskrivning. YouTube kräver att första
    /// kapitlet börjar på 0:00; finns inget där läggs "Start" till.
    public var youtubeChapters: String {
        var rows = chapters.map { (Self.stamp($0.start), $0.chapter.title) }
        if let first = chapters.first, first.start > 0.5 { rows.insert(("0:00", "Start"), at: 0) }
        return rows.map { "\($0.0) \($0.1)" }.joined(separator: "\n")
    }

    static func stamp(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Ett extra ljudklipp: berättarröst, musik eller ljudeffekt. Filen ligger i paketets
/// `media/` (gjord utanför appen — berättarröst via elevenlabs-dialogue i Claude Code).
/// Berättarrösten sänker datorljud, mikrofon och musik under sig; musiken sänks under tal.
public struct AudioClip: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable, CaseIterable { case narration, music, effect }
    public var id: UUID
    public var role: Role
    /// Källtid där klippet börjar (det spelas i normal hastighet därifrån).
    public var at: Double
    /// Filnamnet i `media/`.
    public var file: String
    /// Det som sägs (berättarröst), för granskningen "det som sägs ska synas".
    public var text: String
    /// Klippets längd (s), uppmätt när det lades till.
    public var duration: Double
    public var volume: Double
    public var fadeIn: Double
    public var fadeOut: Double

    public init(id: UUID = UUID(), role: Role, at: Double, file: String, text: String = "", duration: Double,
                volume: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0) {
        self.id = id; self.role = role; self.at = at; self.file = file; self.text = text
        self.duration = duration; self.volume = volume; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); role = c.value(.role, .narration); at = c.value(.at, 0)
        file = c.value(.file, ""); text = c.value(.text, ""); duration = c.value(.duration, 0)
        volume = c.value(.volume, 1); fadeIn = c.value(.fadeIn, 0); fadeOut = c.value(.fadeOut, 0)
    }
}

extension RecordingBundle {
    /// Extra media (ljudklipp, senare bilder och videoinslag).
    public var mediaDir: URL { url.appendingPathComponent("media", isDirectory: true) }
    /// Producentens brev: vad den valde och varför, och frågorna till människan.
    public var deliveryNoteURL: URL { url.appendingPathComponent("leverans.md") }
}
