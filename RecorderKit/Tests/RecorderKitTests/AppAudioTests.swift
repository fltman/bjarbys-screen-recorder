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

@Suite struct VideoInsertTests {
    @Test func cropSoftnessAndSpeedDefaults() throws {
        let o = try BundleJSON.decoder.decode(Overlay.self, from: Data(#"{"kind":"video","file":"v.mov"}"#.utf8))
        #expect(o.crop == nil && o.softness == 0 && o.speed == 1)
        var c = o
        c.crop = Rect(x: 0.25, y: 0, width: 0.5, height: 1); c.softness = 0.4; c.speed = 2
        let back = try BundleJSON.decoder.decode(Overlay.self, from: BundleJSON.encoder.encode(c))
        #expect(back.crop == c.crop && back.softness == 0.4 && back.speed == 2)
    }
}

@Suite struct StandardStyleTests {
    /// Utseendet följer med, innehållet aldrig.
    @Test func adoptStyleKeepsContent() throws {
        var source = try BundleJSON.decoder.decode(EditProject.self, from: Data("{}".utf8))
        source.padding = 0.2; source.cornerRadius = 0.05; source.aspect = .vertical; source.motionBlur = true
        source.background = EditProject.Background.presets[3]; source.camera.mirror.toggle()
        source.segments = [.init(start: 0, end: 9)]
        source.overlays = [Overlay(kind: .fact, at: 1, title: "Inte stil")]
        var target = EditProject.initial(duration: 4)
        target.zooms = [.init(start: 1, end: 2, scale: 2, centerX: 0.5, centerY: 0.5)]
        target.adoptStyle(of: source.styleOnly)
        #expect(target.padding == 0.2 && target.aspect == .vertical && target.motionBlur)
        #expect(target.background == source.background && target.camera == source.camera)
        #expect(target.segments.count == 1 && target.segments[0].end == 4)
        #expect(target.overlays.isEmpty && target.zooms.count == 1)
        #expect(target.hasSameStyle(as: source))
        let roundTrip = try JSONDecoder().decode(EditProject.self, from: JSONEncoder().encode(source.styleOnly))
        #expect(roundTrip.hasSameStyle(as: source) && roundTrip.overlays.isEmpty)
    }
}

@Suite struct OverlayAnimationTests {
    @Test func typewriterRevealsOverTime() throws {
        var o = Overlay(kind: .text, at: 0, title: "Hej världen")      // 11 tecken → 0,4 s (minimum)
        #expect(OverlayTrack.typewriterReveal(o, elapsed: 0) == nil)    // tona: ingen skrivmaskin
        o.animation = .typewriter
        #expect(OverlayTrack.typewriterReveal(o, elapsed: 0) == 0)
        #expect(OverlayTrack.typewriterReveal(o, elapsed: 0.2) == 5)
        #expect(OverlayTrack.typewriterReveal(o, elapsed: 0.5) == nil)  // allt syns
        var fact = Overlay(kind: .fact, at: 0, title: "Fakta"); fact.animation = .typewriter
        #expect(OverlayTrack.typewriterReveal(fact, elapsed: 0) == nil)  // bara text och rubrik
        let decoded = try BundleJSON.decoder.decode(Overlay.self, from: Data("{}".utf8))
        #expect(decoded.animation == .fade)
    }
}

@Suite struct SpeedUpTests {
    /// Ett intervall i 4× delar delen i kanterna; snitten får ingen övergång; filmen blir kortare.
    @Test func speedUpSplitsAndKeepsEverything() throws {
        var p = EditProject.initial(duration: 10)
        p.transition = .init(kind: .crossfade, duration: 0.5)
        p.setSpeed(4, in: 3...7)
        #expect(p.segments.map(\.start) == [0, 3, 7] && p.segments.map(\.end) == [3, 7, 10])
        #expect(p.segments.map(\.speed) == [1, 4, 1])
        #expect(p.segments[1].transitionIn?.kind == EditProject.Transition.Kind.none && p.segments[2].transitionIn?.kind == EditProject.Transition.Kind.none)
        #expect(abs(TimeMap(segments: p.segments).outputDuration - 7) < 1e-9)   // 3 + 1 + 3
    }
}
