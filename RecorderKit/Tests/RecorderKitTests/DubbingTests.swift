import Testing
import Foundation
import AVFoundation
@testable import RecorderKit

@Suite struct DubbingTests {
    @Test func linesStartWithTheOriginalWhenTheyFit() {
        let p = Dubbing.place(starts: [1.04, 2.34, 9.56], durations: [1.0, 5.2, 2.0], end: 24)
        #expect(p.map(\.at) == [1.04, 2.34, 9.56])
        #expect(p.allSatisfy { $0.speed == 1 && $0.lag == 0 && $0.overrun == 0 })
    }

    @Test func aLongLineDelaysTheNextThenSpeedsUp() {
        // Rad 1 får gå 0,6 s in i nästa rads tid; rad 2 börjar då efter en kort andning.
        let lag = Dubbing.place(starts: [0, 1.0], durations: [1.5, 1.0], end: 10)
        #expect(lag[0].speed == 1 && abs(lag[1].at - 1.6) < 1e-9 && abs(lag[1].lag - 0.6) < 1e-9)
        // Räcker inte det spelas raden fortare, högst 1,15×, och resten rapporteras.
        let fast = Dubbing.place(starts: [0, 1.0], durations: [2.0, 1.0], end: 10)
        #expect(fast[0].speed == Dubbing.maxSpeed)
        #expect(abs(fast[0].overrun - (2.0 / 1.15 - 1.6)) < 1e-9)
        let fits = Dubbing.place(starts: [0, 1.0], durations: [1.7, 1.0], end: 10)
        #expect(abs(fits[0].speed - 1.7 / 1.6) < 1e-9 && fits[0].overrun < 1e-9)
    }

    @Test func aLongLineStartsEarlierInTheSilenceBefore() {
        // Uppmätt fall: AI-upplysningen gjorde första raden 4,24 s, med 1,04 s tystnad före.
        let p = Dubbing.place(starts: [1.04, 2.34, 9.56], durations: [4.24, 3.92, 3.52], end: 24)
        #expect(abs(p[0].at - 0.24) < 1e-9 && abs(p[0].lag + 0.8) < 1e-9)
        // Bara så mycket tidigare som behövs, och aldrig in i föregående rad.
        let q = Dubbing.place(starts: [0, 2.0], durations: [1.0, 1.5], end: 3.6)
        #expect(q[1].at == 2.0)
        let r = Dubbing.place(starts: [0, 2.0], durations: [2.0, 2.0], end: 3.8)
        #expect(abs(r[1].at - (r[0].end + Dubbing.breath)) < 1e-9 && r[1].at < 2.0 + 0.2)
    }

    @Test func applyCopiesPlacesAndReplacesTheDub() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = RecordingBundle(url: dir.appendingPathComponent("prov.bsrec"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        try bundle.saveTranslation(CaptionTranslation(language: "en", cues: [
            .init(start: 1, end: 3, text: "Hello and welcome."),
            .init(start: 4, end: 6, text: "This line is skipped."),
            .init(start: 7, end: 9, text: "First we open the window."),
        ]))
        func tone(_ name: String, seconds: Double) throws -> String {
            let url = dir.appendingPathComponent(name)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 44_100))!
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
            return url.path
        }
        var project = EditProject.initial(duration: 12)
        project.audioClips = [AudioClip(role: .dub, at: 0, file: "gammal.mp3", duration: 1, language: "en"),
                              AudioClip(role: .narration, at: 0, file: "berattare.mp3", duration: 1)]
        let lines = try await Dubbing.apply(to: bundle, project: &project, duration: 12, language: "en",
                                            files: [try tone("a.caf", seconds: 1.5), "", try tone("c.caf", seconds: 1.2)],
                                            texts: ["This English voice is an AI. Hello and welcome.", "", ""], show: true)
        #expect(lines.count == 2)
        #expect(lines[0].text.hasPrefix("This English voice is an AI") && lines[1].text == "First we open the window.")
        let dubs = project.audioClips.filter { $0.role == .dub }
        #expect(dubs.map(\.file) == ["dub-en-01.caf", "dub-en-03.caf"])
        #expect(dubs.map(\.at) == [1, 7] && abs(dubs[0].duration - 1.5) < 0.01)
        #expect(project.audioClips.contains { $0.role == .narration })
        #expect(project.audio.voice == "en" && Dubbing.languages(project) == ["en"])
        #expect(FileManager.default.fileExists(atPath: bundle.mediaDir.appendingPathComponent("dub-en-03.caf").path))
        // Fel antal filer.
        await #expect(throws: Dubbing.DubError.self) {
            try await Dubbing.apply(to: bundle, project: &project, duration: 12, language: "en", files: [""], texts: [], show: false)
        }
    }

    @Test func oldProjectsDecode() throws {
        let clip = try BundleJSON.decoder.decode(AudioClip.self, from: Data(#"{"role":"narration","duration":2}"#.utf8))
        #expect(clip.speed == 1 && clip.language.isEmpty && clip.outputDuration == 2)
        #expect(try BundleJSON.decoder.decode(EditProject.AudioMix.self, from: Data("{}".utf8)).voice.isEmpty)
    }
}
