import Foundation
import CoreGraphics

/// Steg-för-steg-guide ur en inspelning: varje klick och kortkommando blir ett steg med en
/// färdig bild, och det som sades kring handlingen blir stegets text. Utan transkript
/// beskrivs handlingen ("Klicka på knapp «Exportera»"), med elementets namn om
/// Tillgänglighet var påslagen.
public struct StepGuide: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case click(String?), doubleClick(String?), rightClick(String?), shortcut(String)
    }

    public struct Step: Equatable, Sendable {
        public var sourceTime: Double
        public var outputTime: Double
        public var action: Action
        /// Det som sades till steget (tomt utan transkript).
        public var spoken: String

        /// Handlingen i ord, på guidens språk.
        public func instruction(_ language: String) -> String {
            let sv = !language.hasPrefix("en")
            switch action {
            case .click(let l): return l.map { sv ? "Klicka på \($0)." : "Click \($0)." } ?? (sv ? "Klicka här." : "Click here.")
            case .doubleClick(let l): return l.map { sv ? "Dubbelklicka på \($0)." : "Double-click \($0)." } ?? (sv ? "Dubbelklicka här." : "Double-click here.")
            case .rightClick(let l): return l.map { sv ? "Högerklicka på \($0)." : "Right-click \($0)." } ?? (sv ? "Högerklicka här." : "Right-click here.")
            case .shortcut(let k): return sv ? "Tryck \(k)." : "Press \(k)."
            }
        }
    }

    /// Guidens språk: talets om det finns ett transkript, annars användarens förstaspråk.
    /// En guide är ett dokument, inte gränssnitt — svenska instruktioner till svenskt tal
    /// även om datorn står på engelska.
    public var language: String

    /// Det som sades före första handlingen.
    public var intro: String
    public var steps: [Step]

    /// Klick närmare varandra än så (i tid) är samma steg.
    static let mergeWindow = 0.8

    public init(events: [InputEvent], words: [Transcript.Word], timeMap: TimeMap, language: String? = nil) {
        self.language = language ?? ((Locale.preferredLanguages.first ?? "sv").hasPrefix("sv") ? "sv" : "en")
        // Elementens namn loggas med klickets tid.
        var labels: [Double: String] = [:]
        for e in events where e.k == .element { if let l = e.label { labels[e.t] = l } }

        var steps: [Step] = []
        for e in events.sorted(by: { $0.t < $1.t }) {
            guard let out = timeMap.output(at: e.t) else { continue }
            switch e.k {
            case .down:
                let label = labels[e.t]
                let action: Action = e.b == 1 ? .rightClick(label) : ((e.n ?? 1) >= 2 ? .doubleClick(label) : .click(label))
                if let last = steps.last, e.t - last.sourceTime < Self.mergeWindow, case .click = last.action {
                    // Andra klicket i ett dubbelklick, eller ett klick strax efter: samma steg.
                    if case .doubleClick = action { steps[steps.count - 1].action = action }
                    continue
                }
                steps.append(Step(sourceTime: e.t, outputTime: out, action: action, spoken: ""))
            case .key:
                guard let k = e.label else { continue }
                if let last = steps.last, case .shortcut(k) = last.action, e.t - last.sourceTime < 1.5 { continue }
                steps.append(Step(sourceTime: e.t, outputTime: out, action: .shortcut(k), spoken: ""))
            default:
                continue
            }
        }

        // Meningar ur transkriptet (bara det som är kvar efter klippningen). whisper lägger
        // ibland flera meningar i ett segment, så de delas också vid .!? och vid pauser.
        var sentences: [(start: Double, text: String)] = []
        var previous: Transcript.Word?
        for w in words where timeMap.output(at: (w.start + w.end) / 2) != nil {
            let ended = previous.map { p in p.text.last.map { ".!?".contains($0) } ?? false } ?? true
            let paused = previous.map { w.start - $0.end > 1.0 } ?? true
            if w.startsSegment || ended || paused || sentences.isEmpty {
                sentences.append((w.start, w.text))
            } else {
                sentences[sentences.count - 1].text += " " + w.text
            }
            previous = w
        }
        // En mening hör till första handlingen som sker när den sägs eller efter (man säger
        // ofta vad man ska göra just innan man gör det).
        var intro: [String] = []
        for s in sentences {
            if let i = steps.firstIndex(where: { $0.sourceTime >= s.start - 0.3 }) {
                if i == 0 && s.start < steps[0].sourceTime - 3 { intro.append(s.text); continue }
                steps[i].spoken += (steps[i].spoken.isEmpty ? "" : " ") + s.text
            } else if !steps.isEmpty {
                steps[steps.count - 1].spoken += (steps[steps.count - 1].spoken.isEmpty ? "" : " ") + s.text
            } else {
                intro.append(s.text)
            }
        }
        self.intro = intro.joined(separator: " ")
        self.steps = steps
    }

    /// Tiden för stegets bild: strax efter handlingen, så att klickringen eller
    /// kortkommandot syns.
    public static func imageTime(_ step: Step) -> Double {
        if case .shortcut = step.action { return step.outputTime + 0.25 }
        return step.outputTime + 0.12
    }

    // MARK: - Filer

    public func markdown(title: String, images: [String]) -> String {
        var md = "# \(title)\n\n"
        if !intro.isEmpty { md += intro + "\n\n" }
        for (i, step) in steps.enumerated() {
            md += "## \(i + 1). \(step.instruction(language))\n\n"
            if i < images.count { md += "![\(stepWord) \(i + 1)](\(images[i]))\n\n" }
            if !step.spoken.isEmpty { md += step.spoken + "\n\n" }
        }
        return md
    }

    private var stepWord: String { language.hasPrefix("en") ? "Step" : "Steg" }

    public func html(title: String, images: [Data]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var body = "<h1>\(esc(title))</h1>\n"
        if !intro.isEmpty { body += "<p class=\"intro\">\(esc(intro))</p>\n" }
        for (i, step) in steps.enumerated() {
            body += "<section><h2><span>\(i + 1)</span>\(esc(step.instruction(language)))</h2>\n"
            if i < images.count {
                body += "<img alt=\"\(stepWord) \(i + 1)\" src=\"data:image/png;base64,\(images[i].base64EncodedString())\">\n"
            }
            if !step.spoken.isEmpty { body += "<p>\(esc(step.spoken))</p>\n" }
            body += "</section>\n"
        }
        return """
        <!DOCTYPE html>
        <html lang="\(language.hasPrefix("en") ? "en" : "sv")"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 17px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; max-width: 920px;
               margin: 48px auto; padding: 0 24px; color: #1d1d1f; background: #fff; }
        @media (prefers-color-scheme: dark) { body { color: #f5f5f7; background: #161618; } }
        h1 { font-size: 34px; letter-spacing: -0.02em; margin-bottom: 8px; }
        .intro { font-size: 19px; opacity: .8; }
        section { margin: 44px 0; }
        h2 { font-size: 21px; display: flex; gap: 12px; align-items: center; }
        h2 span { flex: none; width: 30px; height: 30px; border-radius: 50%; background: #2563eb; color: #fff;
                  font-size: 15px; display: grid; place-items: center; }
        img { width: 100%; border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,.18); }
        </style></head><body>
        \(body)</body></html>
        """
    }
}

/// Gör guiden till filer: en bild per steg, `guide.md` och en fristående `guide.html`.
public enum GuideMaker {
    public struct Output: Sendable {
        public let markdown: URL
        public let html: URL
        public let steps: Int
    }

    public static func make(_ rec: LoadedRecording, project: EditProject, title: String, in directory: URL,
                            shortSide: Int = 1080) async throws -> Output {
        let spoken = rec.transcript?.language
        let guide = StepGuide(events: rec.events, words: rec.transcript?.words ?? [],
                              timeMap: TimeMap(segments: project.segments),
                              language: spoken.flatMap { $0 == "auto" || $0.isEmpty ? nil : $0 })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Guidens bilder: filmens utseende (bakgrund, zoom, markör), men hela bilden i
        // inspelningens format och utan undertext — texten står redan i guiden.
        var look = project
        look.aspect = .source
        look.framing = .fit
        look.captions.visible = false
        let (images, _) = try await FrameGrabber.frames(rec, project: look,
                                                        outputTimes: guide.steps.map(StepGuide.imageTime),
                                                        shortSide: shortSide)
        var names: [String] = []
        var data: [Data] = []
        for (i, image) in images.enumerated() {
            let name = String(format: "steg-%02d.png", i + 1)
            let url = directory.appendingPathComponent(name)
            try FrameGrabber.writePNG(image, to: url)
            names.append(name)
            data.append(try Data(contentsOf: url))
        }
        let md = directory.appendingPathComponent("guide.md")
        let html = directory.appendingPathComponent("guide.html")
        try guide.markdown(title: title, images: names).write(to: md, atomically: true, encoding: .utf8)
        try guide.html(title: title, images: data).write(to: html, atomically: true, encoding: .utf8)
        return Output(markdown: md, html: html, steps: guide.steps.count)
    }
}
