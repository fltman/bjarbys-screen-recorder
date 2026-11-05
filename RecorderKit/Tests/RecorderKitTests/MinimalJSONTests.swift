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

@Suite struct ProjectJSONTests {
    @Test func editProjectFromEmpty() throws {
        let p = try BundleJSON.decoder.decode(EditProject.self, from: Data("{}".utf8))
        #expect(p.autoZoom && p.zoomScale == 2 && p.aspect == .wide)
        for type in [EditProject.ClipSegment.self, EditProject.ZoomSegment.self] as [any Decodable.Type] {
            _ = try BundleJSON.decoder.decode(type, from: Data("{}".utf8))
        }
        _ = try BundleJSON.decoder.decode(EditProject.Background.self, from: Data("{}".utf8))
        _ = try BundleJSON.decoder.decode(EditProject.CursorStyle.self, from: Data("{}".utf8))
        _ = try BundleJSON.decoder.decode(EditProject.CameraStyle.self, from: Data("{}".utf8))
        _ = try BundleJSON.decoder.decode(EditProject.AudioMix.self, from: Data("{}".utf8))
        let keys = try BundleJSON.decoder.decode(EditProject.ShortcutStyle.self, from: Data("{}".utf8))
        #expect(keys.visible && keys.position == .bottom && keys.size == 1)
        #expect(p.framing == .fit && p.shortcuts.visible)
        let caps = try BundleJSON.decoder.decode(EditProject.CaptionStyle.self, from: Data("{}".utf8))
        #expect(caps.visible && caps.size == 1)
        #expect(!p.audio.duckSystem && p.audio.duckLevel == 0.25)
        let t = try BundleJSON.decoder.decode(Transcript.self, from: Data("{}".utf8))
        #expect(t.words.isEmpty && t.track == .microphone)
        _ = try BundleJSON.decoder.decode(Transcript.Word.self, from: Data("{}".utf8))
    }

    @Test func unknownAspectFallsBack() throws {
        let p = try BundleJSON.decoder.decode(EditProject.self, from: Data(#"{"aspect":"cinemascope","padding":0.2}"#.utf8))
        #expect(p.aspect == .wide)
        #expect(p.padding == 0.2)
    }
}
