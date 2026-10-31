#!/usr/bin/swift
// Prints the MacBook's ambient light reading once a second from both private routes Lumos
// knows: A = DisplayServicesClient/AggregatedLux (what backlightd uses), B = the raw HID
// ambient-light event via BezelServices. The numbers define the lux scale the gate's threshold
// is set against; the app's lux bar should match route A within noise.
//
//   swift tools/ambient-probe.swift            # until Ctrl-C
//   swift tools/ambient-probe.swift 10         # ten readings, then exit
import Foundation

// Route A
_ = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
let dsClient = (NSClassFromString("DisplayServicesClient") as? NSObject.Type)?.init()
let dsSelector = Selector(("copyPropertyForKey:"))
func readA() -> Double? {
    guard let dsClient, dsClient.responds(to: dsSelector) else { return nil }
    return (dsClient.perform(dsSelector, with: "AggregatedLux")?.takeRetainedValue() as? NSNumber)?.doubleValue
}

// Route B
typealias CopyClientFn = @convention(c) () -> UnsafeMutableRawPointer?
typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double
let bezel = dlopen("/System/Library/PrivateFrameworks/BezelServices.framework/BezelServices", RTLD_NOW)
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
func sym(_ name: String) -> UnsafeMutableRawPointer? {
    (iokit.flatMap { dlsym($0, name) }) ?? (bezel.flatMap { dlsym($0, name) })
}
let copyClient = bezel.flatMap { dlsym($0, "ALCALSCopyALSServiceClient") }.map { unsafeBitCast($0, to: CopyClientFn.self) }
let copyEvent = sym("IOHIDServiceClientCopyEvent").map { unsafeBitCast($0, to: CopyEventFn.self) }
let getFloat = sym("IOHIDEventGetFloatValue").map { unsafeBitCast($0, to: GetFloatFn.self) }
let hidClient = copyClient?()
func readB() -> Double? {
    guard let hidClient, let copyEvent, let getFloat,
          let event = copyEvent(hidClient, 12, 0, 0) else { return nil }
    defer { Unmanaged<AnyObject>.fromOpaque(event).release() }
    return getFloat(event, 12 << 16)
}

func fmt(_ v: Double?) -> String { v.map { String(format: "%8.1f lx", $0) } ?? "      n/a   " }
print("A: DisplayServices AggregatedLux  \(dsClient == nil ? "(class missing)" : dsClient!.responds(to: dsSelector) ? "ok" : "(selector missing)")")
print("B: HID ambient light event        \(hidClient == nil ? "(client missing)" : copyEvent == nil || getFloat == nil ? "(symbols missing)" : "ok")")
print("time      A              B")
let limit = CommandLine.arguments.dropFirst().first.flatMap { Int($0) } ?? Int.max
let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
var n = 0
while n < limit {
    print("\(clock.string(from: Date()))  \(fmt(readA()))  \(fmt(readB()))")
    fflush(stdout)
    n += 1
    if n < limit { Thread.sleep(forTimeInterval: 1) }
}
