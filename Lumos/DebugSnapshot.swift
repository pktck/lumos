#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: render the menu popover to a PNG on request, so the layout can be checked
/// from a shell without screen capture or accessibility access. Post the distributed notification
/// `com.lennartbrocki.Lumos.snapshot` with an optional `path` (where to write the PNG),
/// and `appearance` ("dark" or "light").
///
/// The live popover window is captured when it is on screen; otherwise the same content view is
/// laid out in an offscreen window with the real app state, at 2× scale.
@MainActor
enum DebugSnapshot {
    static let notification = Notification.Name("com.lennartbrocki.Lumos.snapshot")
    private static var observer: NSObjectProtocol?
    private static var offscreen: NSWindow?

    static func install(state: AppState) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: notification, object: nil, queue: .main
        ) { note in
            let info = note.userInfo ?? [:]
            let path = (info["path"] as? String) ?? NSTemporaryDirectory() + "lumos-popover.png"
            let dark = (info["appearance"] as? String) == "dark"
            Task { @MainActor in render(state: state, to: path, dark: dark) }
        }
        NSLog("Lumos: debug snapshot hook installed (%@)", notification.rawValue)
    }

    private static func render(state: AppState, to path: String, dark: Bool) {
        if let window = NSApp.windows.first(where: {
            $0.isVisible && String(describing: type(of: $0)).contains("MenuBarExtraWindow")
        }), let view = window.contentView {
            write(view, scale: window.backingScaleFactor, to: path, source: "live popover")
            return
        }

        let root = ContentView(state: state)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 348, height: 10),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        offscreen = window
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        window.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        // One more pass so SwiftUI state set up by onAppear (popoverAppeared, a fresh reading)
        // reaches the view before the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            window.setContentSize(host.frame.size)
            host.layoutSubtreeIfNeeded()
            write(host, scale: 2, to: path, source: dark ? "offscreen dark" : "offscreen light")
            window.contentView = nil
            offscreen = nil
        }
    }

    private static func write(_ view: NSView, scale: CGFloat, to path: String, source: String) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { NSLog("Lumos: snapshot failed, empty view"); return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            NSLog("Lumos: snapshot (%@, %.0fx%.0f pt) written to %@", source, bounds.width, bounds.height, path)
        } catch {
            NSLog("Lumos: snapshot write failed: %@", String(describing: error))
        }
    }
}
#endif
