import Testing
import Foundation
@testable import RecorderKit

@Suite struct SpeechChunkTests {
    @Test func mapsJoinedTimesBackToTheRecording() {
        // Talet ur provet med Alva: 0,04–1,31, 1,41–4,51, 8,52–11,55 (s).
        let c = SpeechChunks(speech: [0.04...1.31, 1.41...4.51, 8.52...11.55], sampleRate: 16_000, total: 16_000 * 14)
        #expect(c.chunks.count == 3)
        let third = c.chunks[2]
        #expect(abs(third.joined - (1.27 + 0.4 + 3.10 + 0.4)) < 1e-9)
        // "Först" i tredje delen, 0,23 s in i den.
        #expect(abs(c.original(third.joined + 0.23) - 8.75) < 1e-9)
        // En tid i tystnaden mellan två delar hör till delen efter (whisper sätter gärna
        // början på ett ord i pausen före det).
        #expect(abs(c.original(c.chunks[0].joined + 1.27 + 0.2) - 1.41) < 1e-9)
        // Inom en given del stannar tiden i delen.
        #expect(abs(c.original(c.chunks[0].joined + 1.27 + 0.2, in: c.chunks[0]) - 1.31) < 1e-9)
        let joined = c.joined(from: [Float](repeating: 0.5, count: 16_000 * 14))
        #expect(abs(Double(joined.count) / 16_000 - (1.27 + 3.10 + 3.03 + 3 * 0.4)) < 0.001)
    }

    @Test func parsesTheVadToolsOutput() {
        let text = """
        Detected 2 speech segments:
        Speech segment 0: start = 4.00, end = 131.00
        Speech segment 1: start = 852.00, end = 1155.00
        """
        #expect(Transcriber.parseSpeechSegments(text) == [0.04...1.31, 8.52...11.55])
    }

    @Test func buildsWordsFromTokensAndDropsHallucinations() throws {
        let json = """
        {"transcription":[
          {"text":" Hej och välkommen!","tokens":[
            {"text":"[_BEG_]","offsets":{"from":0,"to":0}},
            {"text":" Hej","offsets":{"from":50,"to":180}},
            {"text":" väl","offsets":{"from":350,"to":600}},
            {"text":"kommen","offsets":{"from":600,"to":960}},
            {"text":"!","offsets":{"from":960,"to":1140}}]},
          {"text":" Tack.","tokens":[{"text":" Tack","offsets":{"from":2000,"to":2100}},{"text":".","offsets":{"from":2100,"to":2200}}]},
          {"text":" Först.","tokens":[
            {"text":" För","offsets":{"from":5000,"to":5100}},
            {"text":"st","offsets":{"from":5100,"to":5300}},
            {"text":" .","offsets":{"from":5300,"to":5350}}]}
        ]}
        """
        let chunks = SpeechChunks(speech: [0...4, 10...14], sampleRate: 16_000, total: 16_000 * 15)
        let words = try Transcriber.parse(Data(json.utf8), chunks: chunks, offset: 0.5)
        #expect(words.map(\.text) == ["Hej", "välkommen!", "Först."])
        #expect(words[0].startsSegment && !words[1].startsSegment && words[2].startsSegment)
        #expect(abs(words[1].start - (0.35 + 0.5)) < 1e-9 && abs(words[1].end - (0.96 + 0.5)) < 1e-9)
        // 5,0 s i den hopfogade filen = 0,6 s in i andra delen (som börjar vid 4,4) = 10,6 + 0,5.
        #expect(abs(words[2].start - 11.1) < 1e-9)
    }

    @Test func hallucinationFilter() {
        #expect(Hallucination.isNoise(" Tack."))
        #expect(Hallucination.isNoise("Textning av Jan Svensson"))
        #expect(Hallucination.isNoise("[Musik]"))
        #expect(Hallucination.isNoise("Ett stort stort stort stort stort hus"))
        #expect(!Hallucination.isNoise("Tack för att du tog dig tid."))
        #expect(!Hallucination.isNoise("Först klickar vi på knappen."))
    }

    @Test func fillerWords() {
        #expect(FillerWords.isFiller("Eh,") && FillerWords.isFiller("öhm") && !FillerWords.isFiller("ehrm-nej"))
    }
}

@Suite struct CaptionTests {
    private func words(_ spec: [(Double, Double, String)]) -> [Transcript.Word] {
        spec.enumerated().map { Transcript.Word(start: $1.0, end: $1.1, text: $1.2, startsSegment: $0 == 0) }
    }

    @Test func splitsOnPausesAndFollowsCuts() {
        let w = words([(1, 1.3, "Hej"), (1.35, 1.8, "och"), (1.85, 2.4, "välkommen."),
                       (5, 5.4, "Nu"), (5.45, 5.9, "börjar"), (5.95, 6.3, "vi.")])
        let full = Captions(words: w, timeMap: TimeMap(segments: [.init(start: 0, end: 10)]))
        #expect(full.cues.map(\.text) == ["Hej och välkommen.", "Nu börjar vi."])
        #expect(full.cue(at: 2.0)?.text == "Hej och välkommen.")
        #expect(full.cue(at: 4.0) == nil)
        // "och" bortklippt; resten flyttas fram i tid.
        let cut = Captions(words: w, timeMap: TimeMap(segments: [.init(start: 0, end: 1.32), .init(start: 1.83, end: 10)]))
        #expect(cut.cues.first?.text == "Hej välkommen.")
        #expect(abs((cut.cues.last?.start ?? 0) - (5 - 0.51)) < 1e-9)
    }

    @Test func wrapsLongTextIntoTwoEvenLines() {
        let text = Captions.wrap("Först klickar vi på knappen längst upp till höger i fönstret".split(separator: " ").map(String.init))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(abs(lines[0].count - lines[1].count) < 12)
    }

    @Test func srtAndVtt() {
        let w = words([(61.5, 62, "Hej."), (62.1, 62.5, "Du.")])
        let c = Captions(words: w, timeMap: TimeMap(segments: [.init(start: 0, end: 100)]))
        #expect(c.srt.hasPrefix("1\n00:01:01,500 --> 00:01:03,"))
        #expect(c.vtt.hasPrefix("WEBVTT\n\n00:01:01.500 --> "))
    }
}

@Suite struct SegmentEditingTests {
    @Test func cutAndRestoreRoundTrip() {
        var p = EditProject.initial(duration: 10)
        p.cut(2...3)
        p.cut(6...7)
        #expect(p.segments.map { [$0.start, $0.end] } == [[0, 2], [3, 6], [7, 10]])
        #expect(!p.isKept(2.5) && p.isKept(3.5))
        p.restore(2...3)
        #expect(p.segments.map { [$0.start, $0.end] } == [[0, 6], [7, 10]])
        // Delvis återställning från början av en lucka.
        p.restore(6...6.5)
        #expect(p.segments.map { [$0.start, $0.end] } == [[0, 6.5], [7, 10]])
    }

    @Test func restoreKeepsSpeedOfTheNeighbour() {
        var p = EditProject.initial(duration: 10)
        p.segments = [.init(start: 0, end: 4, speed: 2), .init(start: 6, end: 10, speed: 1)]
        p.restore(4...6)
        #expect(p.segments.count == 2)
        #expect(p.segments[0].end == 6 && p.segments[0].speed == 2)
    }

    @Test func restoreBeforeEverything() {
        var p = EditProject.initial(duration: 10)
        p.cut(0...2)
        p.restore(0...1)
        #expect(p.segments.map { [$0.start, $0.end] } == [[0, 1], [2, 10]])
        #expect(p.isKept(0.5) && !p.isKept(1.5))
    }
}

@Suite struct DeadTimeTests {
    @Test func findsTheQuietStartAndTheWait() {
        var ev: [InputEvent] = []
        // Musen rör sig 3–5 s och 12–14 s; tal 5–8 s.
        for t in stride(from: 3.0, through: 5.0, by: 0.05) { ev.append(InputEvent(t: t, k: .move, x: 1, y: 1)) }
        for t in stride(from: 12.0, through: 14.0, by: 0.05) { ev.append(InputEvent(t: t, k: .move, x: 1, y: 1)) }
        let dead = DeadTime.find(events: ev, speech: [5...8], duration: 17, minimum: 2, keep: 0.4)
        #expect(dead.count == 3)
        #expect(abs(dead[0].lowerBound) < 1e-9 && abs(dead[0].upperBound - (2.9 - 0.4)) < 1e-6)
        #expect(abs(dead[1].lowerBound - 8.4) < 1e-6 && abs(dead[1].upperBound - (11.9 - 0.4)) < 1e-6)
        #expect(abs(dead[2].lowerBound - (14.1 + 0.4)) < 1e-6 && dead[2].upperBound == 17)
    }

    @Test func shortPausesStay() {
        let ev = [InputEvent(t: 1, k: .down, x: 0, y: 0), InputEvent(t: 2.5, k: .down, x: 0, y: 0)]
        #expect(DeadTime.find(events: ev, speech: [], duration: 3.5, minimum: 2).isEmpty)
    }
}

@Suite struct DuckingTests {
    @Test func dipsAroundSpeechAndHoldsThroughShortPauses() {
        let ramps = Ducking.ramps(speech: [2...4, 4.8...6, 12...13], level: 0.2, normal: 0.8)
        // 2–6 blir en sänkning (pausen 0,8 s), 12–13 en till.
        #expect(ramps.count == 4)
        #expect(ramps[0] == .init(start: 1.75, end: 2, from: 0.8, to: 0.2))
        #expect(ramps[1] == .init(start: 6, end: 6.5, from: 0.2, to: 0.8))
        #expect(abs(ramps[2].start - 11.75) < 1e-9)
        // Ramperna får inte överlappa (AVAudioMix kräver det).
        for (a, b) in zip(ramps, ramps.dropFirst()) { #expect(a.end <= b.start) }
    }

    @Test func speechAtTheVeryStartRampsFromZero() {
        let ramps = Ducking.ramps(speech: [0.1...1], level: 0.2, normal: 1)
        #expect(ramps.first?.start == 0)
    }
}

@Suite struct LoudnessTests {
    /// 1 kHz-sinus: K-viktningen är ~0 dB där, så LUFS ≈ RMS i dBFS − 0,691 + 0,7 (filtret).
    /// Referens: ffmpeg `ebur128` gav −41,1 LUFS för en sinus med toppen −38,05 dBFS.
    @Test func sineMatchesFfmpegReference() {
        let amplitude = pow(10, -38.05 / 20)
        let samples = (0..<(48_000 * 5)).map { Float(amplitude * sin(2 * .pi * 1000 * Double($0) / 48_000)) }
        let lufs = Loudness.integrated(samples)
        #expect(lufs.map { abs($0 - (-41.07)) < 0.1 } == true)
    }

    @Test func silenceIsNotMeasured() {
        #expect(Loudness.integrated([Float](repeating: 0, count: 48_000 * 2)) == nil)
    }

    @Test func gainHitsTheTargetForStereoUnlessPeaksStopIt() {
        // Uppmätt: −32,37 LUFS mono → +13,36 dB → exporten mätte −16,0 LUFS i ffmpeg.
        let quiet = Loudness.gain(for: .init(integrated: -32.37, peak: pow(10, -16.85 / 20)))
        #expect(abs(20 * log10(quiet.gain) - 13.36) < 0.01 && !quiet.limitedByPeaks)
        let peaky = Loudness.gain(for: .init(integrated: -40, peak: pow(10, -6 / 20)))
        #expect(abs(20 * log10(peaky.gain) - 5) < 0.01 && peaky.limitedByPeaks)
    }
}
