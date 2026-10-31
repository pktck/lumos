import Foundation

/// User settings for the ambient-light gate. Persisted as JSON in `UserDefaults`, the way the
/// pause list is; the Auto-brightness toggle itself stays per-session.
struct AmbientGateSettings: Codable, Equatable {
    enum UnavailablePolicy: String, Codable { case adapt, hold }   // hold = do not adapt

    var enabled = false
    var thresholdLux: Double = 50          // dark below this
    var enterDelay: TimeInterval = 5       // lights off: start adapting soon
    var exitDelay: TimeInterval = 5        // lights on: a passing light is caught by the dwell
    var fadeDuration: TimeInterval = 2     // both directions; 0 = step
    var whenUnavailable: UnavailablePolicy = .adapt

    static let thresholdRange: ClosedRange<Double> = 1 ... 5000
    static let enterDelayRange: ClosedRange<TimeInterval> = 1 ... 60
    static let exitDelayRange: ClosedRange<TimeInterval> = 5 ... 300
    static let fadeDurationRange: ClosedRange<TimeInterval> = 0 ... 10

    init() {}

    /// Every value inside its range, so a bad value in defaults can never wedge the gate.
    func clamped() -> AmbientGateSettings {
        var s = self
        s.thresholdLux = Self.thresholdRange.clamp(thresholdLux.isFinite ? thresholdLux : 50)
        s.enterDelay = Self.enterDelayRange.clamp(enterDelay.isFinite ? enterDelay : 5)
        s.exitDelay = Self.exitDelayRange.clamp(exitDelay.isFinite ? exitDelay : 5)
        s.fadeDuration = Self.fadeDurationRange.clamp(fadeDuration.isFinite ? fadeDuration : 2)
        return s
    }

    // Decoded field by field so a key missing from an older or newer file falls back to its
    // default instead of failing the whole struct.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        thresholdLux = try c.decodeIfPresent(Double.self, forKey: .thresholdLux) ?? thresholdLux
        enterDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .enterDelay) ?? enterDelay
        exitDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .exitDelay) ?? exitDelay
        fadeDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .fadeDuration) ?? fadeDuration
        whenUnavailable = try c.decodeIfPresent(UnavailablePolicy.self, forKey: .whenUnavailable) ?? whenUnavailable
    }
}

final class AmbientGateSettingsStore {
    private static let defaultsKey = "ambientGate"

    /// Defaults on any failure; values clamped on the way in.
    func load() -> AmbientGateSettings {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(AmbientGateSettings.self, from: data) else {
            return AmbientGateSettings()
        }
        return decoded.clamped()
    }

    func save(_ settings: AmbientGateSettings) {
        guard let data = try? JSONEncoder().encode(settings.clamped()) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

/// Lux values as the menu shows them: two significant figures, "lx" suffix.
enum LuxFormat {
    static func twoSignificant(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 0 }
        let magnitude = pow(10, floor(log10(v)) - 1)
        return (v / magnitude).rounded() * magnitude
    }

    static func string(_ v: Double) -> String {
        let r = twoSignificant(v)
        if r == 0 { return "0 lx" }
        if r < 1 { return String(format: "%.2f lx", r) }
        return r < 10 ? String(format: "%.1f lx", r) : String(format: "%.0f lx", r)
    }

    static func seconds(_ s: TimeInterval) -> String {
        s == s.rounded() ? String(format: "%.0f s", s) : String(format: "%.1f s", s)
    }
}

private extension ClosedRange where Bound == Double {
    func clamp(_ v: Double) -> Double { Swift.min(upperBound, Swift.max(lowerBound, v)) }
}
