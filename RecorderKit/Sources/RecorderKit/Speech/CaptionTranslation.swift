import Foundation

/// Undertexterna på ett annat språk: samma rader som originalet, med översatt text. Tiderna är
/// källtid, så att översättningen överlever klipp. Översättningen görs av producenten (Claude Code
/// via MCP: `get_caption_cues` → `set_caption_translation`) — Apples översättning på datorn har
/// ingen svenska, och KB-Whisper/turbo-modellen översätter inte (uppmätt).
public struct CaptionTranslation: Codable, Equatable, Sendable {
    public struct Cue: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = c.value(.start, 0); end = c.value(.end, 0); text = c.value(.text, "")
        }
    }
    /// Språkkod, t.ex. "en".
    public var language: String
    public var cues: [Cue]

    public init(language: String, cues: [Cue]) { self.language = language; self.cues = cues }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = c.value(.language, ""); cues = c.value(.cues, [])
    }

    /// Originalets rader i källtid (det som ska översättas).
    public static func sourceCues(_ words: [Transcript.Word], duration: Double) -> [Cue] {
        let identity = TimeMap(segments: [.init(start: 0, end: max(duration, words.last?.end ?? 0) + 1)])
        return Captions(words: words, timeMap: identity).cues.map {
            Cue(start: $0.start, end: $0.end, text: $0.text.replacingOccurrences(of: "\n", with: " "))
        }
    }
}

extension Captions {
    /// Översatta undertexter i filmens tid: en rad syns från där dess början finns kvar i filmen.
    public init(translation: CaptionTranslation, timeMap: TimeMap) {
        var out: [Cue] = []
        for c in translation.cues where !c.text.isEmpty {
            guard let a = timeMap.output(at: c.start) else { continue }
            let b = max(a + 0.3, timeMap.output(at: c.end) ?? (a + (c.end - c.start)))
            if let last = out.last, last.end > a { out[out.count - 1].end = a }
            // Samma radbrytning som originalet (en eller två jämna rader).
            let words = c.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            out.append(Cue(start: a, end: b, text: Captions.wrap(words)))
        }
        self.init(cues: out)
    }
}

extension RecordingBundle {
    public func translationURL(_ language: String) -> URL { url.appendingPathComponent("captions-\(language).json") }

    public func readTranslation(_ language: String) -> CaptionTranslation? {
        try? BundleJSON.read(CaptionTranslation.self, from: translationURL(language))
    }

    public func saveTranslation(_ t: CaptionTranslation) throws {
        try BundleJSON.write(t, to: translationURL(t.language))
    }

    /// Språken som finns översatta.
    public var translationLanguages: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasPrefix("captions-") && $0.hasSuffix(".json") }
            .map { String($0.dropFirst("captions-".count).dropLast(".json".count)) }
            .sorted()
    }
}

/// Undertextfilerna bredvid en export: `<namn>.srt` på det visade språket, och varje annat
/// språk (originalet och översättningarna) som `<namn>.<språk>.srt`.
public enum SubtitleFiles {
    @discardableResult
    public static func write(_ rec: LoadedRecording, project: EditProject, range: ClosedRange<Double>?, nextTo url: URL) -> [URL] {
        let map = TimeMap(segments: project.segments)
        let original = rec.transcript?.language.isEmpty == false ? rec.transcript!.language : "sv"
        var all: [(String, Captions)] = []
        if let words = rec.transcript?.words, !words.isEmpty { all.append((original, Captions(words: words, timeMap: map))) }
        for lang in rec.bundle.translationLanguages {
            if let t = rec.bundle.readTranslation(lang) { all.append((lang, Captions(translation: t, timeMap: map))) }
        }
        let shown = project.captions.language.isEmpty ? original : project.captions.language
        let base = url.deletingPathExtension()
        var written: [URL] = []
        for (lang, captions) in all where !captions.cues.isEmpty {
            let file = lang == shown ? base.appendingPathExtension("srt") : base.appendingPathExtension("\(lang).srt")
            let text = range.map { captions.srt(in: $0) } ?? captions.srt
            if (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil { written.append(file) }
        }
        return written
    }
}
