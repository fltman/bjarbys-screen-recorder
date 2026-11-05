import Foundation

/// Klipp i källtid: det som klipps bort är luckor mellan delarna, så att ta bort ord ur
/// texten, ta bort dödtid och dela i tidslinjen är samma sak.
extension EditProject {
    static let epsilon = 0.001

    /// Klipper bort källintervallet `range` ur alla delar det berör.
    public mutating func cut(_ range: ClosedRange<Double>) {
        let a = range.lowerBound, b = range.upperBound
        guard b - a > Self.epsilon else { return }
        var out: [ClipSegment] = []
        for s in segments {
            guard s.end > a, s.start < b else { out.append(s); continue }
            if a - s.start > Self.epsilon {
                var left = s; left.end = a; out.append(left)
            }
            if s.end - b > Self.epsilon {
                var right = s; right.id = UUID(); right.start = b; out.append(right)
            }
        }
        segments = out
    }

    /// Tar tillbaka källintervallet `range`: luckor i det fylls av grannen före (eller efter),
    /// i grannens hastighet, eller av en ny del i normal hastighet.
    public mutating func restore(_ range: ClosedRange<Double>) {
        let a = range.lowerBound, b = range.upperBound
        guard b - a > Self.epsilon else { return }
        var sorted = segments.sorted { $0.start < $1.start }
        // Luckorna i [a, b] som ingen del täcker.
        var gaps: [(Double, Double)] = []
        var at = a
        for s in sorted where s.end > at && s.start < b {
            if s.start - at > Self.epsilon { gaps.append((at, s.start)) }
            at = max(at, s.end)
        }
        if b - at > Self.epsilon { gaps.append((at, b)) }

        for (ga, gb) in gaps {
            let before = sorted.firstIndex { abs($0.end - ga) <= Self.epsilon }
            let after = sorted.firstIndex { abs($0.start - gb) <= Self.epsilon }
            if let i = before, let j = after, sorted[i].speed == sorted[j].speed {
                sorted[i].end = sorted[j].end
                sorted.remove(at: j)
            } else if let i = before {
                sorted[i].end = gb
            } else if let j = after {
                sorted[j].start = ga
            } else {
                sorted.append(ClipSegment(start: ga, end: gb))
                sorted.sort { $0.start < $1.start }
            }
        }
        segments = sorted
    }

    /// Spelar källintervallet `range` i farten `speed` i stället för att klippa bort det: delarna
    /// delas i kanterna, och de nya snitten får ingen övergång (det ska se ut som ett svep).
    public mutating func setSpeed(_ speed: Double, in range: ClosedRange<Double>) {
        let a = range.lowerBound, b = range.upperBound
        guard b - a > Self.epsilon else { return }
        var out: [ClipSegment] = []
        for s in segments {
            guard s.end > a, s.start < b else { out.append(s); continue }
            if a - s.start > Self.epsilon {
                var left = s; left.end = a; out.append(left)
            }
            var mid = s
            mid.start = max(s.start, a); mid.end = min(s.end, b); mid.speed = speed
            if a - s.start > Self.epsilon { mid.id = UUID(); mid.transitionIn = Transition(kind: .none) }
            out.append(mid)
            if s.end - b > Self.epsilon {
                var right = s; right.id = UUID(); right.start = b; right.transitionIn = Transition(kind: .none); out.append(right)
            }
        }
        segments = out
    }

    /// Är källtiden `t` med i filmen?
    public func isKept(_ t: Double) -> Bool {
        segments.contains { t >= $0.start && t < $0.end }
    }
}

/// Dödtid: stunder där ingen talar och inget händer — ingen mus, inga klick, inga tangenter.
/// Det typiska är början efter nedräkningen, och väntan medan något laddar.
public enum DeadTime {
    /// Händelser som räknas som att något händer.
    static let activity: Set<InputEvent.Kind> = [.move, .down, .up, .drag, .scroll, .key, .typing, .ink]

    /// Källintervall längre än `minimum` utan tal och utan aktivitet. `keep` sekunder lämnas
    /// kvar intill det som händer, så att klippet inte känns avhugget.
    public static func find(events: [InputEvent], speech: [ClosedRange<Double>], duration: Double,
                            minimum: Double = 2.0, keep: Double = 0.4) -> [ClosedRange<Double>] {
        var busy: [ClosedRange<Double>] = speech
        for e in events where activity.contains(e.k) {
            busy.append(max(0, e.t - 0.1)...(e.t + 0.1))
        }
        busy.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for r in busy {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        var out: [ClosedRange<Double>] = []
        // Luckorna mellan det som händer, med början och slut på inspelningen som kanter.
        var previousEnd: Double? = nil
        for next in merged.map(Optional.some) + [nil] {
            let gapStart = previousEnd ?? 0
            let gapEnd = next?.lowerBound ?? duration
            if gapEnd - gapStart >= minimum {
                let start = previousEnd == nil ? gapStart : gapStart + keep
                let end = next == nil ? gapEnd : gapEnd - keep
                if end - start > 0.2 { out.append(start...end) }
            }
            if let next { previousEnd = max(previousEnd ?? 0, next.upperBound) }
        }
        return out
    }
}
