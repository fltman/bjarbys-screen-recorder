import Testing
import Foundation
@testable import RecorderKit

@Suite struct EventLogTests {
    @Test func writesAndReadsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try EventLogWriter(url: url)
        w.append(InputEvent(t: 0.5, k: .move, x: 10, y: 20))
        w.append(InputEvent(t: 1.0, k: .down, x: 11, y: 21, b: 0, n: 1))
        w.append(InputEvent(t: 1.2, k: .key, code: 1, label: "⌘S"))
        w.close()
        let events = EventLogReader.read(url)
        #expect(events.count == 3)
        #expect(events[1].k == .down && events[1].n == 1)
        #expect(events[2].label == "⌘S")
    }

    @Test func tornLastLineIsSkippedNotFatal() {
        let data = Data("""
        {"t":0.1,"k":"move","x":1,"y":2}
        {"t":0.2,"k":"down","x":1,"y":2,"b":0}
        {"t":0.3,"k":"mo
        """.utf8)
        let events = EventLogReader.parse(data)
        #expect(events.count == 2)
        #expect(events.last?.k == .down)
    }

    @Test func unknownKindIsKeptAsUnknown() {
        let events = EventLogReader.parse(Data(#"{"t":1,"k":"teleport","x":3}"#.utf8))
        #expect(events.count == 1)
        #expect(events[0].k == .unknown)
        #expect(events[0].x == 3)
    }

    @Test func outOfOrderLinesAreSorted() {
        let events = EventLogReader.parse(Data("{\"t\":2,\"k\":\"move\"}\n{\"t\":1,\"k\":\"move\"}\n".utf8))
        #expect(events.map(\.t) == [1, 2])
    }
}
