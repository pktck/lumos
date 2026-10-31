import Foundation

/// Polls an `AmbientLightSource` about once a second on a utility queue and delivers each
/// reading on the main thread. Polling rather than event callbacks: the gate has seconds of
/// dwell, so 1 Hz is plenty, and one call a second costs nothing against Lumos's near-zero
/// idle CPU.
///
/// Lid detection lives here, not in the sources: the sensor sits in the display bezel, so with
/// the lid closed (`activeBuiltInDisplayID()` is nil) the monitor publishes nil without asking
/// the source.
final class AmbientLightMonitor {
    private let source: AmbientLightSource
    private let queue = DispatchQueue(label: "Lumos.ambient", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(source: AmbientLightSource) { self.source = source }

    var isAvailable: Bool { source.isAvailable }

    /// `handler` runs on the main thread about once a second; nil means no reading right now.
    /// Idempotent: calling start while running replaces the handler and keeps the cadence.
    func start(interval: TimeInterval = 1.0, handler: @escaping (Double?) -> Void) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [source] in
            let lux: Double? = BrightnessController.activeBuiltInDisplayID() == nil ? nil : source.readLux()
            DispatchQueue.main.async { handler(lux) }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
