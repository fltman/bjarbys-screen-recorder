import Foundation

/// Kortkommandona som ska synas i filmen, i **utdatatid**: ett kommando visas lika länge
/// oavsett om delen det trycktes i spelas i 1× eller 4×, och inget visas ur bortklippta delar.
///
/// Ett nytt kommando ersätter det som syns. Samma kommando igen medan det syns räknas upp
/// ("⌘Z ×3") i stället för att blinka.
public struct ShortcutTrack: Sendable {
    public struct Item: Equatable, Sendable {
        public let label: String
        public let count: Int
        /// När bubblan dök upp (för infadningen); samma för hela en uppräkning.
        public let appear: Double
        public let start: Double
        public let end: Double
        /// Tonas ut vid `end`, eller byts direkt mot nästa.
        public let fadesOut: Bool

        public var text: String { count > 1 ? "\(label) ×\(count)" : label }
    }

    /// Så länge ett kommando syns efter trycket.
    public static let hold = 1.5
    static let fadeIn = 0.12
    static let fadeOut = 0.3

    public let items: [Item]

    public init(events: [InputEvent], timeMap: TimeMap) {
        var items: [Item] = []
        for e in events where e.k == .key {
            guard let label = e.label, !label.isEmpty, let t = timeMap.output(at: e.t) else { continue }
            var count = 1
            var appear = t
            if let last = items.last, t < last.end {
                // Det som syns byts ut direkt.
                items[items.count - 1] = Item(label: last.label, count: last.count, appear: last.appear,
                                              start: last.start, end: max(last.start, t), fadesOut: false)
                if last.label == label {
                    count = last.count + 1
                    appear = last.appear
                }
            }
            items.append(Item(label: label, count: count, appear: appear, start: t, end: t + Self.hold,
                              fadesOut: true))
        }
        self.items = items.filter { $0.end > $0.start }
    }

    /// Alla texter som kan visas, för att rita dem i förväg.
    public var texts: Set<String> { Set(items.map(\.text)) }

    /// Det som syns vid utdatatiden `t`: text, opacitet 0–1 och infadningens förlopp 0–1.
    public func visible(at t: Double) -> (text: String, opacity: Double, entrance: Double)? {
        // Binärsökning efter sista posten som börjat.
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let item = items[lo - 1]
        guard t < item.end else { return nil }
        let entrance = min(1, max(0, (t - item.appear) / Self.fadeIn))
        var opacity = entrance
        if item.fadesOut {
            opacity = min(opacity, max(0, (item.end - t) / Self.fadeOut))
        }
        return (item.text, opacity, entrance)
    }
}
