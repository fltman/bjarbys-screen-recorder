import Foundation
import CoreGraphics

/// Föreslår zoomar ur klicken. Förslagen är vanliga zoomsegment som användaren kan flytta,
/// ändra och ta bort; automatiken är en start, inte ett tvång.
public enum AutoZoom {
    /// Klick tätare än så hör till samma zoom.
    static let clusterGap = 2.5
    /// Zoomen börjar så här långt före första klicket, så att den hinner fram.
    static let lead = 0.6
    /// …och slutar så här långt efter sista.
    static let tail = 1.8
    /// Zoomar närmare varandra än så slås ihop i stället för att zooma ut och in igen.
    static let mergeGap = 1.0

    public static func generate(events: [InputEvent], mapping: ContentMapping, duration: Double,
                                scale: Double) -> [EditProject.ZoomSegment] {
        let downs = events.filter { $0.k == .down && $0.point != nil }
        guard !downs.isEmpty, scale > 1.01 else { return [] }
        // Elementramar loggas med klickets tid.
        var elements: [Double: CGRect] = [:]
        for e in events where e.k == .element {
            if let r = e.rect { elements[e.t] = mapping.normalize(r.cgRect, at: e.t) }
        }

        struct Cluster { var times: [Double]; var points: [CGPoint]; var elements: [CGRect] }
        var clusters: [Cluster] = []
        for d in downs {
            let p = mapping.normalize(d.point!, at: d.t)
            guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { continue }
            let el = elements[d.t]
            if var last = clusters.last, d.t - last.times.last! <= clusterGap {
                last.times.append(d.t); last.points.append(p)
                if let el { last.elements.append(el) }
                clusters[clusters.count - 1] = last
            } else {
                clusters.append(Cluster(times: [d.t], points: [p], elements: el.map { [$0] } ?? []))
            }
        }

        var zooms: [EditProject.ZoomSegment] = []
        for c in clusters {
            let start = max(0, c.times.first! - lead)
            let end = min(duration, c.times.last! + tail)
            guard end - start >= 1.0 else { continue }
            var center = CGPoint(x: c.points.map(\.x).reduce(0, +) / Double(c.points.count),
                                 y: c.points.map(\.y).reduce(0, +) / Double(c.points.count))
            var s = scale
            // Ett lagom stort element (knapp, fält) ramas in; stora element (hela fönster)
            // säger inget om var blicken ska vara.
            let useful = c.elements.filter { $0.width > 0.005 && $0.height > 0.005 && $0.width * $0.height < 0.15 }
            if let el = useful.first, c.points.count == 1 {
                center = CGPoint(x: el.midX, y: el.midY)
                s = min(scale, 0.7 / max(el.width, el.height))
            }
            s = max(1.25, s)
            if var last = zooms.last, start - last.end < mergeGap {
                last.end = end
                last.centerX = (last.centerX + center.x) / 2
                last.centerY = (last.centerY + center.y) / 2
                last.scale = min(last.scale, s)
                zooms[zooms.count - 1] = last
            } else {
                zooms.append(.init(start: start, end: end, scale: s, centerX: center.x, centerY: center.y,
                                   followsCursor: true, isAuto: true))
            }
        }
        return zooms
    }
}

/// Den virtuella kamerans bana: zoomgrad och mittpunkt över tiden, i 240 Hz på källans
/// tidslinje.
///
/// Inom en zoom står bilden still så länge markören håller sig inom de inre 70 procenten.
/// Lämnar den zonen tittar kameran en sekund framåt: kommer markören tillbaka hoppas
/// panoreringen över (ingen nervös kamera). Annars siktar den på markörens medelposition
/// under den kommande halvsekunden och glider dit med en överdämpad fjäder.
///
/// `visible` är hur stor del av innehållet som syns utan zoom, per axel. Normalt hela
/// (1 × 1). När innehållet fyller en bildyta med andra proportioner (Reel-läge) syns bara en
/// del, och då följer kameran markören även utan zoom (`followAtRest`).
public struct CameraPath: Sendable {
    public static let rate = 240.0
    static let safeZone = 0.7

    let scales: [Float]
    let xs: [Float]
    let ys: [Float]
    public let duration: Double

    public init(zooms: [EditProject.ZoomSegment], cursor: CursorPath, duration: Double,
                visible: CGSize = CGSize(width: 1, height: 1), followAtRest: Bool = false) {
        self.duration = max(duration, 0)
        let n = Int((self.duration * Self.rate).rounded(.up)) + 1
        let sorted = zooms.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let vis = CGSize(width: min(max(visible.width, 0.01), 1), height: min(max(visible.height, 0.01), 1))
        /// Halva det synliga fönstret per axel vid zoomen `s`.
        func halves(_ s: Double) -> CGSize {
            CGSize(width: 0.5 * vis.width / max(s, 1), height: 0.5 * vis.height / max(s, 1))
        }
        let follow = followAtRest && cursor.hasData
        let start = follow ? Self.clamp(cursor.position(at: 0), half: halves(1)) : CGPoint(x: 0.5, y: 0.5)
        var scales = [Float](repeating: 1, count: n)
        var xs = [Float](repeating: 0.5, count: n)
        var ys = [Float](repeating: 0.5, count: n)
        var scale = SpringFollower(1)
        var cx = SpringFollower(start.x)
        var cy = SpringFollower(start.y)
        var activeID: UUID?
        var focus = start
        let dt = 1 / Self.rate
        var k = 0
        for i in 0..<n {
            let t = Double(i) * dt
            while k < sorted.count && sorted[k].end <= t { k += 1 }
            let active = k < sorted.count && sorted[k].start <= t ? sorted[k] : nil
            let targetScale = active?.scale ?? 1
            let half = halves(targetScale)

            var tracking = false
            if let z = active {
                if z.id != activeID {
                    focus = CGPoint(x: z.centerX, y: z.centerY)
                    activeID = z.id
                }
                tracking = z.followsCursor && cursor.hasData
            } else {
                // Utan zoom: mitten, eller (Reel-läge) vidare efter markören därifrån den är.
                activeID = nil
                tracking = follow
                if !follow { focus = CGPoint(x: 0.5, y: 0.5) }
            }
            if tracking {
                let p = cursor.position(at: t)
                if !Self.inside(p, focus: focus, half: half) {
                    let ahead = cursor.position(at: t + 1.0)
                    if !Self.inside(ahead, focus: focus, half: half) {
                        var sx = 0.0, sy = 0.0
                        for s in 0..<10 {
                            let q = cursor.position(at: t + Double(s) * 0.05)
                            sx += q.x; sy += q.y
                        }
                        focus = CGPoint(x: sx / 10, y: sy / 10)
                    }
                }
            }
            focus = Self.clamp(focus, half: half)

            scale.step(toward: targetScale, dt: dt, spring: targetScale >= scale.position ? .zoomIn : .zoomOut)
            cx.step(toward: focus.x, dt: dt, spring: .viewport)
            cy.step(toward: focus.y, dt: dt, spring: .viewport)
            let s = max(scale.position, 1)
            let c = Self.clamp(CGPoint(x: cx.position, y: cy.position), half: halves(s))
            scales[i] = Float(s)
            xs[i] = Float(c.x)
            ys[i] = Float(c.y)
        }
        self.scales = scales; self.xs = xs; self.ys = ys
    }

    static func inside(_ p: CGPoint, focus: CGPoint, half: CGSize) -> Bool {
        abs(p.x - focus.x) <= half.width * safeZone && abs(p.y - focus.y) <= half.height * safeZone
    }

    static func clamp(_ p: CGPoint, half: CGSize) -> CGPoint {
        let hx = min(half.width, 0.5), hy = min(half.height, 0.5)
        return CGPoint(x: min(max(p.x, hx), 1 - hx), y: min(max(p.y, hy), 1 - hy))
    }

    /// Zoomgrad (≥ 1) och mittpunkt (normaliserad, origo uppe till vänster) vid källtiden `t`.
    public func viewport(at t: Double) -> (scale: Double, center: CGPoint) {
        guard !scales.isEmpty else { return (1, CGPoint(x: 0.5, y: 0.5)) }
        let f = max(0, min(t, duration)) * Self.rate
        let i = min(Int(f), scales.count - 1)
        let k = min(i + 1, scales.count - 1)
        let w = Float(f - Double(i))
        func lerp(_ a: [Float]) -> Double { Double(a[i] + (a[k] - a[i]) * w) }
        return (lerp(scales), CGPoint(x: lerp(xs), y: lerp(ys)))
    }
}
