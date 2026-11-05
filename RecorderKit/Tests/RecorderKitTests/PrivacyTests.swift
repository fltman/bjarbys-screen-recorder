import Testing
import Foundation
import CoreGraphics
@testable import RecorderKit

@Suite struct SensitiveTextTests {
    private func kinds(_ s: String) -> [SensitiveText.Kind] { SensitiveText.matches(in: s).map(\.kind) }
    private func found(_ s: String) -> [String] { SensitiveText.matches(in: s).map { String(s[$0.range]) } }

    @Test func emails() {
        #expect(found("Skicka till anna.svensson+demo@exempel.se i dag") == ["anna.svensson+demo@exempel.se"])
        #expect(kinds("ingen adress här @ alls").isEmpty)
    }

    @Test func keysWithKnownPrefixes() {
        #expect(kinds("OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx") == [.secret])
        #expect(kinds("token ghp_abcdefghijklmnopqrstuvwxyz0123456789") == [.secret])
        #expect(kinds("AKIAIOSFODNN7EXAMPLE") == [.secret])
    }

    @Test func randomLookingWordsButNotPaths() {
        #expect(kinds("x-api-key: Zq8kP2mWv9Lr4Tn7Bx3Hc6Jd") == [.secret])
        #expect(kinds("/Users/anna/Projekt/bjarbys-screen-recorder/RecorderKit").isEmpty)
        #expect(kinds("CompositionBuilderVideoCompositionInstruction").isEmpty)
    }

    @Test func swedishPersonalNumbers() {
        #expect(kinds("Personnr 19850412-1234") == [.personalNumber])
        #expect(kinds("850412-1234") == [.personalNumber])
        #expect(kinds("Version 2026-11-05").isEmpty)
    }

    @Test func cardsNeedLuhn() {
        #expect(kinds("Kort 4111 1111 1111 1111 exp 12/29") == [.card])
        #expect(kinds("Order 4111 1111 1111 1112").filter { $0 == .card }.isEmpty)
    }

    @Test func phoneNumbers() {
        #expect(kinds("Ring 070-123 45 67") == [.phone])
        #expect(kinds("+46 70 123 45 67") == [.phone])
        #expect(kinds("Skärmen är 3024 pixlar bred").isEmpty)
    }

    @Test func hintNeverContainsTheText() {
        let h = SensitiveText.hint(.email, "anna@exempel.se")
        #expect(h.hasPrefix("a") && !h.contains("@") && !h.contains("exempel"))
    }
}

@Suite struct MaskTests {
    @Test func coversBothPositionsWhileTheTextMoves() {
        let a = Rect(x: 0.1, y: 0.5, width: 0.2, height: 0.03)
        let b = Rect(x: 0.1, y: 0.3, width: 0.2, height: 0.03)
        let m = EditProject.Mask(start: 0, end: 4, keyframes: [.init(t: 1, rect: a), .init(t: 2, rect: b)])
        #expect(m.rect(at: 0.5) == a.cgRect)
        let between = m.rect(at: 1.5)!
        #expect(between.contains(a.cgRect) && between.contains(b.cgRect))
        #expect(m.rect(at: 3) == b.cgRect)
        #expect(m.rect(at: 4.5) == nil)
    }

    @Test func linksTheSameTextAcrossFramesAndPadsTheEnds() {
        let hit = MaskScanner.Hit(kind: .email, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.02), text: "a@b.se")
        let other = MaskScanner.Hit(kind: .phone, rect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.02), text: "070-1234567")
        // Syns 2–5 s, missas av OCR vid 4 s; telefonnumret bara vid 8 s.
        let samples: [(t: Double, hits: [MaskScanner.Hit])] =
            [(0, []), (1, []), (2, [hit]), (3, [hit]), (4, []), (5, [hit]), (6, []), (7, []), (8, [other]), (9, [])]
        let masks = MaskScanner.link(samples, duration: 9.5)
        #expect(masks.count == 2)
        #expect(masks[0].kind == .email && masks[0].start == 1 && masks[0].end == 6)
        #expect(masks[1].kind == .phone && masks[1].start == 7 && masks[1].end == 9)
        #expect(!masks[0].hint.contains("@"))
    }

    @Test func masksDecodeFromEmpty() throws {
        _ = try BundleJSON.decoder.decode(EditProject.Mask.self, from: Data("{}".utf8))
        _ = try BundleJSON.decoder.decode(EditProject.Mask.Keyframe.self, from: Data("{}".utf8))
        let p = try BundleJSON.decoder.decode(EditProject.self, from: Data("{}".utf8))
        #expect(p.masks.isEmpty)
    }
}
