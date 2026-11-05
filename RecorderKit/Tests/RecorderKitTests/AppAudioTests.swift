import Testing
import Foundation
@testable import RecorderKit

@Suite struct AppAudioTests {
    @Test func choiceAndAppTrackFromEmptyJSON() throws {
        let c = try BundleJSON.decoder.decode(AudioSourceChoice.self, from: Data("{}".utf8))
        #expect(c.bundleID.isEmpty && c.pids.isEmpty)
        let t = try BundleJSON.decoder.decode(RecordingMeta.Track.self, from: Data(#"{"kind":"app","file":"app-0-0.mov"}"#.utf8))
        #expect(t.kind == .app && t.appID.isEmpty)
        let mix = try BundleJSON.decoder.decode(EditProject.AudioMix.self, from: Data("{}".utf8))
        #expect(mix.appVolumes.isEmpty && mix.appMuted.isEmpty)
        #expect(mix.appVolume("com.exempel.app") == EditProject.AudioMix.appDefault)
    }

    @Test func appTracksRoundTrip() throws {
        var m = RecordingMeta(source: .empty, fps: 60, appVersion: "t")
        m.tracks = [.init(kind: .system, file: "system-0.mov", deviceName: "Övrigt datorljud"),
                    .init(kind: .app, file: RecordingBundle.appFileName(0), deviceName: "Spotify", appID: "com.spotify.client"),
                    .init(kind: .app, file: RecordingBundle.appFileName(1), deviceName: "Chrome", failed: true, appID: "com.google.Chrome")]
        let back = try BundleJSON.decoder.decode(RecordingMeta.self, from: BundleJSON.encoder.encode(m))
        #expect(back.appTracks.map(\.appID) == ["com.spotify.client"])
        #expect(back.appTracks.first?.file == "app-0-0.mov")
    }

    @Test func choiceMatchesHelpersAndResponsibleApp() {
        let ps: [AudioProcesses.Process] = [
            .init(objectID: 1, pid: 10, bundleID: "com.google.Chrome", appBundleID: "com.google.Chrome", appName: "Chrome", isPlaying: false),
            .init(objectID: 2, pid: 11, bundleID: "com.google.Chrome.helper", appBundleID: "com.google.Chrome", appName: "Chrome", isPlaying: true),
            // Safaris ljud spelas i en WebKit-process som Safari ansvarar för.
            .init(objectID: 3, pid: 12, bundleID: "com.apple.WebKit.GPU", appBundleID: "com.apple.Safari", appName: "Safari", isPlaying: true),
            .init(objectID: 4, pid: 13, bundleID: "com.apple.WebKit.GPU", appBundleID: "com.apple.mail", appName: "Mail", isPlaying: false),
        ]
        #expect(AudioProcesses.objectIDs(for: .init(bundleID: "com.google.Chrome", name: "Chrome"), in: ps) == [1, 2])
        #expect(AudioProcesses.objectIDs(for: .init(bundleID: "com.apple.Safari", name: "Safari"), in: ps) == [3])
        #expect(AudioProcesses.objectIDs(for: .init(bundleID: "", name: "afplay", pids: [13]), in: ps) == [4])
    }
}
