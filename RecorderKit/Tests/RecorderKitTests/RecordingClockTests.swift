import Testing
import CoreMedia
@testable import RecorderKit

private func s(_ v: Double) -> CMTime { CMTime(seconds: v, preferredTimescale: 1_000_000) }

@Suite struct RecordingClockTests {
    @Test func dropsEverythingBeforeStart() {
        let c = RecordingClock()
        #expect(c.map(s(100)) == nil)
        c.startIfNeeded(at: s(100))
        #expect(c.map(s(99.9)) == nil)
        #expect(abs(c.map(s(101))!.seconds - 1) < 1e-6)
    }

    @Test func startIsSetOnlyOnce() {
        let c = RecordingClock()
        #expect(c.startIfNeeded(at: s(10)))
        #expect(!c.startIfNeeded(at: s(20)))
        #expect(abs(c.map(s(15))!.seconds - 5) < 1e-6)
    }

    @Test func pauseRemovesItsDurationAndDropsBuffersInside() {
        let c = RecordingClock()
        c.startIfNeeded(at: s(0))
        c.pause(at: s(10))
        #expect(c.map(s(11)) == nil, "under pågående paus")
        c.resume(at: s(14))
        // En sen buffert som fångades under pausen ska fortfarande kastas.
        #expect(c.map(s(12)) == nil)
        // Före pausen: oförändrat. Efter: fyra sekunder bortdragna.
        #expect(abs(c.map(s(9))!.seconds - 9) < 1e-6)
        #expect(abs(c.map(s(15))!.seconds - 11) < 1e-6)
    }

    @Test func multiplePausesAccumulate() {
        let c = RecordingClock()
        c.startIfNeeded(at: s(0))
        c.pause(at: s(5)); c.resume(at: s(7))
        c.pause(at: s(10)); c.resume(at: s(13))
        #expect(abs(c.map(s(20))!.seconds - 15) < 1e-6)
        #expect(abs(c.map(s(8))!.seconds - 6) < 1e-6)
    }
}
