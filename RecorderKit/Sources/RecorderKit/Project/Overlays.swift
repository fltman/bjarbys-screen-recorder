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
        /// Ett videoinslag ur `media/`: bild-i-bild eller helbild (`frame` [0,0,1,1]), med ljud.
        case video
        /// En pil i innehållet (zoomar med det): från (`target.x`, `target.y`) till spetsen
        /// (`target.x + width`, `target.y + height`); bredd och höjd kan vara negativa.
        case arrow
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
    /// Video: var i filen inslaget börjar (s).
    public var offset: Double
    /// Video: ljudets volym (0 = tyst).
    public var volume: Double
    /// Video: utsnittet av videons bild (0–1, origo uppe till vänster), nil = hela.
    public var crop: Rect?
    /// Video: mjuka kanter, 0 = skarpa (med rundade hörn och skugga) till 1 = mycket mjuka.
    public var softness: Double
    /// Video: hastighet (0,25–4). `duration` är fortfarande tiden i filmen; videon spelar
    /// `duration × speed` sekunder av filen.
    public var speed: Double
    /// Hur lagret kommer in: tonas, glider upp, poppar fram, eller skrivs fram (text och rubrik).
    public var animation: Animation
    public enum Animation: String, Codable, Sendable, CaseIterable { case fade, slide, pop, typewriter }
    /// Pilens färg (#RRGGBB).
    public var color: String

    public init(id: UUID = UUID(), kind: Kind, at: Double, duration: Double = 4, title: String = "",
                lines: [String] = [], url: String = "", target: Rect? = nil, corner: Corner = .topRight,
                frame: Rect? = nil, file: String = "", size: Double = 1, background: Bool = true) {
        self.id = id; self.kind = kind; self.at = at; self.duration = duration; self.title = title
        self.lines = lines; self.url = url; self.target = target; self.corner = corner
        self.frame = frame; self.file = file; self.size = size; self.background = background
        self.offset = 0; self.volume = 1
        self.crop = nil; self.softness = 0; self.speed = 1
        self.animation = .fade
        self.color = "#FF3B30"
    }

    /// Täcker hela bildytan (helbild): ritas utan hörn och skugga, och fyller.
    public var isFullFrame: Bool {
        guard let f = frame else { return false }
        return f.x <= 0.01 && f.y <= 0.01 && f.width >= 0.98 && f.height >= 0.98
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
        offset = c.value(.offset, 0)
        volume = c.value(.volume, 1)
        crop = c.value(.crop, nil)
        softness = c.value(.softness, 0)
        speed = c.value(.speed, 1)
        animation = c.value(.animation, .fade)
        color = c.value(.color, "#FF3B30")
    }

    /// Pilens start och spets (innehållets koordinater, 0–1).
    public var arrowEnds: (start: CGPoint, tip: CGPoint)? {
        guard kind == .arrow, let t = target else { return nil }
        return (CGPoint(x: t.x, y: t.y), CGPoint(x: t.x + t.width, y: t.y + t.height))
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

    /// Det som syns vid utdatatiden `t`, med opacitet, infadningens förlopp (0–1) och tiden sedan
    /// lagret började synas (för animationerna).
    public func visible(at t: Double) -> [(overlay: Overlay, opacity: Double, entrance: Double, elapsed: Double)] {
        placed.compactMap { p in
            guard t >= p.start, t < p.end else { return nil }
            let entrance = min(1, (t - p.start) / Self.fadeIn)
            let opacity = min(entrance, min(1, (p.end - t) / Self.fadeOut))
            return (p.overlay, opacity, entrance, t - p.start)
        }
    }

    /// Skrivmaskinen: hur många tecken (rubrik, sedan raderna) som syns efter `elapsed` sekunder,
    /// eller nil när allt syns. 35 ms per tecken, mellan 0,4 och 1,5 s för hela texten.
    public static func typewriterReveal(_ o: Overlay, elapsed: Double) -> Int? {
        guard o.animation == .typewriter, o.kind == .text || o.kind == .title else { return nil }
        let total = o.title.count + o.lines.joined().count
        let duration = min(1.5, max(0.4, 0.035 * Double(total)))
        let n = Int(Double(total) * min(1, elapsed / duration))
        return n < total ? n : nil
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

    /// Kapitlen inom `range` (utdatatid) som en sammanhängande lista: kapitlet som pågår vid
    /// utsnittets början börjar där, och "Start" läggs först om inget pågår. Till filmens
    /// kapitelspår och YouTube-texten för ett utsnitt.
    public func chapterList(in range: ClosedRange<Double>) -> [(start: Double, end: Double, title: String)] {
        guard !chapters.isEmpty else { return [] }
        var starts: [(Double, String)] = []
        if let running = chapters.last(where: { $0.start <= range.lowerBound + 0.001 }) {
            starts.append((range.lowerBound, running.chapter.title))
        } else {
            starts.append((range.lowerBound, String(localized: "Start")))
        }
        for c in chapters where c.start > range.lowerBound + 0.001 && c.start < range.upperBound - 0.5 {
            starts.append((c.start, c.chapter.title))
        }
        return starts.enumerated().map { i, c in
            (c.0, i + 1 < starts.count ? starts[i + 1].0 : range.upperBound, c.1)
        }
    }

    /// YouTube-texten för ett utsnitt, med tider räknade från utsnittets början.
    public func youtubeChapters(in range: ClosedRange<Double>) -> String {
        chapterList(in: range).map { "\(Self.stamp($0.start - range.lowerBound)) \($0.title)" }.joined(separator: "\n")
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
    /// `dub` = en rad i en dubbning: talet på ett annat språk (`language`), som ersätter
    /// mikrofonen när filmen har den rösten (`AudioMix.voice`).
    public enum Role: String, Codable, Sendable, CaseIterable { case narration, music, effect, dub }
    public var id: UUID
    public var role: Role
    /// Dubbningens språk (bara `dub`).
    public var language: String
    /// Uppspelningshastighet (1 = normal; en dubbningsrad som inte ryms spelas något fortare,
    /// med bibehållen tonhöjd).
    public var speed: Double
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
                volume: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0, language: String = "", speed: Double = 1) {
        self.id = id; self.role = role; self.at = at; self.file = file; self.text = text
        self.duration = duration; self.volume = volume; self.fadeIn = fadeIn; self.fadeOut = fadeOut
        self.language = language; self.speed = speed
    }

    /// Hur länge klippet låter i filmen (längden genom hastigheten).
    public var outputDuration: Double { duration / max(speed, 0.01) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); role = c.value(.role, .narration); at = c.value(.at, 0)
        file = c.value(.file, ""); text = c.value(.text, ""); duration = c.value(.duration, 0)
        volume = c.value(.volume, 1); fadeIn = c.value(.fadeIn, 0); fadeOut = c.value(.fadeOut, 0)
        language = c.value(.language, ""); speed = c.value(.speed, 1)
    }
}

extension RecordingBundle {
    /// Extra media (ljudklipp, senare bilder och videoinslag).
    public var mediaDir: URL { url.appendingPathComponent("media", isDirectory: true) }
    /// Producentens brev: vad den valde och varför, och frågorna till människan.
    public var deliveryNoteURL: URL { url.appendingPathComponent("leverans.md") }
}
