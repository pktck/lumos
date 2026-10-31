import Foundation

/// A source of ambient light readings in lux. There is no public API for the MacBook's sensor,
/// so the two built-in sources below resolve private symbols at runtime, the way
/// `BrightnessController` does for brightness. Anything else that can measure a room (an
/// external or network sensor) would implement this protocol too; nothing here assumes the
/// built-in one beyond the lid handling in `AmbientLightMonitor`.
protocol AmbientLightSource: AnyObject {
    /// False when the private symbols did not resolve at init. Decided once, never changes.
    var isAvailable: Bool { get }
    /// Lux now, or nil when the call failed. May block briefly; callers run it off the main thread.
    func readLux() -> Double?
}

/// Route A: `DisplayServicesClient` / `AggregatedLux`. One ObjC-runtime call into a framework
/// Lumos already loads for brightness; underneath it is an XPC call into `backlightd`, which is
/// what the system's own auto-brightness reads. The client is kept for the process lifetime
/// because each instance is a connection.
final class DisplayServicesLuxSource: AmbientLightSource {
    private let client: NSObject?
    private let selector = Selector(("copyPropertyForKey:"))

    init() {
        _ = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        client = (NSClassFromString("DisplayServicesClient") as? NSObject.Type)?.init()
        if !isAvailable { NSLog("Lumos: DisplayServicesClient/AggregatedLux unavailable") }
    }

    var isAvailable: Bool { client?.responds(to: selector) ?? false }

    func readLux() -> Double? {
        guard let client, client.responds(to: selector) else { return nil }
        // A "copy" selector returns +1; take it retained so the count balances.
        return (client.perform(selector, with: "AggregatedLux")?.takeRetainedValue() as? NSNumber)?.doubleValue
    }
}

/// Route B: the HID ambient-light event. `BezelServices` exports a helper that finds the
/// sensor's HID service client; the event accessors are IOKit SPI. This is the raw driver value
/// rather than `backlightd`'s aggregate, so it is the fallback, not the first choice.
final class HIDLuxSource: AmbientLightSource {
    private typealias CopyClientFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double
    /// `kIOHIDEventTypeAmbientLightSensor`; its lux level is field `eventType << 16`.
    private static let eventType: Int32 = 12

    private let client: UnsafeMutableRawPointer?   // +1, kept for the life of the process
    private let copyEvent: CopyEventFn?
    private let getFloat: GetFloatFn?

    init() {
        guard let bezel = dlopen("/System/Library/PrivateFrameworks/BezelServices.framework/BezelServices", RTLD_NOW),
              let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            client = nil; copyEvent = nil; getFloat = nil
            NSLog("Lumos: BezelServices/IOKit dlopen failed for the ambient light sensor")
            return
        }
        func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(iokit, name) ?? dlsym(bezel, name) }
        let copyClient = dlsym(bezel, "ALCALSCopyALSServiceClient").map { unsafeBitCast($0, to: CopyClientFn.self) }
        copyEvent = sym("IOHIDServiceClientCopyEvent").map { unsafeBitCast($0, to: CopyEventFn.self) }
        getFloat = sym("IOHIDEventGetFloatValue").map { unsafeBitCast($0, to: GetFloatFn.self) }
        client = copyClient?()
        if !isAvailable { NSLog("Lumos: HID ambient light sensor unavailable") }
    }

    var isAvailable: Bool { client != nil && copyEvent != nil && getFloat != nil }

    func readLux() -> Double? {
        guard let client, let copyEvent, let getFloat,
              let event = copyEvent(client, Int64(Self.eventType), 0, 0) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(event).release() }   // balance the Copy
        return getFloat(event, Self.eventType << 16)
    }
}

/// Picks the first source that resolved at launch and logs the choice. The order is a constant:
/// A first, B as fallback; flip it if the probe shows A lagging or stuck. Non-finite or negative
/// values are rejected here so no caller has to.
final class CompositeLuxSource: AmbientLightSource {
    private let chosen: AmbientLightSource?

    init(order: [AmbientLightSource] = [DisplayServicesLuxSource(), HIDLuxSource()]) {
        chosen = order.first { $0.isAvailable }
        NSLog("Lumos: ambient light source: \(chosen.map { String(describing: type(of: $0)) } ?? "none")")
    }

    var isAvailable: Bool { chosen != nil }

    func readLux() -> Double? {
        guard let lux = chosen?.readLux(), lux.isFinite, lux >= 0 else { return nil }
        return lux
    }
}

#if DEBUG
/// Logs one reading a second so the app's scale can be checked against `tools/ambient-probe.swift`.
/// Debug builds only; the monitor and the menu's lux bar take over from here in later commits.
enum AmbientLightDebugLog {
    private static var timer: DispatchSourceTimer?

    static func start() {
        let source = CompositeLuxSource()
        guard source.isAvailable else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Lumos.ambient.debug", qos: .utility))
        t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        t.setEventHandler {
            if let lux = source.readLux() {
                NSLog("Lumos: ambient %.1f lx", lux)
            } else {
                NSLog("Lumos: ambient no reading")
            }
        }
        t.resume()
        timer = t
    }
}
#endif
