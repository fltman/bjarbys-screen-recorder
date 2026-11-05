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
    @Test func onlyMultilingualModelsTranslate() {
        #expect(WhisperSetup.canTranslate("ggml-medium.bin"))
        #expect(WhisperSetup.canTranslate("ggml-large-v3-q5_0.bin"))
        // Uppmätt: KB-Whisper och turbo skriver svenska med -tr; .en förstår bara engelska.
        #expect(!WhisperSetup.canTranslate("kb_whisper_ggml_medium.bin"))
        #expect(!WhisperSetup.canTranslate("ggml-large-v3-turbo.bin"))
        #expect(!WhisperSetup.canTranslate("ggml-medium.en.bin"))
        #expect(!WhisperSetup.canTranslate("ggml-silero-v5.1.2.bin"))
        let here = ["ggml-large-v3-turbo.bin", "ggml-medium.bin", "ggml-medium.en.bin", "kb_whisper_ggml_medium.bin"]
        #expect(WhisperSetup.translationModel(among: here) == "ggml-medium.bin")
        #expect(WhisperSetup.translationModel(among: ["kb_whisper_ggml_small.bin", "ggml-large-v3-turbo.bin"]) == nil)
    }

    /// whisper-cli:s segment (-tr -ojf) → rader i inspelningens tid. Taldelar i originalet:
    /// 0,5–4,0 och 5,6–9,0 → i den hopfogade filen 0–3,5 och 3,9–7,3 (0,4 s tystnad emellan).
    @Test func translatedSegmentsMapBackThroughTheSpeechParts() throws {
        let json = """
        {"transcription":[
          {"text":" Hello and welcome.","offsets":{"from":0,"to":3700},"tokens":[]},
          {"text":" [Music]","offsets":{"from":3700,"to":3800},"tokens":[]},
          {"text":" First we open the export window.","offsets":{"from":3700,"to":7300},"tokens":[]}]}
        """
        let chunks = SpeechChunks(speech: [0.5...4.0, 5.6...9.0], sampleRate: 16_000, total: 16_000 * 10)
        let cues = try Transcriber.translatedCues(Data(json.utf8), chunks: chunks, offset: 0.25, words: [])
        #expect(cues.map(\.text) == ["Hello and welcome.", "First we open the export window."])
        // Slutet i pausen hör till delen före (4,0), början i pausen till delen efter (5,6).
        #expect(abs(cues[0].start - 0.75) < 1e-9 && abs(cues[0].end - 4.25) < 1e-9)
        #expect(abs(cues[1].start - 5.85) < 1e-9 && abs(cues[1].end - 9.25) < 1e-9)

        // Med transkriptet fästs gränserna vid originalets ord (inom 0,8 s).
        let words = [Transcript.Word(start: 0.9, end: 1.3, text: "Hej"), Transcript.Word(start: 3.0, end: 4.1, text: "välkommen."),
                     Transcript.Word(start: 6.2, end: 6.6, text: "Först"), Transcript.Word(start: 8.0, end: 8.7, text: "exportfönstret.")]
        let snapped = try Transcriber.translatedCues(Data(json.utf8), chunks: chunks, offset: 0.25, words: words)
        #expect(snapped.map(\.start) == [0.9, 6.2] && snapped.map(\.end) == [4.1, 8.7])
    }

    /// Det uppmätta fallet: whisper bröt «… with a» | «chapter. First …» och det andra segmentet
    /// gick över en paus. Taldelar 1,0–7,3 och 9,5–14,0 → hopfogat 0–6,3 och 6,7–11,2.
    @Test func sentencesAreRejoinedAndSnappedToThePause() throws {
        let json = """
        {"transcription":[
          {"text":" Hello and welcome. In this film I show how to export a recording with a","offsets":{"from":0,"to":5800},"tokens":[]},
          {"text":" chapter. First we open the export window.","offsets":{"from":5800,"to":11000},"tokens":[]}]}
        """
        let chunks = SpeechChunks(speech: [1.0...7.3, 9.5...14.0], sampleRate: 16_000, total: 16_000 * 15)
        let cues = try Transcriber.translatedCues(Data(json.utf8), chunks: chunks, offset: 0, words: [])
        #expect(cues.map(\.text) == ["Hello and welcome.", "In this film I show how to export a recording with a chapter.",
                                      "First we open the export window."])
        #expect(abs(cues[0].start - 1.0) < 1e-9)
        // Meningen före pausen slutar där talet slutar; nästa börjar där talet tar vid.
        #expect(abs(cues[1].end - 7.3) < 1e-9 && abs(cues[2].start - 9.5) < 1e-9 && abs(cues[2].end - 14.0) < 1e-9)
        #expect(CaptionTranslation.sentences("One. Two? Three") == ["One.", "Two?", "Three"])
        #expect(CaptionTranslation.endsSentence("done.»") && !CaptionTranslation.endsSentence("with a"))
    }

    @Test func longTranslatedSentencesSplitIntoReadableLines() {
        let text = "Then we click on the button at the bottom right, and the movie is saved in the movie folder where you can find it later."
        let words = [Transcript.Word(start: 12.8, end: 13.2, text: "och")]
        let cues = CaptionTranslation.pieces(text, start: 10, end: 16, words: words)
        #expect(cues.count == 2)
        #expect(cues.allSatisfy { $0.text.count <= Captions.lineLength * 2 })
        #expect(cues[0].text.hasSuffix("right,"))
        #expect(cues.map(\.text).joined(separator: " ") == text)
        // Gränsen fäst vid ett ord som börjar i originalet, raderna kant i kant.
        #expect(cues[0].start == 10 && cues[0].end == 12.8 && cues[1].start == 12.8 && cues[1].end == 16)
        #expect(CaptionTranslation.pieces("Short.", start: 1, end: 2, words: []).count == 1)
    }
}
