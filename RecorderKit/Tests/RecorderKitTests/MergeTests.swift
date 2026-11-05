import Testing
import Foundation
import AVFoundation
import CoreVideo
@testable import RecorderKit

/// Ihopslagning av tagningar: två små riktiga paket (skärmspår 64×36, 10 bilder/s) slås ihop.
@Suite struct MergeTests {
    /// Ett paket med `seconds` sekunder skärmspår, en klickhändelse i mitten och två ord.
    static func take(in dir: URL, seconds: Double, width: Int = 64, x: Double = 0, word: String) async throws -> RecordingBundle {
        let bundle = try RecordingBundle.create(in: dir, date: Date().addingTimeInterval(Double.random(in: 0..<1e6)))
        try FileManager.default.createDirectory(at: bundle.recordingDir, withIntermediateDirectories: true)
        let url = bundle.trackURL(.screen)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: 36])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: 36])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * 10)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var px: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &px)
            adaptor.append(px!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()

        var meta = RecordingMeta(source: .init(kind: .display, title: "prov", displayID: 0, windowID: nil,
                                               contentRect: Rect(x: x, y: 0, width: 32, height: 18), pixelScale: 2,
                                               pixelWidth: width, pixelHeight: 36),
                                 fps: 10, appVersion: "prov")
        meta.tracks = [.init(kind: .screen, file: RecordingBundle.fileName(for: .screen))]
        meta.duration = seconds
        meta.finished = true
        try bundle.writeMeta(meta)
        let log = try EventLogWriter(url: bundle.eventsURL)
        log.append(InputEvent(t: seconds / 2, k: .down, x: x + 10, y: 5, b: 0, n: 1))
        log.append(InputEvent(t: 0.1, k: .ink, pts: [0, x + 5, 5, 0.1, x + 15, 6]))
        log.close()
        try bundle.saveTranscript(Transcript(model: "prov", language: "sv", words: [
            .init(start: 0.1, end: 0.3, text: word), .init(start: 0.4, end: 0.6, text: word)]))
        return bundle
    }

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
    }

    @Test func takesFollowEachOther() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await Self.take(in: dir, seconds: 1.0, word: "a")
        let b = try await Self.take(in: dir, seconds: 1.5, x: 100, word: "b")
        let merged = try await RecordingMerger.merge([a, b], into: dir.appendingPathComponent("ut"))
        let meta = try merged.readMeta()
        #expect(abs(meta.duration - 2.5) < 1e-9)
        #expect(meta.finished)

        let asset = AVURLAsset(url: merged.trackURL(.screen), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2.5) < 0.11)

        // Klicken flyttade i tid; den andra tagningens punkt räknad mot den första tagningens ram.
        let downs = merged.readEvents().filter { $0.k == .down }
        #expect(downs.map(\.t) == [0.5, 1.75])
        #expect(downs.map { $0.x ?? -1 } == [10, 10])
        // Pennans punkter flyttas likadant.
        let ink = merged.readEvents().filter { $0.k == .ink }
        #expect(ink.map(\.t) == [0.1, 1.1])
        #expect(ink.map { $0.pts ?? [] } == [[0, 5, 5, 0.1, 15, 6], [0, 5, 5, 0.1, 15, 6]])
        // En ram vid andra tagningens början.
        #expect(merged.readEvents().contains { $0.k == .frame && $0.t == 1.0 })

        let words = merged.readTranscript()?.words ?? []
        #expect(words.map(\.text) == ["a", "a", "b", "b"])
        #expect(abs(words[2].start - 1.1) < 1e-9)
        #expect(words[2].startsSegment)
        // Originalen orörda.
        #expect(abs(try a.readMeta().duration - 1.0) < 1e-9)
    }

    @Test func refusesDifferentSizesAndSingleTakes() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await Self.take(in: dir, seconds: 0.5, word: "a")
        let b = try await Self.take(in: dir, seconds: 0.5, width: 48, word: "b")
        await #expect(throws: RecordingMerger.MergeError.self) { try await RecordingMerger.merge([a], into: dir) }
        await #expect(throws: RecordingMerger.MergeError.self) { try await RecordingMerger.merge([a, b], into: dir) }
    }
}
