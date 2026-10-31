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

/// Reads the sources in order and returns the first good value, so a route that resolves but
/// goes quiet falls through to the next one on that tick. The HID event comes first: it is the
/// raw sensor and moves with the room, where `AggregatedLux` is `backlightd`'s smoothed figure
/// and held still most of the time (54 changes against 632 over the same 15 minutes). Non-finite
/// or negative values are rejected here so no caller has to.
final class CompositeLuxSource: AmbientLightSource {
    private let sources: [AmbientLightSource]

    init(order: [AmbientLightSource] = [HIDLuxSource(), DisplayServicesLuxSource()]) {
        sources = order.filter { $0.isAvailable }
        NSLog("Lumos: ambient light sources: \(sources.map { String(describing: type(of: $0)) }.joined(separator: ", "))")
    }

    var isAvailable: Bool { !sources.isEmpty }

    func readLux() -> Double? {
        for source in sources {
            if let lux = source.readLux(), lux.isFinite, lux >= 0 { return lux }
        }
        return nil
    }

}
