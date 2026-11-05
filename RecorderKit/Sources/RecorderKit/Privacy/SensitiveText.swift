import Foundation

/// Hittar känslig text i det som syns på skärmen. Bara mönster, ingen modell: det ska gå att
/// förutsäga vad som döljs, och ett missat mönster ska gå att lägga till här med ett prov.
public enum SensitiveText {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case email, phone, personalNumber, card, secret, manual
    }

    public struct Match: Equatable, Sendable {
        public let kind: Kind
        public let range: Range<String.Index>
    }

    static let patterns: [(Kind, NSRegularExpression)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        return [
            (.email, re(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#)),
            // Nycklar med känt prefix (OpenAI, Anthropic, GitHub, AWS, Slack, Google, Stripe, JWT).
            (.secret, re(#"(?:sk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z_\-]{30,}|(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,})"#)),
            // Svenskt personnummer/samordningsnummer: (ÅÅ)ÅÅMMDD-NNNN.
            (.personalNumber, re(#"(?<![0-9])(?:19|20)?[0-9]{2}(?:0[1-9]|1[0-2])(?:[0-2][0-9]|3[01]|[6-8][0-9]|9[01])[-+ ]?[0-9]{4}(?![0-9])"#)),
            (.card, re(#"(?<![0-9])(?:[0-9][ \-]?){12,18}[0-9](?![0-9])"#)),
            // Telefon: +46 eller 0 följt av 7–11 siffror med valfria mellanrum/bindestreck.
            (.phone, re(#"(?<![0-9])(?:\+[0-9]{1,3}[ \-]?|0)[0-9]{1,3}(?:[ \-]?[0-9]{2,4}){2,4}(?![0-9])"#)),
        ]
    }()

    /// Alla träffar i en textrad. Ett kortnummer måste klara Luhn-kontrollen; ett längre
    /// slumpartat ord (nyckel utan känt prefix) räknas som hemlighet.
    public static func matches(in text: String) -> [Match] {
        var out: [Match] = []
        let ns = text as NSString
        func overlaps(_ r: Range<String.Index>) -> Bool { out.contains { $0.range.overlaps(r) } }
        for (kind, re) in patterns {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(m.range, in: text), !overlaps(r) else { continue }
                let s = String(text[r])
                switch kind {
                case .card:
                    guard luhn(s) else { continue }
                case .phone:
                    let digits = s.filter(\.isNumber).count
                    guard digits >= 8 && digits <= 13 else { continue }
                default: break
                }
                out.append(Match(kind: kind, range: r))
            }
        }
        // Långa slumpartade ord: blandning av versaler, gemener och siffror, minst 24 tecken.
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\"" || $0 == "'" || $0 == "=" || $0 == ":" }) {
            let r = word.startIndex..<word.endIndex
            guard word.count >= 24, !overlaps(r), looksRandom(String(word)) else { continue }
            out.append(Match(kind: .secret, range: r))
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap(\.wholeNumberValue)
        guard digits.count >= 13 && digits.count <= 19 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    static func looksRandom(_ s: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-+/"))
        guard s.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        let upper = s.contains { $0.isUppercase }, lower = s.contains { $0.isLowercase }
        let digits = s.filter(\.isNumber).count
        // Sökvägar och vanliga sammansatta ord har få siffror; nycklar har många.
        return upper && lower && digits >= 3 && Set(s).count >= 12
    }

    /// En kort, ofarlig beskrivning för listan: aldrig själva texten.
    public static func hint(_ kind: Kind, _ text: String) -> String {
        let first = text.first.map(String.init) ?? ""
        return first + String(repeating: "•", count: min(8, max(3, text.count - 1)))
    }
}
