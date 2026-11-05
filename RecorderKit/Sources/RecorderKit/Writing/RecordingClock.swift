import Foundation
import CoreMedia
import os

/// Den gemensamma tidslinjen för alla spår och all markördata.
///
/// Allt mäts i värdklockan (`CMClockGetHostTimeClock`). Nollpunkten `t0` är den första
/// skärmrutans tid. Pauser dras av, så att filerna blir sammanhängande: en buffert som
/// fångades under en paus kastas, och allt efter en paus flyttas bakåt med pausens längd.
/// Eftersom varje spår och varje händelse går genom samma avbildning hamnar de exakt rätt
/// mot varandra, oavsett vilken kö de kom på.
public final class RecordingClock: @unchecked Sendable {
    private struct State {
        var t0: CMTime?
        var pauses: [(start: CMTime, end: CMTime)] = []
        var pausedAt: CMTime?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public static func hostNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    /// Sätter nollpunkten om den inte redan är satt. Returnerar sant första gången.
    @discardableResult
    public func startIfNeeded(at time: CMTime) -> Bool {
        state.withLock { s in
            guard s.t0 == nil else { return false }
            s.t0 = time
            return true
        }
    }

    public var isStarted: Bool { state.withLock { $0.t0 != nil } }
    /// Nollpunkten i värdklockan (första hela rutan), eller nil före start.
    public var origin: CMTime? { state.withLock { $0.t0 } }
    public var isPaused: Bool { state.withLock { $0.pausedAt != nil } }

    public func pause(at time: CMTime = RecordingClock.hostNow()) {
        state.withLock { s in
            guard s.pausedAt == nil else { return }
            s.pausedAt = time
        }
    }

    public func resume(at time: CMTime = RecordingClock.hostNow()) {
        state.withLock { s in
            guard let p = s.pausedAt else { return }
            s.pauses.append((p, time))
            s.pausedAt = nil
        }
    }

    /// Värdklocktid → tid på inspelningens tidslinje, eller nil om bufferten ska kastas
    /// (före start, under en paus).
    public func map(_ host: CMTime) -> CMTime? {
        state.withLock { s in
            guard let t0 = s.t0, host.isNumeric, host >= t0 else { return nil }
            if let p = s.pausedAt, host >= p { return nil }
            var removed = CMTime.zero
            for pause in s.pauses {
                if host >= pause.end {
                    removed = removed + (pause.end - pause.start)
                } else if host >= pause.start {
                    return nil
                }
            }
            return host - t0 - removed
        }
    }

    public func seconds(_ host: CMTime) -> Double? {
        map(host)?.seconds
    }

    /// Hur långt inspelningen har kommit just nu (pauser borträknade).
    public var elapsed: Double {
        state.withLock { s in
            guard let t0 = s.t0 else { return 0 }
            let now = s.pausedAt ?? RecordingClock.hostNow()
            var removed = CMTime.zero
            for pause in s.pauses { removed = removed + (pause.end - pause.start) }
            return max(0, (now - t0 - removed).seconds)
        }
    }
}
