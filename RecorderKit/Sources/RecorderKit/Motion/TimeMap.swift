import Foundation
import CoreGraphics

/// Källtid ↔ utdatatid genom klipp och hastighetsändringar. Delarna spelas i ordning;
/// det som inte ingår i någon del är bortklippt.
public struct TimeMap: Equatable, Sendable {
    public struct Piece: Equatable, Sendable {
        public let sourceStart: Double
        public let sourceEnd: Double
        public let outputStart: Double
        public let speed: Double
        public var outputEnd: Double { outputStart + (sourceEnd - sourceStart) / speed }
    }

    public let pieces: [Piece]

    public init(segments: [EditProject.ClipSegment]) {
        var out = 0.0
        var pieces: [Piece] = []
        for s in segments where s.duration > 0.001 {
            let speed = max(s.speed, 0.01)
            pieces.append(Piece(sourceStart: s.start, sourceEnd: s.end, outputStart: out, speed: speed))
            out += s.duration / speed
        }
        self.pieces = pieces
    }

    public var outputDuration: Double { pieces.last?.outputEnd ?? 0 }

    /// Källtiden som visas vid utdatatiden `t` (begränsad till filmens längd).
    public func source(at t: Double) -> Double {
        guard let first = pieces.first else { return t }
        if t <= 0 { return first.sourceStart }
        for p in pieces where t < p.outputEnd {
            return p.sourceStart + (t - p.outputStart) * p.speed
        }
        return pieces.last!.sourceEnd
    }

    /// Utdatatiden där källtiden `s` visas, eller nil om den är bortklippt.
    public func output(at s: Double) -> Double? {
        for p in pieces where s >= p.sourceStart && s <= p.sourceEnd {
            return p.outputStart + (s - p.sourceStart) / p.speed
        }
        return nil
    }

    /// Hastigheten vid utdatatiden `t`.
    public func speed(at t: Double) -> Double {
        pieces.first { t < $0.outputEnd }?.speed ?? 1
    }
}

/// Räknar om globala punkter (CoreGraphics-rymden som markördatan sparas i) till
/// normaliserade koordinater i skärmspåret: 0–1, origo uppe till vänster.
public struct ContentMapping: Sendable {
    public let pixelWidth: Double
    public let pixelHeight: Double
    let initialFrame: CGRect
    /// Fönsterramar över tid (bara fönsterinspelning), sorterade på tid.
    let frames: [(t: Double, rect: CGRect)]

    public init(meta: RecordingMeta, events: [InputEvent]) {
        pixelWidth = Double(max(meta.source.pixelWidth, 1))
        pixelHeight = Double(max(meta.source.pixelHeight, 1))
        initialFrame = meta.source.contentRect.cgRect
        frames = meta.source.kind == .window
            ? events.filter { $0.k == .frame }.compactMap { e in e.rect.map { (e.t, $0.cgRect) } }
            : []
    }

    public init(contentRect: CGRect, pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = Double(pixelWidth)
        self.pixelHeight = Double(pixelHeight)
        initialFrame = contentRect
        frames = []
    }

    func frame(at t: Double) -> CGRect {
        guard !frames.isEmpty else { return initialFrame }
        var current = initialFrame
        for f in frames {
            if f.t > t { break }
            current = f.rect
        }
        return current
    }

    /// Normaliserad punkt (kan hamna utanför 0–1 när markören är utanför innehållet).
    public func normalize(_ p: CGPoint, at t: Double) -> CGPoint {
        let f = frame(at: t)
        guard f.width > 0, f.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        // Innehållet skalas in i spårets pixlar med bibehållna proportioner, centrerat.
        let s = min(pixelWidth / f.width, pixelHeight / f.height)
        let offX = (pixelWidth - f.width * s) / 2
        let offY = (pixelHeight - f.height * s) / 2
        let px = (p.x - f.minX) * s + offX
        let py = (p.y - f.minY) * s + offY
        return CGPoint(x: px / pixelWidth, y: py / pixelHeight)
    }

    /// Normaliserad rektangel.
    public func normalize(_ r: CGRect, at t: Double) -> CGRect {
        let a = normalize(CGPoint(x: r.minX, y: r.minY), at: t)
        let b = normalize(CGPoint(x: r.maxX, y: r.maxY), at: t)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Hur många pixlar i spåret en punkt på skärmen motsvarar.
    public func pixelsPerPoint(at t: Double) -> Double {
        let f = frame(at: t)
        guard f.width > 0, f.height > 0 else { return 1 }
        return min(pixelWidth / f.width, pixelHeight / f.height)
    }
}
