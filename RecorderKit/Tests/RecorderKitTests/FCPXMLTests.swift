import Testing
import Foundation
@testable import RecorderKit

@Suite struct FCPXMLTests {
    func doc(size: CGSize = CGSize(width: 1920, height: 1080)) throws -> XMLDocument {
        let xml = FCPXML.document(name: "Demo & \"test\"", video: URL(fileURLWithPath: "/tmp/a b/Bild.mov"), size: size, fps: 60,
                                  duration: 6, audio: [.init(name: "Mikrofon", url: URL(fileURLWithPath: "/tmp/a b/01 Mikrofon.wav"), role: "dialogue"),
                                                       .init(name: "Musik", url: URL(fileURLWithPath: "/tmp/m.wav"), role: "music")],
                                  markers: [.init(time: 2.5, title: "Mitten <å>", chapter: true), .init(time: 1.5, title: "M1", chapter: false),
                                            .init(time: 9, title: "efter slutet", chapter: true)])
        return try XMLDocument(xmlString: xml)
    }

    @Test func isWellFormedWithTheClipsInPlace() throws {
        let d = try doc()
        let root = try #require(d.rootElement())
        #expect(root.attribute(forName: "version")?.stringValue == "1.10")
        let clips = try d.nodes(forXPath: "//spine/asset-clip")
        #expect(clips.count == 1)
        let connected = try d.nodes(forXPath: "//spine/asset-clip/asset-clip") as! [XMLElement]
        #expect(connected.map { $0.attribute(forName: "lane")?.stringValue } == ["-1", "-2"])
        #expect(connected.map { $0.attribute(forName: "audioRole")?.stringValue } == ["dialogue", "music"])
        #expect((try d.nodes(forXPath: "//sequence") as! [XMLElement]).first?.attribute(forName: "duration")?.stringValue == "360/60s")
    }

    @Test func markersInFramesAndEscaped() throws {
        let d = try doc()
        let chapters = try d.nodes(forXPath: "//chapter-marker") as! [XMLElement]
        #expect(chapters.map { $0.attribute(forName: "start")?.stringValue } == ["150/60s"])  // 9 s ligger efter slutet
        #expect(chapters.first?.attribute(forName: "value")?.stringValue == "Mitten <å>")
        let markers = try d.nodes(forXPath: "//marker") as! [XMLElement]
        #expect(markers.first?.attribute(forName: "start")?.stringValue == "90/60s")
        #expect((try d.nodes(forXPath: "//project") as! [XMLElement]).first?.attribute(forName: "name")?.stringValue == "Demo & \"test\"")
        let src = (try d.nodes(forXPath: "//media-rep") as! [XMLElement]).first?.attribute(forName: "src")?.stringValue
        #expect(src == "file:///tmp/a%20b/Bild.mov")
    }

    @Test func nonStandardSizesHaveNoFormatName() throws {
        let format = (try doc(size: CGSize(width: 1080, height: 1920)).nodes(forXPath: "//format") as! [XMLElement]).first
        #expect(format?.attribute(forName: "name") == nil)
        #expect(format?.attribute(forName: "width")?.stringValue == "1080")
        let standard = (try doc().nodes(forXPath: "//format") as! [XMLElement]).first
        #expect(standard?.attribute(forName: "name")?.stringValue == "FFVideoFormat1080p60")
    }
}
