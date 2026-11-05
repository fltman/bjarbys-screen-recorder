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

@Suite struct BugReportTests {
    @Test func reportHasStepsEnvironmentAndAttachments() {
        let ev = [InputEvent(t: 2, k: .down, x: 1, y: 1, b: 0, n: 1),
                  InputEvent(t: 2, k: .element, label: "knapp «Spara»"),
                  InputEvent(t: 5, k: .key, label: "⌘S")]
        let words = [Transcript.Word(start: 1, end: 1.4, text: "Nu", startsSegment: true),
                     Transcript.Word(start: 1.5, end: 1.9, text: "sparar"), Transcript.Word(start: 2.0, end: 2.3, text: "jag."),
                     Transcript.Word(start: 5.5, end: 6, text: "Ingenting", startsSegment: true),
                     Transcript.Word(start: 6.1, end: 6.5, text: "händer.")]
        let guide = StepGuide(events: ev, words: words, timeMap: TimeMap(segments: [.init(start: 0, end: 10)]), language: "sv")
        let env = BugReport.Environment(macOS: "macOS 26.1.0", model: "Mac17,2", app: "Kundkoll", appVersion: "1.2 (34)")
        let md = BugReport.markdown(title: "Spara fungerar inte", guide: guide, environment: env,
                                    recordedAt: Date(timeIntervalSince1970: 0), duration: 10, video: "film.mp4", hasLog: true)
        #expect(md.hasPrefix("# Spara fungerar inte\n"))
        #expect(md.contains("## Vad som händer\n\nNu sparar jag. Ingenting händer."))
        #expect(md.contains("- Program: Kundkoll 1.2 (34)"))
        #expect(md.contains("1. Klicka på knapp «Spara». _(2.0 s)_ — Nu sparar jag."))
        #expect(md.contains("2. Tryck ⌘S. _(5.0 s)_ — Ingenting händer."))
        #expect(md.contains("[Systemlogg](logg.txt)") && md.contains("[Filmen](film.mp4)"))
    }
}
