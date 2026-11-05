import Testing
import Foundation
@testable import RecorderKit

@Suite struct FaceTrackTests {
    func face(_ x: Double) -> CGRect { CGRect(x: x - 0.1, y: 0.4, width: 0.2, height: 0.3) }

    @Test func gapsAreFilledWithTheNearestFind() {
        let raw: [(t: Double, face: CGRect?)] = [(0, nil), (0.25, face(0.3)), (0.5, nil), (0.75, nil), (1.0, face(0.3))]
        let s = FaceTrack.smooth(raw)
        #expect(s.count == 5)
        #expect(s.allSatisfy { abs($0.x - 0.3) < 1e-9 && abs($0.y - 0.55) < 1e-9 && abs($0.h - 0.3) < 1e-9 })
    }

    @Test func smoothingTakesTheJitterOut() {
        // Huvudet darrar ±0,05 varannan ruta; medelvärdet över ±3 prov ligger nära 0,5.
        let raw: [(t: Double, face: CGRect?)] = (0..<20).map { (Double($0) / 4, face($0 % 2 == 0 ? 0.55 : 0.45)) }
        let s = FaceTrack.smooth(raw)
        #expect(s[10].x > 0.48 && s[10].x < 0.52)
    }

    @Test func noFaceGivesAnEmptyTrack() {
        #expect(FaceTrack.smooth([(0, nil), (0.25, nil)]).isEmpty)
        #expect(FaceTrack(samples: []).center(at: 1) == nil)
    }

    @Test func centerInterpolatesAndHoldsAtTheEnds() {
        let t = FaceTrack(samples: [.init(t: 1, x: 0.2, y: 0.5, h: 0.3), .init(t: 2, x: 0.6, y: 0.7, h: 0.3)])
        #expect(t.center(at: 0) == CGPoint(x: 0.2, y: 0.5))
        let mid = t.center(at: 1.5)!
        #expect(abs(mid.x - 0.4) < 1e-9 && abs(mid.y - 0.6) < 1e-9)
        #expect(t.center(at: 9) == CGPoint(x: 0.6, y: 0.7))
    }

    @Test func decodesFromEmpty() throws {
        let t = try BundleJSON.decoder.decode(FaceTrack.self, from: Data("{}".utf8))
        #expect(t.samples.isEmpty)
        let c = try BundleJSON.decoder.decode(EditProject.CameraStyle.self, from: Data("{}".utf8))
        #expect(!c.followFace)
    }
}
