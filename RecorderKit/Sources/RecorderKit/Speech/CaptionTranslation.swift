import Foundation

/// Undertexterna på ett annat språk, med tiderna i källtid så att översättningen överlever klipp.
/// Två vägar: producenten (Claude Code via MCP: `get_caption_cues` → `set_caption_translation`,
/// samma rader som originalet, vilket språk som helst) eller whisper på datorn
/// (`Transcriber.translate`, bara till engelska, med en flerspråkig modell som ggml-medium).
/// Apples översättning på datorn har ingen svenska (uppmätt).
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

    /// Slutar texten en mening?
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'”’)»")).last else { return true }
        return ".!?…".contains(last)
    }

    /// Texten delad efter varje mening (skiljetecknet följer med).
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for w in text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) {
            current.append(w)
            if endsSentence(w) { out.append(current.joined(separator: " ")); current = [] }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }

    /// Närmaste värde i `values` inom `within` sekunder, annars `t`.
    static func snap(_ t: Double, to values: [Double], within: Double) -> Double {
        guard let best = values.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= within else { return t }
        return best
    }

    /// En översatt mening som en eller flera rader: lång text delas vid ordgränser (helst efter
    /// ett skiljetecken) så att varje rad ryms på två textrader, och tiden fördelas efter
    /// textens längd — med gränserna fästa vid där ett ord börjar i originalet.
    static func pieces(_ text: String, start: Double, end: Double, words: [Transcript.Word]) -> [Cue] {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let limit = Captions.lineLength * 2
        let total = tokens.joined(separator: " ").count
        guard total > limit, tokens.count > 1 else { return [Cue(start: start, end: end, text: tokens.joined(separator: " "))] }
        let n = Int((Double(total) / Double(limit)).rounded(.up))
        let target = Double(total) / Double(n)
        var groups: [[String]] = [[]]
        for w in tokens {
            let current = groups[groups.count - 1]
            let length = current.joined(separator: " ").count
            let after = length + 1 + w.count
            let sentenceEnd = current.last.map { ",.;:!?".contains($0.last ?? " ") } ?? false
            if !current.isEmpty && (after > limit || (groups.count < n && (Double(after) > target * 1.15
                                                                            || (sentenceEnd && Double(length) > target * 0.6)))) {
                groups.append([w])
            } else {
                groups[groups.count - 1].append(w)
            }
        }
        let starts = words.map(\.start).filter { $0 > start + 0.3 && $0 < end - 0.3 }
        var cues: [Cue] = []
        var done = 0
        var at = start
        for (i, g) in groups.enumerated() {
            let line = g.joined(separator: " ")
            done += line.count + 1
            var stop = i == groups.count - 1 ? end : start + (end - start) * Double(done) / Double(total + 1)
            if i < groups.count - 1 { stop = max(at + 0.3, snap(stop, to: starts, within: 0.6)) }
            cues.append(Cue(start: at, end: stop, text: line))
            at = stop
        }
        return cues
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
