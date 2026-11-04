import Testing
import Foundation
import CoreGraphics
@testable import RecorderKit

@Suite struct SpringTests {
    static let regimes: [(String, Spring)] = [
        ("underdämpad", Spring(tension: 170, mass: 1, friction: 10)),
        ("kritisk", Spring(tension: 100, mass: 1, friction: 20)),
        ("överdämpad", .viewport),
    ]

    @Test(arguments: regimes.map(\.1))
    func startsAtInitialStateAndConverges(_ spring: Spring) {
        let s0 = spring.solve(displacement: 1, velocity: 0.5, t: 0)
        #expect(abs(s0.x - 1) < 1e-9 && abs(s0.v - 0.5) < 1e-9)
        let tiny = spring.solve(displacement: 1, velocity: 0.5, t: 1e-6)
        #expect(abs(tiny.x - 1) < 1e-5, "kontinuerlig vid t = 0")
        let late = spring.solve(displacement: 1, velocity: 0.5, t: 10)
        #expect(abs(late.x) < 1e-3 && abs(late.v) < 1e-2)
    }

    @Test func regimesAreClassifiedRight() {
        #expect(Spring(tension: 170, mass: 1, friction: 10).zeta < 1)
        #expect(abs(Spring(tension: 100, mass: 1, friction: 20).zeta - 1) < 1e-9)
        #expect(Spring.viewport.zeta > 1)
    }

    @Test func overdampedNeverOvershoots() {
        var t = 0.0
        while t < 5 {
            #expect(Spring.viewport.solve(displacement: 1, velocity: 0, t: t).x >= -1e-9)
            t += 0.01
        }
    }

    /// Velocity ska vara derivatan av läget.
    @Test(arguments: regimes.map(\.1))
    func velocityIsDerivative(_ spring: Spring) {
        for t in [0.05, 0.2, 0.7] {
            let h = 1e-6
            let a = spring.solve(displacement: 1, velocity: -2, t: t - h).x
            let b = spring.solve(displacement: 1, velocity: -2, t: t + h).x
            let v = spring.solve(displacement: 1, velocity: -2, t: t).v
            #expect(abs((b - a) / (2 * h) - v) < 1e-4)
        }
    }

    /// Kärnan i att lösa analytiskt: samma läge oavsett stegstorlek.
    @Test func frameRateIndependent() {
        func run(fps: Double) -> Double {
            var f = SpringFollower(0)
            let steps = Int(fps * 0.5)
            for _ in 0..<steps { f.step(toward: 1, dt: 1 / fps, spring: .cursorDefault) }
            return f.position
        }
        let a = run(fps: 30), b = run(fps: 60), c = run(fps: 120), d = run(fps: 240)
        #expect(abs(a - b) < 1e-9 && abs(b - c) < 1e-9 && abs(c - d) < 1e-9)
    }
}

@Suite struct TimeMapTests {
    @Test func cutsAndSpeed() {
        let map = TimeMap(segments: [
            .init(start: 0, end: 4),             // 0–4
            .init(start: 6, end: 10, speed: 2),  // 4–6
            .init(start: 12, end: 13),           // 6–7
        ])
        #expect(abs(map.outputDuration - 7) < 1e-9)
        #expect(abs(map.source(at: 2) - 2) < 1e-9)
        #expect(abs(map.source(at: 5) - 8) < 1e-9)
        #expect(abs(map.source(at: 6.5) - 12.5) < 1e-9)
        #expect(map.output(at: 5) == nil, "bortklippt")
        #expect(abs(map.output(at: 8)! - 5) < 1e-9)
        #expect(map.speed(at: 5) == 2)
    }

    @Test func clampsOutsideRange() {
        let map = TimeMap(segments: [.init(start: 1, end: 3)])
        #expect(map.source(at: -1) == 1)
        #expect(map.source(at: 99) == 3)
    }
}

@Suite struct ContentMappingTests {
    @Test func displayMapsLinearly() {
        let m = ContentMapping(contentRect: CGRect(x: 100, y: 50, width: 1000, height: 500), pixelWidth: 2000, pixelHeight: 1000)
        let p = m.normalize(CGPoint(x: 600, y: 300), at: 0)
        #expect(abs(p.x - 0.5) < 1e-9 && abs(p.y - 0.5) < 1e-9)
        #expect(abs(m.pixelsPerPoint(at: 0) - 2) < 1e-9)
    }
}

@Suite struct AutoZoomTests {
    private let mapping = ContentMapping(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                         pixelWidth: 1000, pixelHeight: 1000)

    private func click(_ t: Double, _ x: Double, _ y: Double) -> InputEvent {
        InputEvent(t: t, k: .down, x: x, y: y, b: 0, n: 1)
    }

    @Test func clustersNearbyClicksAndLeadsThem() {
        let events = [click(5, 200, 200), click(6, 220, 210), click(20, 800, 800)]
        let z = AutoZoom.generate(events: events, mapping: mapping, duration: 30, scale: 2)
        #expect(z.count == 2)
        #expect(abs(z[0].start - 4.4) < 1e-9, "börjar 0,6 s före första klicket")
        #expect(abs(z[0].end - 7.8) < 1e-9, "slutar 1,8 s efter sista")
        #expect(abs(z[0].centerX - 0.21) < 1e-9)
        #expect(z.allSatisfy { $0.isAuto })
    }

    @Test func mergesZoomsThatAlmostTouch() {
        // 3 s mellan klicken: två grupper, men zoomarna (…4,8) och (5,4…) ligger < 1 s isär.
        let z = AutoZoom.generate(events: [click(3, 100, 100), click(6, 900, 900)],
                                  mapping: mapping, duration: 30, scale: 2)
        #expect(z.count == 1)
    }

    @Test func elementFramesTheButton() {
        let events = [click(5, 510, 510),
                      InputEvent(t: 5, k: .element, rect: Rect(x: 480, y: 495, width: 100, height: 30))]
        let z = AutoZoom.generate(events: events, mapping: mapping, duration: 30, scale: 3)
        #expect(z.count == 1)
        #expect(abs(z[0].centerX - 0.53) < 1e-9 && abs(z[0].centerY - 0.51) < 1e-9)
        #expect(z[0].scale <= 3)
    }

    @Test func noZoomWhenScaleIsOne() {
        #expect(AutoZoom.generate(events: [click(5, 1, 1)], mapping: mapping, duration: 30, scale: 1).isEmpty)
    }
}

@Suite struct CameraPathTests {
    private let mapping = ContentMapping(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                         pixelWidth: 1000, pixelHeight: 1000)

    private func cursor(_ events: [InputEvent], duration: Double) -> CursorPath {
        CursorPath(events: events, mapping: mapping, duration: duration, style: .init())
    }

    @Test func zoomsInSettlesAndZoomsOut() {
        let z = EditProject.ZoomSegment(start: 2, end: 6, scale: 2, centerX: 0.3, centerY: 0.3, followsCursor: false)
        let path = CameraPath(zooms: [z], cursor: cursor([], duration: 10), duration: 10)
        #expect(abs(path.viewport(at: 1).scale - 1) < 1e-6)
        let mid = path.viewport(at: 5)
        #expect(abs(mid.scale - 2) < 0.01)
        #expect(abs(mid.center.x - 0.3) < 0.01 && abs(mid.center.y - 0.3) < 0.01)
        let after = path.viewport(at: 9.9)
        #expect(abs(after.scale - 1) < 0.01 && abs(after.center.x - 0.5) < 0.01)
    }

    @Test func viewportNeverLeavesTheContent() {
        let z = EditProject.ZoomSegment(start: 0.5, end: 3, scale: 3, centerX: 0.01, centerY: 0.99, followsCursor: false)
        let path = CameraPath(zooms: [z], cursor: cursor([], duration: 5), duration: 5)
        var t = 0.0
        while t < 5 {
            let v = path.viewport(at: t)
            let h = 0.5 / v.scale
            #expect(v.center.x - h >= -1e-6 && v.center.x + h <= 1 + 1e-6)
            #expect(v.center.y - h >= -1e-6 && v.center.y + h <= 1 + 1e-6)
            t += 0.01
        }
    }

    @Test func briefExcursionOutsideSafeZoneDoesNotPan() {
        // Markören står i mitten, gör en snabb utflykt till kanten och kommer tillbaka.
        var ev: [InputEvent] = [InputEvent(t: 0, k: .move, x: 500, y: 500)]
        ev.append(InputEvent(t: 3.0, k: .move, x: 950, y: 500))
        ev.append(InputEvent(t: 3.3, k: .move, x: 500, y: 500))
        let z = EditProject.ZoomSegment(start: 1, end: 8, scale: 2, centerX: 0.5, centerY: 0.5)
        let path = CameraPath(zooms: [z], cursor: cursor(ev, duration: 10), duration: 10)
        #expect(abs(path.viewport(at: 4).center.x - 0.5) < 0.02)
    }

    @Test func sustainedMoveOutsideSafeZonePans() {
        var ev: [InputEvent] = [InputEvent(t: 0, k: .move, x: 500, y: 500)]
        ev.append(InputEvent(t: 3.0, k: .move, x: 850, y: 500))
        let z = EditProject.ZoomSegment(start: 1, end: 8, scale: 2, centerX: 0.5, centerY: 0.5)
        let path = CameraPath(zooms: [z], cursor: cursor(ev, duration: 10), duration: 10)
        #expect(path.viewport(at: 6).center.x > 0.65)
    }
}

@Suite struct CursorPathTests {
    private let mapping = ContentMapping(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                         pixelWidth: 1000, pixelHeight: 1000)

    @Test func landsOnTheClick() {
        let ev = [InputEvent(t: 0, k: .move, x: 100, y: 100),
                  InputEvent(t: 1, k: .move, x: 800, y: 600),
                  InputEvent(t: 1.05, k: .down, x: 800, y: 600, b: 0)]
        let path = CursorPath(events: ev, mapping: mapping, duration: 3, style: .init())
        // En teleport på 700 px: fjädern är nära men inte exakt framme efter 0,2 s.
        let p = path.position(at: 1.25)
        #expect(abs(p.x - 0.8) < 0.03 && abs(p.y - 0.6) < 0.03)
        #expect(path.clicks.count == 1)
    }

    @Test func landsOnTheClickAfterRealisticMove() {
        // Jämn rörelse i 120 Hz under 0,5 s fram till klicket, som en riktig mus.
        var ev: [InputEvent] = []
        for i in 0...60 {
            let f = Double(i) / 60
            ev.append(InputEvent(t: 0.5 + f * 0.5, k: .move, x: 100 + 700 * f, y: 100 + 500 * f))
        }
        ev.append(InputEvent(t: 1.1, k: .down, x: 800, y: 600, b: 0))
        let path = CursorPath(events: ev, mapping: mapping, duration: 3, style: .init())
        let p = path.position(at: 1.1)
        #expect(abs(p.x - 0.8) < 0.01 && abs(p.y - 0.6) < 0.01)
    }

    /// Stilla mus följd av en ensam rörelse långt senare: markören ska stå kvar på
    /// klickpunkten, inte glida mot nästa punkt (uppmätt fel i första renderingen).
    @Test func holdsPositionAcrossLongGap() {
        let ev = [InputEvent(t: 0, k: .move, x: 900, y: 600),
                  InputEvent(t: 1.0, k: .down, x: 900, y: 600, b: 0),
                  InputEvent(t: 1.0, k: .up, x: 900, y: 600, b: 0),
                  InputEvent(t: 2.5, k: .move, x: 400, y: 550)]
        for smoothing in [0.0, 0.6] {
            let path = CursorPath(events: ev, mapping: mapping, duration: 4, style: .init(smoothing: smoothing))
            let p = path.position(at: 1.12)
            #expect(abs(p.x - 0.9) < 0.005 && abs(p.y - 0.6) < 0.005)
        }
    }

    @Test func hidesWhenIdle() {
        let ev = [InputEvent(t: 0, k: .move, x: 100, y: 100), InputEvent(t: 0.5, k: .move, x: 200, y: 100)]
        let path = CursorPath(events: ev, mapping: mapping, duration: 5, style: .init(hideWhenIdle: true))
        #expect(path.opacity(at: 1) > 0.99)
        #expect(path.opacity(at: 4) < 0.01)
    }

    @Test func rawModeFollowsExactly() {
        // Tät rörelse (60 Hz) från vänster till höger på en sekund.
        let ev = (0...60).map { i in InputEvent(t: Double(i) / 60, k: .move, x: 1000 * Double(i) / 60, y: 0) }
        let path = CursorPath(events: ev, mapping: mapping, duration: 2, style: .init(smoothing: 0))
        #expect(abs(path.position(at: 0.5).x - 0.5) < 0.01)
        #expect(abs(path.position(at: 0.508).x - 0.508) < 0.01)
    }
}

@Suite struct RenderPlanGeometryTests {
    private func plan(aspect: EditProject.Aspect, source: (Int, Int)) -> RenderPlan {
        var meta = RecordingMeta(source: .init(kind: .display, title: "", displayID: 1, windowID: nil,
                                               contentRect: Rect(x: 0, y: 0, width: Double(source.0), height: Double(source.1)),
                                               pixelScale: 1, pixelWidth: source.0, pixelHeight: source.1),
                                 fps: 60, appVersion: "t")
        meta.duration = 10
        var p = EditProject.initial(duration: 10)
        p.aspect = aspect
        let canvas = RenderPlan.canvasSize(aspect: aspect, source: CGSize(width: source.0, height: source.1), shortSide: 1080)
        return RenderPlan(canvas: canvas, project: p, meta: meta, events: [], cursors: CursorCatalog(),
                          cursorsDir: FileManager.default.temporaryDirectory, hasCamera: false)
    }

    @Test func verticalCanvasCentersLandscapeContentVertically() {
        let p = plan(aspect: .vertical, source: (1600, 1000))
        let c = p.coverageClamped(CGPoint(x: 0.9, y: 0.9), zoom: 2)
        #expect(abs(c.y - 0.5) < 1e-9, "täcker inte höjden: centrerat")
        #expect(c.x < 0.9 && c.x > 0.5, "täcker bredden: begränsat men följer")
    }

    @Test func zoomedContentNeverShowsBackgroundWhenItCovers() {
        let p = plan(aspect: .wide, source: (1920, 1080))
        let zoom = 3.0
        let c = p.coverageClamped(CGPoint(x: 0.99, y: 0.01), zoom: zoom)
        // Bildytans högra kant i innehållskoordinater ska ligga innanför innehållet.
        let rightEdge = c.x + p.canvas.width / (2 * p.screenRect.width * zoom)
        let topEdge = c.y - p.canvas.height / (2 * p.screenRect.height * zoom)
        #expect(rightEdge <= 1 + 1e-9 && topEdge >= -1e-9)
    }

    @Test func noZoomIsAlwaysCentered() {
        let p = plan(aspect: .wide, source: (1440, 900))
        let c = p.coverageClamped(CGPoint(x: 0.2, y: 0.8), zoom: 1)
        #expect(c == CGPoint(x: 0.5, y: 0.5))
    }
}
