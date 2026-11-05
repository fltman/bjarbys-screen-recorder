import Testing
import Foundation
@testable import RecorderKit

@Suite struct TypingZoomTests {
    // Innehållet 1000 × 500 punkter från origo.
    let mapping = ContentMapping(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 500), pixelWidth: 2000, pixelHeight: 1000)

    func typing(_ t: Double, x: Double? = 600, y: Double = 100) -> InputEvent {
        InputEvent(t: t, k: .typing, rect: x.map { Rect(x: $0, y: y, width: 8, height: 16) })
    }

    @Test func aBurstOfTypingZoomsOnTheCaretAndStandsStill() {
        let events = stride(from: 3.0, through: 5.0, by: 0.25).map { typing($0, x: 600 + ($0 - 3) * 40) }
        let zooms = AutoZoom.generate(events: events, mapping: mapping, duration: 20, scale: 2)
        #expect(zooms.count == 1)
        let z = zooms[0]
        #expect(abs(z.start - 2.6) < 1e-9 && abs(z.end - 6.2) < 1e-9)
        #expect(!z.followsCursor && z.isAuto)
        // Mitt i det som skrevs (600–688 punkter i sidled, raden vid 100–116).
        #expect(abs(z.centerX - 0.644) < 0.001)
        #expect(abs(z.centerY - 0.216) < 0.001)
        #expect(z.scale > 1.25 && z.scale <= 2)
    }

    @Test func withoutAccessibilityThereIsNoTypingZoom() {
        let events = stride(from: 3.0, through: 5.0, by: 0.25).map { typing($0, x: nil) }
        #expect(AutoZoom.generate(events: events, mapping: mapping, duration: 20, scale: 2).isEmpty)
    }

    @Test func aClickInTheFieldThenTypingBecomesOneStillZoom() {
        var events = [InputEvent(t: 2, k: .down, x: 610, y: 108, b: 0, n: 1)]
        events += stride(from: 3.5, through: 5.0, by: 0.25).map { typing($0) }
        let zooms = AutoZoom.generate(events: events, mapping: mapping, duration: 20, scale: 2)
        #expect(zooms.count == 1)
        #expect(abs(zooms[0].start - 1.4) < 1e-9 && !zooms[0].followsCursor)
    }

    @Test func separateBurstsGiveSeparateZooms() {
        let events = [3.0, 3.25, 3.5, 3.75].map { typing($0) } + [10.0, 10.25, 10.5].map { typing($0, x: 100, y: 400) }
        let zooms = AutoZoom.generate(events: events, mapping: mapping, duration: 20, scale: 2)
        #expect(zooms.count == 2)
        #expect(zooms[1].centerX < 0.2)
    }

    @Test func typingCountsAsActivityForDeadTime() {
        #expect(DeadTime.activity.contains(.typing) && DeadTime.activity.contains(.ink))
    }
}
