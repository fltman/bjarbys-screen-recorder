import Testing
import Foundation
@testable import RecorderKit

@Suite struct CaptionTranslationTests {
    let translation = CaptionTranslation(language: "en", cues: [
        .init(start: 1, end: 3, text: "First line"),
        .init(start: 5, end: 7, text: "This one starts in a part that is cut away"),
        .init(start: 9, end: 11, text: "A rather long third line that should be wrapped into two even lines"),
    ])

    @Test func followsCutsAndWrapsLikeTheOriginal() {
        // Delar 0–4 och 8–12 kvar: rad 2 (5–7) är bortklippt, rad 3 hamnar på 5–7 i filmen.
        let captions = Captions(translation: translation, timeMap: TimeMap(segments: [.init(start: 0, end: 4), .init(start: 8, end: 12)]))
        #expect(captions.cues.count == 2)
        #expect(captions.cues[0].start == 1 && captions.cues[0].end == 3)
        #expect(captions.cues[1].start == 5 && captions.cues[1].end == 7)
        #expect(captions.cues[1].text.contains("\n"))
        #expect(captions.cue(at: 6)?.text.hasPrefix("A rather long") == true)
    }

    @Test func sourceCuesAreOneLineEach() {
        let words = (0..<12).map { Transcript.Word(start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.3, text: "ord\($0)") }
        let cues = CaptionTranslation.sourceCues(words, duration: 6)
        #expect(!cues.isEmpty && cues.allSatisfy { !$0.text.contains("\n") })
        #expect(cues.first?.start == 0)
    }

    @Test func decodesFromEmpty() throws {
        let t = try BundleJSON.decoder.decode(CaptionTranslation.self, from: Data("{}".utf8))
        #expect(t.cues.isEmpty && t.language.isEmpty)
        #expect(try BundleJSON.decoder.decode(EditProject.CaptionStyle.self, from: Data("{}".utf8)).language.isEmpty)
    }
}
