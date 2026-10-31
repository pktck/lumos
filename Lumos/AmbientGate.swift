import Foundation

/// Decides whether the room counts as dark. Pure logic: it is fed one lux reading per tick and
/// says when the dark state flips. Hysteresis stops chatter around the threshold; the two dwell
/// times stop single events (a flashlight, a hand over the sensor, a door opening) from flipping
/// it at all. No timers and no smoothing: the dwell is the filter.
final class AmbientGate {
    var threshold: Double = 50          // lux. Dark below this.
    var exitRatio: Double = 2.0         // Bright again only above threshold * exitRatio.
    var enterDelay: TimeInterval = 5    // Lights off: start adapting soon.
    var exitDelay: TimeInterval = 20    // Lights on: do not bail on a passing light.

    private(set) var isDark = false
    private var candidateSince: Date?
    /// Fires once per flip, on the caller's thread.
    var onChange: ((Bool) -> Void)?

    /// A flip that is waiting out its dwell. For the menu's progress line and countdown.
    struct Pending {
        let towardDark: Bool
        let progress: Double          // 0 ... 1 of the dwell elapsed
        let remaining: TimeInterval   // seconds until the flip, if the condition keeps holding
    }

    /// Feed one reading. nil (no reading) holds the current state and clears any pending flip.
    /// A flip needs its condition to hold for the whole dwell; any tick that disagrees restarts
    /// the clock. Changing `threshold` or the delays simply takes effect on the next tick.
    func ingest(lux: Double?, at now: Date = Date()) {
        guard let lux else { candidateSince = nil; return }
        let wantsDark = isDark ? lux < threshold * exitRatio : lux < threshold
        guard wantsDark != isDark else { candidateSince = nil; return }
        let since = candidateSince ?? now
        candidateSince = since
        if now.timeIntervalSince(since) >= (wantsDark ? enterDelay : exitDelay) {
            isDark = wantsDark
            candidateSince = nil
            onChange?(isDark)
        }
    }

    /// Pure read; never changes state. The UI reads it between ticks.
    func pending(at now: Date = Date()) -> Pending? {
        guard let since = candidateSince else { return nil }
        let required = isDark ? exitDelay : enterDelay
        let elapsed = now.timeIntervalSince(since)
        return Pending(towardDark: !isDark,
                       progress: min(1, elapsed / max(required, 0.001)),
                       remaining: max(0, required - elapsed))
    }

    /// Back to bright with no pending flip and no callback. Call when polling stops; the caller
    /// reconciles afterwards.
    func reset() {
        isDark = false
        candidateSince = nil
    }
}
