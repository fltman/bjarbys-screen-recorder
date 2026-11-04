import Foundation
import CoreGraphics

// ⚠️ Varje typ som skrivs till disk avkodas med `value(_:_:)` nedan i en handskriven
// `init(from:)`. Swift använder inte egenskapernas standardvärden när en nyckel saknas,
// och ett nytt fält skulle då göra alla gamla projekt oläsbara — tyst, eftersom filerna
// läses med `try?`. Det hände tre gånger i Kundkoll. `MinimalJSONTests` provar att `{}`
// avkodas för varje typ.

extension KeyedDecodingContainer {
    /// Läser en nyckel och faller tillbaka på `fallback` om den saknas eller har fel typ.
    /// Fel typ tolereras med flit: ett trasigt fält ska inte ta hela inspelningen med sig.
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        if let v = try? decodeIfPresent(T.self, forKey: key) { return v }
        return fallback()
    }
}

/// Gemensam JSON-kodning för paketets filer: läsbar, stabil nyckelordning, datum i ISO 8601.
enum BundleJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Skriver atomärt så att en krasch mitt i skrivningen aldrig lämnar en halv fil.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }
}

/// En rektangel som kodas som `[x, y, w, h]` — kompakt i händelseloggen.
public struct Rect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public init(_ r: CGRect) {
        self.init(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = (try? c.decode(Double.self)) ?? 0
        y = (try? c.decode(Double.self)) ?? 0
        width = (try? c.decode(Double.self)) ?? 0
        height = (try? c.decode(Double.self)) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(width); try c.encode(height)
    }
}
