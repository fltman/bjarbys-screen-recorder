import Foundation

/// Undertexter i **utdatatid**, byggda ur orden som är kvar efter klippningen. Samma rutor
/// används för de inbrända undertexterna och för .srt/.vtt, så de säger alltid samma sak.
public struct Captions: Equatable, Sendable {
    public struct Cue: Equatable, Sendable {
        public var start: Double
        public var end: Double
        /// En eller två rader, åtskilda av "\n".
        public var text: String
    }

    /// Högst så många tecken per rad (gängse för undertexter), och högst två rader.
    public static let lineLength = 42
    /// En paus så här lång i talet börjar en ny ruta.
    static let pauseBreak = 0.7
    /// Rutan står kvar så här länge efter sista ordet, om nästa inte tar över före.
    static let linger = 0.6
    static let minimumDuration = 0.9

    public let cues: [Cue]

    public init(words: [Transcript.Word], timeMap: TimeMap) {
        // Orden i utdatatid; bortklippta ord faller bort.
        struct Placed { var start: Double; var end: Double; var text: String; var newSentence: Bool }
        var placed: [Placed] = []
        for w in words {
            let mid = (w.start + w.end) / 2
            guard timeMap.output(at: mid) != nil else { continue }
            let s = timeMap.output(at: w.start) ?? timeMap.output(at: mid)!
            let e = timeMap.output(at: w.end) ?? timeMap.output(at: mid)!
            placed.append(Placed(start: s, end: max(e, s), text: w.text, newSentence: w.startsSegment))
        }

        var groups: [[Placed]] = []
        var current: [Placed] = []
        func length(_ ws: [Placed]) -> Int { ws.map(\.text.count).reduce(0, +) + max(0, ws.count - 1) }
        for w in placed {
            if let last = current.last {
                let pause = w.start - last.end
                let full = length(current + [w]) > Self.lineLength * 2
                // En mening som slutar och en ny som börjar efter en kort stund: ny ruta.
                let sentenceEnd = last.text.last.map { ".!?".contains($0) } ?? false
                if pause > Self.pauseBreak || full || (sentenceEnd && length(current) > Self.lineLength / 2) {
                    groups.append(current)
                    current = []
                }
            }
            current.append(w)
        }
        if !current.isEmpty { groups.append(current) }

        var cues: [Cue] = []
        for (i, g) in groups.enumerated() {
            let start = g.first!.start
            var end = max(g.last!.end + Self.linger, start + Self.minimumDuration)
            if i + 1 < groups.count { end = min(end, groups[i + 1].first!.start) }
            cues.append(Cue(start: start, end: max(end, start + 0.1), text: Self.wrap(g.map(\.text))))
        }
        self.cues = cues
    }

    /// Bryter orden i högst två jämna rader.
    static func wrap(_ words: [String]) -> String {
        let total = words.joined(separator: " ")
        guard total.count > lineLength, words.count > 1 else { return total }
        // Brytpunkten som ger jämnast rader.
        var best = 1, bestDiff = Int.max
        for i in 1..<words.count {
            let a = words[..<i].joined(separator: " ").count
            let b = words[i...].joined(separator: " ").count
            if abs(a - b) < bestDiff { bestDiff = abs(a - b); best = i }
        }
        return words[..<best].joined(separator: " ") + "\n" + words[best...].joined(separator: " ")
    }

    /// Rutan som visas vid utdatatiden `t`.
    public func cue(at t: Double) -> Cue? {
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, t < cues[lo - 1].end else { return nil }
        return cues[lo - 1]
    }

    // MARK: - Filer

    public var srt: String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(Self.stamp(c.start, separator: ",")) --> \(Self.stamp(c.end, separator: ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    public var vtt: String {
        "WEBVTT\n\n" + cues.map { c in
            "\(Self.stamp(c.start, separator: ".")) --> \(Self.stamp(c.end, separator: "."))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func stamp(_ t: Double, separator: String) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
}
