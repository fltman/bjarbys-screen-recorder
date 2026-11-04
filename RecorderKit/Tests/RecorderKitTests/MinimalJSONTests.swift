import Testing
import Foundation
@testable import RecorderKit

/// ⚠️ Varje typ som skrivs till disk ska gå att läsa ur `{}`. Annars blir gamla paket
/// oläsbara så fort ett fält läggs till (det hände tre gånger i Kundkoll).
@Suite struct MinimalJSONTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String = "{}") throws -> T {
        try BundleJSON.decoder.decode(type, from: Data(json.utf8))
    }

    @Test func recordingMeta() throws {
        let m = try decode(RecordingMeta.self)
        #expect(m.fps == 60)
        #expect(!m.finished)
        #expect(m.tracks.isEmpty)
    }

    @Test func nestedTypes() throws {
        _ = try decode(RecordingMeta.Source.self)
        _ = try decode(RecordingMeta.Track.self)
        _ = try decode(RecordingMeta.Gap.self)
        _ = try decode(CursorCatalog.self)
        _ = try decode(CursorCatalog.Entry.self)
        _ = try decode(InputEvent.self)
    }

    @Test func wrongTypeInOneFieldDoesNotLoseTheRest() throws {
        let m = try decode(RecordingMeta.self, #"{"fps":"sextio","duration":12.5,"finished":true}"#)
        #expect(m.fps == 60)
        #expect(m.duration == 12.5)
        #expect(m.finished)
    }

    @Test func roundTrip() throws {
        var m = RecordingMeta(source: .empty, fps: 30, appVersion: "t")
        m.tracks = [.init(kind: .microphone, file: "mic-0.mov", deviceName: "Mik")]
        m.gaps = [.init(start: 1, end: 2, reason: "x")]
        let data = try BundleJSON.encoder.encode(m)
        let back = try BundleJSON.decoder.decode(RecordingMeta.self, from: data)
        #expect(back.tracks == m.tracks)
        #expect(back.gaps == m.gaps)
        #expect(back.fps == 30)
    }

    @Test func rectEncodesAsArray() throws {
        let data = try JSONEncoder().encode(Rect(x: 1, y: 2, width: 3, height: 4))
        #expect(String(data: data, encoding: .utf8) == "[1,2,3,4]")
    }
}
