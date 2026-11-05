import Foundation
import CoreGraphics

/// Ett streck som ritades på skärmen under inspelningen, i källtid och normaliserade punkter
/// (0–1, origo uppe till vänster i innehållet). Strecket var aldrig med i bilden — appens egna
/// fönster utesluts ur inspelningen — utan ritas i efterhand, så att det går att stänga av,
/// zoomar med innehållet och tonar bort som det gjorde på skärmen.
public struct InkStroke: Sendable, Identifiable, Equatable {
    public struct Point: Sendable, Equatable {
        public var t: Double
        public var p: CGPoint
        public init(t: Double, p: CGPoint) { self.t = t; self.p = p }
    }
    public let id: Int
    public let points: [Point]
    public let color: String
    public init(id: Int, points: [Point], color: String) { self.id = id; self.points = points; self.color = color }
    public var start: Double { points.first?.t ?? 0 }
    public var end: Double { points.last?.t ?? 0 }
}

public struct InkTrack: Sendable {
    public let strokes: [InkStroke]
    /// Hur länge en bortgång tar (s), samma som på skärmen.
    public static let fade = 0.4
    /// Hur länge ett färdigt streck ligger kvar på skärmen som standard (s).
    public static let standardHold = 3.0
    /// Streckets bredd i förhållande till innehållets höjd (≈ 7 px vid 1080 rader).
    public static let widthFraction = 0.007
    /// Färgerna som pennan kan ha (siffertangenterna 1–5 under ritandet).
    public static let colors = ["#FF3B30", "#FFCC00", "#34C759", "#0A84FF", "#FFFFFF"]

    public init(strokes: [InkStroke]) { self.strokes = strokes }

    public init(events: [InputEvent], mapping: ContentMapping) {
        var out: [InkStroke] = []
        for e in events where e.k == .ink {
            guard let pts = e.pts, pts.count >= 3 else { continue }
            var points: [InkStroke.Point] = []
            for i in stride(from: 0, to: pts.count - 2, by: 3) {
                let t = e.t + pts[i]
                points.append(.init(t: t, p: mapping.normalize(CGPoint(x: pts[i + 1], y: pts[i + 2]), at: t)))
            }
            out.append(InkStroke(id: out.count, points: points, color: e.color ?? Self.colors[0]))
        }
        strokes = out.sorted { $0.start < $1.start }
    }

    public var isEmpty: Bool { strokes.isEmpty }

    /// Strecken som syns vid källtiden `s`: hur många punkter som hunnit ritas och opaciteten.
    /// Ett streck syns från första punkten, ligger kvar `hold` s efter sista och tonar sedan bort.
    public func visible(at s: Double, hold: Double) -> [(stroke: InkStroke, count: Int, opacity: Double)] {
        var out: [(InkStroke, Int, Double)] = []
        for stroke in strokes {
            guard s >= stroke.start else { break }
            let gone = stroke.end + hold
            guard s < gone + Self.fade else { continue }
            let count = s >= stroke.end ? stroke.points.count
                : (stroke.points.lastIndex { $0.t <= s }.map { $0 + 1 } ?? 1)
            let opacity = s <= gone ? 1 : max(0, 1 - (s - gone) / Self.fade)
            out.append((stroke, count, opacity))
        }
        return out
    }

    /// En mjuk bana genom punkterna (kvadratiska kurvor genom mittpunkterna), i de koordinater
    /// `map` ger.
    public static func path(_ points: ArraySlice<InkStroke.Point>, map: (CGPoint) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        let p = points.map { map($0.p) }
        guard let first = p.first else { return path }
        path.move(to: first)
        if p.count == 1 {
            path.addLine(to: first)
            return path
        }
        if p.count == 2 { path.addLine(to: p[1]); return path }
        for i in 1..<(p.count - 1) {
            let mid = CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: p[i])
        }
        path.addLine(to: p[p.count - 1])
        return path
    }
}
