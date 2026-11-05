import Testing
import Foundation
@testable import RecorderKit

@Suite struct FlashbackPlanTests {
    // Tre delar à ~60 s som överlappar: nästa börjar 0,3 s innan föregående slutar.
    let segments: [FlashbackPlan.Segment] = [.init(start: 1000, duration: 60.3),
                                             .init(start: 1060, duration: 60.3),
                                             .init(start: 1120, duration: 30)]

    @Test func handsOverWhereTheNextSegmentStarts() {
        let p = FlashbackPlan.pieces(segments, from: 1030, to: 1150)
        #expect(p.count == 3)
        #expect(p[0] == .init(segment: 0, localStart: 30, localEnd: 60, output: 0))
        #expect(p[1] == .init(segment: 1, localStart: 0, localEnd: 60, output: 30))
        #expect(p[2] == .init(segment: 2, localStart: 0, localEnd: 30, output: 90))
        // Sammanhängande: varje bit börjar där förra slutade.
        for (a, b) in zip(p, p.dropFirst()) { #expect(abs(a.output + a.localEnd - a.localStart - b.output) < 1e-9) }
    }

    @Test func bufferOlderThanTheFirstSegmentStartsLater() {
        let p = FlashbackPlan.pieces(segments, from: 900, to: 1010)
        #expect(p.count == 1 && p[0].localStart == 0 && p[0].localEnd == 10 && p[0].output == 100)
    }

    @Test func aHoleBetweenSegmentsStaysAHole() {
        // Del 2 startade först 2 s efter att del 1 slutat (rotationen misslyckades en stund).
        let p = FlashbackPlan.pieces([.init(start: 0, duration: 10), .init(start: 12, duration: 10)], from: 0, to: 22)
        #expect(p.count == 2 && p[0].localEnd == 10 && p[1].output == 12)
    }

    @Test func metaRemembersTheHostTime() throws {
        let m = try BundleJSON.decoder.decode(RecordingMeta.self, from: Data(#"{"startHostTime":12345.5}"#.utf8))
        #expect(m.startHostTime == 12345.5)
        #expect(try BundleJSON.decoder.decode(RecordingMeta.self, from: Data("{}".utf8)).startHostTime == 0)
    }
}
