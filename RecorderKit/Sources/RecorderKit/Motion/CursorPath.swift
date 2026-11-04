import Foundation
import CoreGraphics

/// Markörens utjämnade bana, beräknad i förväg i 240 Hz på källans tidslinje. Både
/// förhandsvisning och export slår upp i samma tabell, så de blir exakt lika.
///
/// Pipeline: rå rörelse → skakfilter (< 2 punkter kastas) → fjäder mot senaste råa
/// positionen, med profil efter sammanhang: snabb nära ett klick (så att markören landar på
/// det som klickas), stadig under drag, annars standard.
public struct CursorPath: Sendable {
    public static let rate = 240.0

    public struct Click: Sendable, Equatable {
        public let t: Double
        public let point: CGPoint
        public let button: Int
    }

    let xs: [Float]
    let ys: [Float]
    let opacity: [Float]
    public let clicks: [Click]
    let cursorChanges: [(t: Double, id: String)]
    public let duration: Double
    public let hasData: Bool

    public init(events: [InputEvent], mapping: ContentMapping, duration: Double,
                style: EditProject.CursorStyle) {
        self.duration = max(duration, 0)
        let n = Int((self.duration * Self.rate).rounded(.up)) + 1

        // Råa punkter, normaliserade.
        var raw: [(t: Double, p: CGPoint)] = []
        var clicks: [Click] = []
        var drags: [ClosedRange<Double>] = []
        var dragStart: Double?
        var changes: [(Double, String)] = []
        var lastKept: CGPoint?
        for e in events {
            switch e.k {
            case .move, .drag, .down, .up:
                guard let gp = e.point else { continue }
                let p = mapping.normalize(gp, at: e.t)
                let threshold = 2 * mapping.pixelsPerPoint(at: e.t) / mapping.pixelWidth
                let isClick = e.k == .down || e.k == .up
                if let last = lastKept, !isClick,
                   abs(p.x - last.x) < threshold, abs(p.y - last.y) < threshold * mapping.pixelWidth / mapping.pixelHeight {
                    continue
                }
                raw.append((e.t, p))
                lastKept = p
                if e.k == .down {
                    clicks.append(Click(t: e.t, point: p, button: e.b ?? 0))
                    dragStart = e.t
                } else if e.k == .up, let s = dragStart {
                    if e.t - s > 0.15 { drags.append(s...e.t) }
                    dragStart = nil
                }
            case .cursor:
                if let id = e.cursor { changes.append((e.t, id)) }
            default:
                break
            }
        }
        self.clicks = clicks
        self.cursorChanges = changes
        self.hasData = !raw.isEmpty

        var xs = [Float](repeating: 0.5, count: n)
        var ys = [Float](repeating: 0.5, count: n)
        var opacity = [Float](repeating: raw.isEmpty ? 0 : 1, count: n)
        guard !raw.isEmpty else {
            self.xs = xs; self.ys = ys; self.opacity = opacity
            return
        }

        // Fjäderprofilerna skalas med utjämningen; ζ hålls konstant (c skalas med √m).
        let m = 3.0 + (0.45 - 3.0) * min(max(style.smoothing, 0), 1)
        func scaled(_ s: Spring) -> Spring {
            Spring(tension: s.tension * m, mass: s.mass, friction: s.friction * m.squareRoot())
        }
        let springDefault = scaled(.cursorDefault)
        let springSnappy = scaled(.cursorSnappy)
        let springDrag = scaled(.cursorDrag)
        let rawMode = style.smoothing < 0.03

        var fx = SpringFollower(raw[0].p.x)
        var fy = SpringFollower(raw[0].p.y)
        var j = 0             // index i raw för senaste punkten ≤ t
        var c = 0             // index i clicks
        var lastMove = raw[0].t
        let dt = 1 / Self.rate
        var shown: Float = 1
        var anchorIndex = 0
        for i in 0..<n {
            let t = Double(i) * dt
            while j + 1 < raw.count && raw[j + 1].t <= t {
                j += 1
                lastMove = raw[j].t
            }
            let target = raw[j].p
            if rawMode {
                // Linjär interpolation mellan råa punkter.
                let r = Self.interpolated(raw, at: t, hint: j)
                fx.position = r.x; fy.position = r.y
            } else {
                while c < clicks.count && clicks[c].t < t - 0.16 { c += 1 }
                let nearClick = c < clicks.count && abs(clicks[c].t - t) <= 0.16
                let inDrag = drags.contains { $0.contains(t) }
                let spring = nearClick ? springSnappy : (inDrag ? springDrag : springDefault)
                fx.step(toward: target.x, dt: dt, spring: spring)
                fy.step(toward: target.y, dt: dt, spring: spring)
            }
            var px = fx.position, py = fy.position
            if !rawMode {
                // En utjämnad markör släpar ~0,1 s efter. Runt varje klick glider den därför
                // över till den verkliga banan, så att den står exakt på klickpunkten när
                // klicket sker (annars hamnar klickringen bredvid markören).
                let w = Self.clickAnchorWeight(t, clicks: clicks, from: &anchorIndex)
                if w > 0 {
                    let r = Self.interpolated(raw, at: t, hint: j)
                    px += (r.x - px) * w
                    py += (r.y - py) * w
                }
            }
            xs[i] = Float(px)
            ys[i] = Float(py)

            if style.hideWhenIdle {
                // Tänds snabbt när markören rör sig, släcks långsamt efter 1,5 s stillhet.
                let idle = t - lastMove > 1.5
                let goal: Float = idle ? 0 : 1
                let rateUp = Float(dt / 0.15), rateDown = Float(dt / 0.35)
                shown = goal > shown ? min(goal, shown + rateUp) : max(goal, shown - rateDown)
                opacity[i] = shown
            }
        }
        self.xs = xs; self.ys = ys; self.opacity = opacity
    }

    /// Vikt 0–1 för hur mycket den verkliga banan ska gälla vid `t`: tonas in under 0,25 s
    /// före ett klick, är 1 till 0,1 s efter och tonas ut under 0,25 s.
    static func clickAnchorWeight(_ t: Double, clicks: [Click], from index: inout Int) -> Double {
        while index < clicks.count && clicks[index].t < t - 0.35 { index += 1 }
        var w = 0.0
        var k = index
        while k < clicks.count && clicks[k].t <= t + 0.25 {
            let d = t - clicks[k].t
            let v: Double
            if d < -0.25 { v = 0 }
            else if d < 0 { v = smoothstep((d + 0.25) / 0.25) }
            else if d <= 0.1 { v = 1 }
            else if d < 0.35 { v = 1 - smoothstep((d - 0.1) / 0.25) }
            else { v = 0 }
            w = max(w, v)
            k += 1
        }
        return w
    }

    static func smoothstep(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// Den råa banan, linjärt interpolerad, vid `t`. `hint` = index för senaste punkten ≤ t.
    /// En rörlig mus skickar händelser tätt (60–240 Hz). Ett längre glapp betyder att den
    /// stod still, och då ska läget hållas — inte glida mot nästa punkt i förväg.
    static let stillGap = 0.1

    static func interpolated(_ raw: [(t: Double, p: CGPoint)], at t: Double, hint j: Int) -> CGPoint {
        guard j + 1 < raw.count, raw[j].t <= t, raw[j + 1].t - raw[j].t <= stillGap else { return raw[j].p }
        let a = raw[j], b = raw[j + 1]
        let f = (t - a.t) / max(b.t - a.t, 1e-6)
        return CGPoint(x: a.p.x + (b.p.x - a.p.x) * f, y: a.p.y + (b.p.y - a.p.y) * f)
    }

    private func index(_ t: Double) -> (Int, Float) {
        let f = max(0, min(t, duration)) * Self.rate
        let i = min(Int(f), xs.count - 1)
        return (i, Float(f - Double(i)))
    }

    /// Normaliserad position (0–1, origo uppe till vänster).
    public func position(at t: Double) -> CGPoint {
        guard !xs.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let (i, f) = index(t)
        let k = min(i + 1, xs.count - 1)
        return CGPoint(x: Double(xs[i] + (xs[k] - xs[i]) * f), y: Double(ys[i] + (ys[k] - ys[i]) * f))
    }

    public func opacity(at t: Double) -> Double {
        guard !opacity.isEmpty else { return 0 }
        return Double(opacity[index(t).0])
    }

    /// Markörbilden som syns vid `t`.
    public func cursorID(at t: Double) -> String? {
        var id = cursorChanges.first?.id
        for change in cursorChanges {
            if change.t > t { break }
            id = change.id
        }
        return id
    }

    /// Klick vars effekt syns vid `t`, med hur långt effekten kommit (0–1).
    public func activeClicks(at t: Double, length: Double = 0.45) -> [(click: Click, progress: Double)] {
        clicks.compactMap { c in
            let p = (t - c.t) / length
            return p >= 0 && p <= 1 ? (c, p) : nil
        }
    }
}
