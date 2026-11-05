import Foundation

/// `transcript.json`: vad som sades, ord för ord, i **källtid**. Härlett ur inspelningen och
/// går alltid att göra om; redigeringen (vilka ord som klippts bort) ligger i `project.json`
/// som vanliga klipp.
public struct Transcript: Codable, Equatable, Sendable {
    public struct Word: Codable, Equatable, Hashable, Sendable {
        public var start: Double
        public var end: Double
        /// Ordet med skiljetecken, utan inledande blanksteg.
        public var text: String
        /// Ordet börjar en ny mening eller ett nytt stycke (för radbrytning i texten).
        public var startsSegment: Bool

        public init(start: Double, end: Double, text: String, startsSegment: Bool = false) {
            self.start = start; self.end = end; self.text = text; self.startsSegment = startsSegment
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = c.value(.start, 0); end = c.value(.end, 0)
            text = c.value(.text, ""); startsSegment = c.value(.startsSegment, false)
        }
    }

    public var schemaVersion: Int
    /// Modellfilen som användes, t.ex. "kb_whisper_ggml_small.bin".
    public var model: String
    public var language: String
    /// Spåret som transkriberades.
    public var track: RecordingMeta.TrackKind
    public var words: [Word]
    public var createdAt: Date

    public init(model: String = "", language: String = "", track: RecordingMeta.TrackKind = .microphone,
                words: [Word] = [], createdAt: Date = Date()) {
        schemaVersion = 1
        self.model = model; self.language = language; self.track = track
        self.words = words; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Transcript()
        schemaVersion = c.value(.schemaVersion, 1)
        model = c.value(.model, d.model)
        language = c.value(.language, d.language)
        track = c.value(.track, d.track)
        words = c.value(.words, [])
        createdAt = c.value(.createdAt, d.createdAt)
    }

    /// Tiderna där någon talar: orden, med korta pauser inom en mening ihopslagna.
    public func speech(joiningGapsBelow gap: Double = 0.35) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for w in words where w.end > w.start {
            if let last = out.last, w.start - last.upperBound < gap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, w.end)
            } else {
                out.append(w.start...w.end)
            }
        }
        return out
    }
}

extension RecordingBundle {
    public var transcriptURL: URL { url.appendingPathComponent("transcript.json") }

    public func readTranscript() -> Transcript? {
        try? BundleJSON.read(Transcript.self, from: transcriptURL)
    }

    public func saveTranscript(_ t: Transcript) throws {
        try BundleJSON.write(t, to: transcriptURL)
    }
}

// MARK: - Påhitt

/// whisper hittar på text ur tystnad och brus ("Tack.", "Textning av …", ett ord i loop).
/// Taldetekteringen tar det mesta; det här tar resten. Ur Kundkoll, där varje fras här
/// faktiskt dök upp i drift.
public enum Hallucination {
    public static func isNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.hasPrefix("[") && t.hasSuffix("]") { return true }
        if t.hasPrefix("(") && t.hasSuffix(")") { return true }
        let bare = t.trimmingCharacters(in: CharacterSet(charactersIn: " .!?…-"))
        if bare.isEmpty { return true }
        if isLoop(t) { return true }
        let low = bare.lowercased()
        if openings.contains(where: { low.hasPrefix($0) }) { return true }
        return standing.contains(low)
    }

    /// Inledningar som ingen säger men som whisper lärt sig ur textade videor.
    static let openings: [String] = [
        "tack till elever och personal", "tack till alla som", "textning av", "textning:",
        "undertexter av", "undertexter från", "undertextning av", "svensk textning",
        "svensktextning", "översättning av", "översatt av", "tack för att ni tittade",
        "tack för att du tittade", "glöm inte att prenumerera", "prenumerera på",
        "subtitles by", "captions by", "transcribed by", "thanks for watching",
        "teksting av", "tekstet av", "undertekster av", "tekstning af", "undertekster af",
    ]

    /// Bara exakta träffar: "Tack." är påhitt, "Tack för att du tog dig tid" är tal.
    static let standing: Set<String> = [
        "tack", "tack så mycket", "tack för att ni tittade", "tack för att du tittade",
        "tack för hjälpen", "hej då", "amara.org", "textning.nu", "you", "thank you",
        "thanks for watching", "takk", "tusen takk", "tak", "mange tak",
    ]

    /// Samma ord om och om igen är en modell som fastnat, aldrig någon som talar.
    static func isLoop(_ t: String) -> Bool {
        let words = t.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard words.count >= 6 else { return false }
        var longest = 1, run = 1
        for i in 1..<words.count {
            run = words[i] == words[i - 1] ? run + 1 : 1
            longest = max(longest, run)
        }
        if longest >= 4 { return true }
        return words.count >= 12 && Set(words).count * 4 <= words.count
    }
}

// MARK: - Utfyllnadsord

public enum FillerWords {
    /// Tvekljud. KB-Whisper skriver sällan ut dem (den är tränad på textning som stryker dem),
    /// men när de finns i texten går de att klippa bort på en gång.
    static let fillers: Set<String> = ["eh", "ehm", "öh", "öhm", "äh", "ähm", "hm", "hmm", "mm", "mhm",
                                       "um", "umm", "uh", "uhm", "er", "erm"]

    public static func isFiller(_ word: String) -> Bool {
        fillers.contains(word.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted))
    }
}
