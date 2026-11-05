import Foundation

/// En tidslinje för Final Cut Pro och DaVinci Resolve (FCPXML 1.10, som båda läser): den färdiga bilden som ett
/// klipp i huvudspåret, ljudet per källa som anslutna klipp under (med roller), kapitlen som
/// kapitelmarkörer och inspelningens markeringar som vanliga markörer. Allt i filmens tid, så att
/// det ligger som i exporten — det som inte går att uttrycka i FCPXML (zoom, markör, bakgrund)
/// är redan inritat i bilden.
public enum FCPXML {
    public struct Audio: Sendable {
        public var name: String
        public var url: URL
        /// dialogue, music eller effects.
        public var role: String
        public init(name: String, url: URL, role: String) { self.name = name; self.url = url; self.role = role }
    }

    public struct Marker: Sendable {
        public var time: Double
        public var title: String
        public var chapter: Bool
        public init(time: Double, title: String, chapter: Bool) { self.time = time; self.title = title; self.chapter = chapter }
    }

    /// Dokumentet. `video` är bilden (utan ljud), `duration` filmens längd i sekunder.
    public static func document(name: String, video: URL, size: CGSize, fps: Int, duration: Double,
                                audio: [Audio], markers: [Marker]) -> String {
        let frames = max(1, Int((duration * Double(fps)).rounded()))
        func t(_ seconds: Double) -> String {
            let f = Int((seconds * Double(fps)).rounded())
            return f == 0 ? "0s" : "\(f)/\(fps)s"
        }
        let dur = "\(frames)/\(fps)s"
        let w = Int(size.width), h = Int(size.height)
        var x: [String] = []
        x.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        x.append("<!DOCTYPE fcpxml>")
        x.append(#"<fcpxml version="1.10">"#)
        x.append("  <resources>")
        // Namnet bara för Final Cuts standardformat; andra storlekar (stående, kvadrat) anges
        // med bredd och höjd utan namn.
        let standard: Set<String> = ["1280x720", "1920x1080", "3840x2160"]
        let formatName = standard.contains("\(w)x\(h)") ? #" name="FFVideoFormat\#(h)p\#(fps)""# : ""
        x.append(#"    <format id="r1"\#(formatName) frameDuration="1/\#(fps)s" width="\#(w)" height="\#(h)" colorSpace="1-1-1 (Rec. 709)"/>"#)
        x.append(#"    <asset id="r2" name="\#(esc(name))" start="0s" duration="\#(dur)" hasVideo="1" format="r1" videoSources="1">"#)
        x.append(#"      <media-rep kind="original-media" src="\#(esc(video.absoluteString))"/>"#)
        x.append("    </asset>")
        for (i, a) in audio.enumerated() {
            x.append(#"    <asset id="r\#(i + 3)" name="\#(esc(a.name))" start="0s" duration="\#(dur)" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000">"#)
            x.append(#"      <media-rep kind="original-media" src="\#(esc(a.url.absoluteString))"/>"#)
            x.append("    </asset>")
        }
        x.append("  </resources>")
        x.append("  <library>")
        x.append(#"    <event name="Bjarbys skärminspelare">"#)
        x.append(#"      <project name="\#(esc(name))">"#)
        x.append(#"        <sequence format="r1" duration="\#(dur)" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">"#)
        x.append("          <spine>")
        x.append(#"            <asset-clip ref="r2" offset="0s" name="\#(esc(name))" start="0s" duration="\#(dur)" format="r1" tcFormat="NDF">"#)
        for (i, a) in audio.enumerated() {
            x.append(#"              <asset-clip ref="r\#(i + 3)" lane="-\#(i + 1)" offset="0s" name="\#(esc(a.name))" start="0s" duration="\#(dur)" audioRole="\#(a.role)"/>"#)
        }
        for m in markers.sorted(by: { $0.time < $1.time }) where m.time >= 0 && m.time < duration {
            let tag = m.chapter ? "chapter-marker" : "marker"
            let poster = m.chapter ? #" posterOffset="0s""# : ""
            x.append(#"              <\#(tag) start="\#(t(m.time))" duration="1/\#(fps)s" value="\#(esc(m.title))"\#(poster)/>"#)
        }
        x.append("            </asset-clip>")
        x.append("          </spine>")
        x.append("        </sequence>")
        x.append("      </project>")
        x.append("    </event>")
        x.append("  </library>")
        x.append("</fcpxml>")
        return x.joined(separator: "\n") + "\n"
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Ljudrollen för en grupp i exportens ljudspår.
    static func role(forStem key: String) -> String {
        switch key {
        case "mic", "narration": "dialogue"
        case "music": "music"
        default: "effects"
        }
    }
}
