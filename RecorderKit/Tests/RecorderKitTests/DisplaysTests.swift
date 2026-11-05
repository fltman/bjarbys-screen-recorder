import Testing
import Foundation
@testable import RecorderKit

@Suite struct DisplaysTests {
    func meta() -> RecordingMeta {
        var m = RecordingMeta(source: .init(kind: .display, title: "Alla skärmar", displayID: 1, windowID: nil,
                                            contentRect: Rect(x: 0, y: 0, width: 1600, height: 540), pixelScale: 2,
                                            pixelWidth: 3200, pixelHeight: 1080), fps: 30, appVersion: "")
        m.displays = [.init(file: "screen-0.mov", title: "A", displayID: 1, contentRect: Rect(x: 0, y: 0, width: 960, height: 540),
                            pixelWidth: 1920, pixelHeight: 1080),
                      .init(file: "screen-1.mov", title: "B", displayID: 2, contentRect: Rect(x: 960, y: 100, width: 640, height: 360),
                            pixelWidth: 1280, pixelHeight: 720)]
        return m
    }

    @Test func displaysSitWhereTheyAreOnTheDesktop() {
        let rects = RenderPlan.displayRects(meta())
        // Core Image: origo nere till vänster; B ligger 100 pt (200 px) ned från överkanten.
        #expect(rects == [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 160, width: 1280, height: 720)])
    }

    @Test func oneDisplayHasNoLayout() {
        var m = meta(); m.displays = []
        #expect(RenderPlan.displayRects(m).isEmpty)
        let decoded = try? BundleJSON.decoder.decode(RecordingMeta.self, from: Data("{}".utf8))
        #expect(decoded?.displays.isEmpty == true)
    }

    @Test func aSmallerDisplayGetsAZoomThatFillsTheFrame() {
        var m = meta(); m.duration = 6
        // Markören i A (0–2 s), sedan i B (2,5–6 s).
        var events: [InputEvent] = []
        for i in 0..<120 {
            let t = Double(i) * 0.05
            events.append(InputEvent(t: t, k: .move, x: t < 2.2 ? 300 : 1300, y: 280))
        }
        let mapping = ContentMapping(meta: m, events: events)
        let cursor = CursorPath(events: events, mapping: mapping, duration: 6, style: .init())
        // 16:9 som fyller: höjden styr, 60 % av bredden syns.
        let zooms = RenderPlan.displayZooms(meta: m, cursor: cursor, visible: CGSize(width: 0.6, height: 1), avoiding: [])
        #expect(zooms.count == 1)
        let z = zooms[0]
        #expect(abs(z.scale - 1.5) < 1e-9 && abs(z.centerX - 0.8) < 1e-9 && abs(z.centerY - 280.0 / 540) < 1e-9)
        #expect(z.start > 1.8 && z.start < 2.6 && z.end > 5.8)
        // En egen zoom samtidigt går före.
        #expect(RenderPlan.displayZooms(meta: m, cursor: cursor, visible: CGSize(width: 0.6, height: 1),
                                        avoiding: [.init(start: 3, end: 4, scale: 2, centerX: 0.5, centerY: 0.5)]).isEmpty)
    }

    @Test func theCursorIsNormalizedOnTheWholeDesktop() {
        let mapping = ContentMapping(meta: meta(), events: [])
        let p = mapping.normalize(CGPoint(x: 1280, y: 280), at: 0)  // mitt i B
        #expect(abs(p.x - 0.8) < 1e-9 && abs(p.y - 280.0 / 540) < 1e-9)
    }
}
