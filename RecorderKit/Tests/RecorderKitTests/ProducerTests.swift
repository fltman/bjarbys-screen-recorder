import Testing
import Foundation
import CoreGraphics
@testable import RecorderKit

@Suite struct OverlayTrackTests {
    @Test func placedInOutputTimeAndFades() {
        let map = TimeMap(segments: [.init(start: 0, end: 4, speed: 2), .init(start: 6, end: 20)])
        let a = Overlay(kind: .fact, at: 2, duration: 3, title: "A")       // källtid 2 → ut 1
        let b = Overlay(kind: .qr, at: 5, duration: 3, url: "https://x.se") // bortklippt
        let track = OverlayTrack(overlays: [a, b], chapters: [], timeMap: map)
        #expect(track.placed.count == 1 && track.placed[0].start == 1 && track.placed[0].end == 4)
        #expect(track.visible(at: 0.9).isEmpty)
        let mid = track.visible(at: 2.5)
        #expect(mid.count == 1 && mid[0].opacity > 0.99)
        #expect((track.visible(at: 1.1).first?.opacity ?? 1) < 0.5)
        #expect((track.visible(at: 3.9).first?.opacity ?? 1) < 0.5)
    }

    @Test func chapterBannerAndYouTubeList() {
        let map = TimeMap(segments: [.init(start: 0, end: 100)])
        let chapters = [Chapter(at: 10, title: "Installera"), Chapter(at: 65, title: "Exportera")]
        let track = OverlayTrack(overlays: [], chapters: chapters, timeMap: map)
        #expect(track.chapterBanner(at: 11)?.title == "Installera")
        #expect(track.chapterBanner(at: 11)?.number == 1 && track.chapterBanner(at: 11)?.of == 2)
        #expect(track.chapterBanner(at: 20) == nil)
        #expect(track.youtubeChapters == "0:00 Start\n0:10 Installera\n1:05 Exportera")
    }

    @Test func decodeFromEmpty() throws {
        _ = try BundleJSON.decoder.decode(Overlay.self, from: Data("{}".utf8))
        _ = try BundleJSON.decoder.decode(Chapter.self, from: Data("{}".utf8))
        let clip = try BundleJSON.decoder.decode(AudioClip.self, from: Data("{}".utf8))
        #expect(clip.role == .narration && clip.volume == 1)
        let p = try BundleJSON.decoder.decode(EditProject.self, from: Data("{}".utf8))
        #expect(p.overlays.isEmpty && p.chapters.isEmpty && p.audioClips.isEmpty && p.showsChapterBanner)
    }

    @Test func renderingOverlaysDoesNotCrashAndFillsTheCanvas() {
        var meta = RecordingMeta(source: .init(kind: .display, title: "", displayID: 1, windowID: nil,
                                               contentRect: Rect(x: 0, y: 0, width: 1600, height: 1000),
                                               pixelScale: 1, pixelWidth: 1600, pixelHeight: 1000), fps: 60, appVersion: "t")
        meta.duration = 10
        var p = EditProject.initial(duration: 10)
        p.overlays = [Overlay(kind: .title, at: 0, duration: 3, title: "Så exporterar du", lines: ["På en minut"]),
                      Overlay(kind: .callout, at: 1, duration: 3, title: "Exportera", target: Rect(x: 0.8, y: 0.02, width: 0.1, height: 0.04)),
                      Overlay(kind: .fact, at: 1, duration: 3, title: "Tips", lines: ["⌘E exporterar"], corner: .bottomLeft),
                      Overlay(kind: .qr, at: 1, duration: 3, title: "Läs mer", url: "https://generativet.se")]
        p.chapters = [Chapter(at: 0.5, title: "Start")]
        let canvas = RenderPlan.canvasSize(aspect: .wide, source: CGSize(width: 1600, height: 1000), shortSide: 720)
        let plan = RenderPlan(canvas: canvas, project: p, meta: meta, events: [], cursors: CursorCatalog(),
                              cursorsDir: FileManager.default.temporaryDirectory, hasCamera: false)
        let screen = CIImageStub.solid(width: 1600, height: 1000)
        let image = plan.render(outputTime: 1.5, screen: screen, camera: nil)
        #expect(image.extent.size == canvas)
    }
}

import CoreImage
enum CIImageStub {
    static func solid(width: Int, height: Int) -> CIImage {
        CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.95)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

@Suite struct PreflightTests {
    private func w(_ s: Double, _ e: Double, _ t: String) -> Transcript.Word { .init(start: s, end: e, text: t) }

    @Test func catchesTheUsualMistakes() {
        var p = EditProject.initial(duration: 30)
        p.segments = [.init(start: 0, end: 10.25), .init(start: 15, end: 30)]
        p.overlays = [Overlay(kind: .fact, at: 12, duration: 3, title: "Bortklippt"),          // i klippt del
                      Overlay(kind: .qr, at: 2, duration: 4, url: "generativet.se"),           // utan https
                      Overlay(kind: .fact, at: 3, duration: 4, title: "Krock", corner: .topRight), // samma hörn som qr
                      Overlay(kind: .callout, at: 5, duration: 0.5, title: "Kort")]              // utan mål, för kort
        p.audioClips = [AudioClip(role: .narration, at: 16, file: "a.mp3", duration: 5),
                        AudioClip(role: .narration, at: 19, file: "b.mp3", duration: 3)]
        let words = [w(10.1, 10.5, "exportera"), w(17, 18, "hej")]
        let issues = Producer.preflight(project: p, words: words, duration: 30) { $0 != "b.mp3" }
        let errors = issues.filter { $0.severity == .error }.map(\.message)
        #expect(errors.contains { $0.contains("cut part") && $0.contains("Bortklippt") })
        #expect(errors.contains { $0.contains("http(s)") })
        #expect(errors.contains { $0.contains("same corner") })
        #expect(errors.contains { $0.contains("no target") })
        #expect(errors.contains { $0.contains("too short") })
        #expect(errors.contains { $0.contains("b.mp3 is missing") })
        #expect(errors.contains { $0.contains("runs into the next") })
        let warnings = issues.filter { $0.severity == .warning }.map(\.message)
        #expect(warnings.contains { $0.contains("inside the word «exportera»") })
        #expect(warnings.contains { $0.contains("talks over the recorded speech") })
    }

    @Test func cleanProjectPasses() {
        var p = EditProject.initial(duration: 20)
        p.overlays = [Overlay(kind: .title, at: 0, duration: 2.5, title: "Demo")]
        #expect(Producer.preflight(project: p, words: [], duration: 20).isEmpty)
    }
}

@Suite struct TransitionAndLayerTests {
    private func plan(_ p: EditProject) -> RenderPlan {
        var meta = RecordingMeta(source: .init(kind: .display, title: "", displayID: 1, windowID: nil,
                                               contentRect: Rect(x: 0, y: 0, width: 1600, height: 1000),
                                               pixelScale: 1, pixelWidth: 1600, pixelHeight: 1000), fps: 60, appVersion: "t")
        meta.duration = 20
        return RenderPlan(canvas: CGSize(width: 1920, height: 1080), project: p, meta: meta, events: [], cursors: CursorCatalog(),
                          cursorsDir: FileManager.default.temporaryDirectory, hasCamera: false)
    }

    @Test func transitionPeaksAtTheCutAndOnlyThere() {
        var p = EditProject.initial(duration: 20)
        p.segments = [.init(start: 0, end: 5), .init(start: 8, end: 20)]
        p.transition = .init(kind: .dip, duration: 0.6)
        let pl = plan(p)
        #expect(abs(pl.transitionAmount(at: 5) - 1) < 1e-9)
        #expect(abs(pl.transitionAmount(at: 5.15) - 0.5) < 1e-9)
        #expect(pl.transitionAmount(at: 5.4) == 0 && pl.transitionAmount(at: 1) == 0)
        p.transition.kind = .none
        #expect(plan(p).transitionAmount(at: 5) == 0)
    }

    @Test func textIsCenteredOnItsFramePoint() {
        var p = EditProject.initial(duration: 20)
        let o = Overlay(kind: .text, at: 1, title: "Hej", frame: Rect(x: 0.25, y: 0.25, width: 0.5, height: 0))
        p.overlays = [o]
        let f = plan(p).frame(of: o)!
        #expect(abs(f.midX - 480) < 1 && abs(f.midY - 810) < 1)   // 0,25 från toppen = 810 från botten
        #expect(f.width < 960 * 0.6, "plattan följer texten, inte största bredden")
    }

    @Test func formatDefaultsAndPreflightForNewKinds() throws {
        let t = try BundleJSON.decoder.decode(EditProject.Transition.self, from: Data("{}".utf8))
        #expect(t.kind == .none && t.duration == 0.5)
        var p = EditProject.initial(duration: 20)
        p.overlays = [Overlay(kind: .image, at: 1, file: "saknas.png"), Overlay(kind: .text, at: 2)]
        let errors = Producer.preflight(project: p, words: [], duration: 20) { _ in false }.map(\.message)
        #expect(errors.contains { $0.contains("saknas.png is missing") } && errors.contains { $0.contains("has no text") })
    }
}

@Suite struct CutPlanTests {
    @Test func perCutOverridesTheStandardAndNoneIsSkipped() {
        var segs: [EditProject.ClipSegment] = [.init(start: 0, end: 4), .init(start: 6, end: 9), .init(start: 12, end: 20)]
        segs[1].transitionIn = .init(kind: .crossfade, duration: 1)
        let plan = CutPlan(segments: segs, timeMap: TimeMap(segments: segs), standard: .init(kind: .dip, duration: 0.4))
        #expect(plan.cuts.map(\.transition.kind) == [.crossfade, .dip])
        #expect(plan.cuts[0].output == 4 && plan.cuts[1].output == 7)
        segs[2].transitionIn = .init(kind: .none)
        #expect(CutPlan(segments: segs, timeMap: TimeMap(segments: segs), standard: .init(kind: .dip)).cuts.count == 1)
    }

    @Test func crossfadeShowsTheOtherPartsRollInAndOut() {
        // Del A 0–4 i 1×, del B 6–9 i 2× (ut 4–5,5). Övertoning 1 s i snittet vid 4.
        var segs: [EditProject.ClipSegment] = [.init(start: 0, end: 4), .init(start: 6, end: 9, speed: 2)]
        segs[1].transitionIn = .init(kind: .crossfade, duration: 1)
        let cut = CutPlan(segments: segs, timeMap: TimeMap(segments: segs), standard: .init()).cuts[0]
        // Före snittet: B:s förrulle, i B:s hastighet (2×): 0,25 s före snittet = 0,5 s före B:s start.
        #expect(abs(cut.alternateSource(at: 3.75) - 5.5) < 1e-9)
        // Efter snittet: A:s efterrulle i 1×.
        #expect(abs(cut.alternateSource(at: 4.3) - 4.3) < 1e-9)
        let plan = CutPlan(segments: segs, timeMap: TimeMap(segments: segs), standard: .init())
        let mid = plan.active(at: 4)!
        #expect(abs(mid.amount - 1) < 1e-9 && abs(mid.progress - 0.5) < 1e-9)
        #expect(plan.active(at: 3.4) == nil && plan.active(at: 4.6) == nil)
    }

    @Test func transitionInDecodesAsNilFromOldProjects() throws {
        let s = try BundleJSON.decoder.decode(EditProject.ClipSegment.self, from: Data(#"{"start":1,"end":2}"#.utf8))
        #expect(s.transitionIn == nil)
    }
}
