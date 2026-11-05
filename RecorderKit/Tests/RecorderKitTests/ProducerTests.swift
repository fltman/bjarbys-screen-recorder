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
