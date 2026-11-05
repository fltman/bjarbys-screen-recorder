import Foundation

/// Sökningen i biblioteket: namn, källans titel, datumtexten och det som sades. Skiftläget
/// spelar ingen roll; å, ä och ö är egna bokstäver på svenska och skiljs från a och o.
public enum LibrarySearch {
    public enum Match: Equatable, Sendable {
        /// Träff i namnet, källan eller datumet.
        case title
        /// Träff i talet: ett citat kring träffen.
        case speech(String)
    }

    /// Alla ord i sökningen måste finnas någonstans (i titeln eller talet).
    public static func match(query: String, titles: [String], transcript: String?) -> Match? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return .title }
        let title = titles.joined(separator: " ").lowercased()
        let speech = transcript?.lowercased() ?? ""
        guard words.allSatisfy({ title.contains($0) || speech.contains($0) }) else { return nil }
        if words.allSatisfy({ title.contains($0) }) { return .title }
        guard let first = words.first(where: { !title.contains($0) }), let transcript,
              let r = transcript.range(of: first, options: .caseInsensitive) else { return .title }
        return .speech(snippet(transcript, around: r))
    }

    /// Några ord före och efter träffen, med … där texten fortsätter.
    static func snippet(_ text: String, around r: Range<String.Index>, radius: Int = 32) -> String {
        let start = text.index(r.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end])
        // Hela ord i kanterna.
        if start != text.startIndex, let space = s.firstIndex(of: " ") { s = String(s[s.index(after: space)...]) }
        if end != text.endIndex, let space = s.lastIndex(of: " ") { s = String(s[..<space]) }
        return (start != text.startIndex ? "…" : "") + s.trimmingCharacters(in: .whitespaces) + (end != text.endIndex ? "…" : "")
    }
}
