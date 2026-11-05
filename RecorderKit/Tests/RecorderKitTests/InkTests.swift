import Testing
import Foundation
@testable import RecorderKit

@Suite struct InkTests {
    let mapping = ContentMapping(contentRect: CGRect(x: 100, y: 0, width: 1000, height: 500), pixelWidth: 2000, pixelHeight: 1000)

    func event(_ json: String) throws -> InputEvent {
        try JSONDecoder().decode(InputEvent.self, from: Data(json.utf8))
    }

    @Test func strokeFromEventIsNormalizedInSourceTime() throws {
        let e = try event(##"{"t":2,"k":"ink","pts":[0,100,0, 0.5,600,250, 1,1100,500],"color":"#FFCC00"}"##)
        let track = InkTrack(events: [e], mapping: mapping)
        #expect(track.strokes.count == 1)
        let s = track.strokes[0]
        #expect(s.color == "#FFCC00")
        #expect(s.start == 2 && s.end == 3)
        #expect(s.points.map(\.p) == [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)])
    }

    @Test func drawsProgressivelyHoldsThenFades() throws {
        let e = try event(#"{"t":1,"k":"ink","pts":[0,100,0, 0.5,600,250, 1,1100,500]}"#)
        let track = InkTrack(events: [e], mapping: mapping)
        #expect(track.visible(at: 0.9, hold: 3).isEmpty)
        #expect(track.visible(at: 1.0, hold: 3).first?.count == 1)
        #expect(track.visible(at: 1.6, hold: 3).first?.count == 2)
        #expect(track.visible(at: 2.0, hold: 3).first?.count == 3)
        #expect(track.visible(at: 5.0, hold: 3).first?.opacity == 1)
        let fading = try #require(track.visible(at: 5.2, hold: 3).first)
        #expect(abs(fading.opacity - 0.5) < 1e-9)
        #expect(track.visible(at: 5.41, hold: 3).isEmpty)
        // Standardfärgen när färgen saknas.
        #expect(track.strokes[0].color == InkTrack.colors[0])
    }

    @Test func unknownKindStaysReadableAndInkRoundTrips() throws {
        let e = InputEvent(t: 1, k: .ink, pts: [0, 1, 2], color: "#FFFFFF")
        let back = try JSONDecoder().decode(InputEvent.self, from: JSONEncoder().encode(e))
        #expect(back == e)
        #expect(try event(#"{"t":1,"k":"laser"}"#).k == .unknown)
    }

    @Test func projectDefaultsShowInk() throws {
        let p = try JSONDecoder().decode(EditProject.self, from: Data("{}".utf8))
        #expect(p.showsInk && p.inkHold == InkTrack.standardHold)
    }
}
