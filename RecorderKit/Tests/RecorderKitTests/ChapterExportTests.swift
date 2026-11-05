import Testing
import Foundation
import AVFoundation
@testable import RecorderKit

@Suite struct ChapterExportTests {
    let track = OverlayTrack(overlays: [], chapters: [.init(at: 1, title: "Intro"), .init(at: 2.5, title: "Mitten"), .init(at: 4, title: "Slut")],
                             timeMap: TimeMap(segments: [.init(start: 0, end: 6)]))

    @Test func wholeFilmStartsWithStartWhenNothingRunsAtZero() {
        let list = track.chapterList(in: 0...6)
        #expect(list.map(\.title) == ["Start", "Intro", "Mitten", "Slut"])
        #expect(list.map(\.start) == [0, 1, 2.5, 4])
        #expect(list.map(\.end) == [1, 2.5, 4, 6])
    }

    @Test func excerptBeginsWithTheRunningChapter() {
        let list = track.chapterList(in: 2...5)
        #expect(list.map(\.title) == ["Intro", "Mitten", "Slut"])
        #expect(list.map(\.start) == [2, 2.5, 4])
        #expect(list.last?.end == 5)
        #expect(track.youtubeChapters(in: 2...5) == "0:00 Intro\n0:00 Mitten\n0:02 Slut")
    }

    @Test func noChaptersNoList() {
        let empty = OverlayTrack(overlays: [], chapters: [], timeMap: TimeMap(segments: [.init(start: 0, end: 6)]))
        #expect(empty.chapterList(in: 0...6).isEmpty)
    }

    @Test func chapterSampleIsLengthPrefixedUTF8() throws {
        let sample = try #require(Exporter.chapterSample("Å", from: 1, to: 2))
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
        #expect(bytes == [0, 2, 0xC3, 0x85])
        #expect(CMSampleBufferGetPresentationTimeStamp(sample).seconds == 1)
        #expect(CMSampleBufferGetDuration(sample).seconds == 1)
    }
}
