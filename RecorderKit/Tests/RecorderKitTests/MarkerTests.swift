import Testing
import Foundation
@testable import RecorderKit

@Suite struct MarkerTests {
    @Test func splitsInsidePartsOnlyAndKeepsSpeed() {
        var p = EditProject()
        p.segments = [.init(start: 0, end: 10), .init(start: 12, end: 20, speed: 2)]
        p.split(at: [5, 11, 12.05, 15])
        #expect(p.segments.map(\.start) == [0, 5, 12, 15])
        #expect(p.segments.map(\.end) == [5, 10, 15, 20])
        #expect(p.segments.map(\.speed) == [1, 1, 2, 2])
        #expect(Set(p.segments.map(\.id)).count == 4)
    }

    @Test func chaptersAtMarkersSkipExistingOnes() {
        var p = EditProject()
        p.chapters = [Chapter(at: 10.4, title: "Mitten")]
        p.addChapters(at: [30, 2, 10], title: "Markering")
        #expect(p.chapters.map(\.at) == [2, 10.4, 30])
        #expect(p.chapters.map(\.title) == ["Markering 1", "Mitten", "Markering 2"])
    }

    @Test func markerEventsAreReadInOrder() throws {
        let e = try JSONDecoder().decode(InputEvent.self, from: Data(#"{"t":3.5,"k":"marker"}"#.utf8))
        #expect(e.k == .marker && e.t == 3.5)
    }
}
