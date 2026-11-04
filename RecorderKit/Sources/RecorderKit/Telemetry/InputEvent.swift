import Foundation

/// En rad i `recording/events.jsonl`. Platt struktur med valfria fält i stället för en
/// enum med associerade värden: en okänd eller trasig rad ska kunna läsas så långt det går,
/// och nya händelsetyper ska inte göra gamla läsare blinda för de kända.
///
/// Koordinater är globala punkter (CoreGraphics: origo uppe till vänster på huvudskärmen).
/// `t` är sekunder på inspelningens tidslinje — samma nollpunkt som videospåren, pauser
/// borträknade.
public struct InputEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case move, down, up, drag, scroll, key
        /// Markören bytte utseende; `cursor` pekar på en post i `cursors.json`.
        case cursor
        /// Det inspelade fönstret flyttades eller ändrade storlek; `rect` är den nya ramen.
        case frame
        /// Ramen för gränssnittselementet under ett klick (via Accessibility).
        case element
        case pause, resume
        case unknown
    }

    public var t: Double
    public var k: Kind
    public var x: Double?
    public var y: Double?
    /// Musknapp: 0 vänster, 1 höger, 2 övriga.
    public var b: Int?
    /// Antal klick i följd (dubbelklick = 2).
    public var n: Int?
    public var dx: Double?
    public var dy: Double?
    /// Tangentkod (virtuell).
    public var code: Int?
    /// Läsbar etikett för kortkommandot, t.ex. "⌘⇧S".
    public var label: String?
    public var cursor: String?
    public var rect: Rect?

    public init(t: Double, k: Kind, x: Double? = nil, y: Double? = nil, b: Int? = nil, n: Int? = nil,
                dx: Double? = nil, dy: Double? = nil, code: Int? = nil, label: String? = nil,
                cursor: String? = nil, rect: Rect? = nil) {
        self.t = t; self.k = k; self.x = x; self.y = y; self.b = b; self.n = n
        self.dx = dx; self.dy = dy; self.code = code; self.label = label
        self.cursor = cursor; self.rect = rect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = c.value(.t, 0)
        k = c.value(.k, .unknown)
        x = c.value(.x, nil); y = c.value(.y, nil)
        b = c.value(.b, nil); n = c.value(.n, nil)
        dx = c.value(.dx, nil); dy = c.value(.dy, nil)
        code = c.value(.code, nil); label = c.value(.label, nil)
        cursor = c.value(.cursor, nil); rect = c.value(.rect, nil)
    }

    public var point: CGPoint? {
        guard let x, let y else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// `recording/cursors.json`: markörbilderna som syntes under inspelningen.
public struct CursorCatalog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Hash av bilden; filen heter `cursors/<id>.png`.
        public var id: String
        /// Bildens storlek i punkter.
        public var width: Double
        public var height: Double
        /// Hotspot i punkter från bildens övre vänstra hörn.
        public var hotX: Double
        public var hotY: Double

        public init(id: String, width: Double, height: Double, hotX: Double, hotY: Double) {
            self.id = id; self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.value(.id, ""); width = c.value(.width, 0); height = c.value(.height, 0)
            hotX = c.value(.hotX, 0); hotY = c.value(.hotY, 0)
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = c.value(.entries, [])
    }

    public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
}
