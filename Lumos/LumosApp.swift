import AppKit
import ServiceManagement
import SwiftUI

@main
struct LumosApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // Three states: adapting, armed and waiting for a dark room, off.
        MenuBarExtra("Lumos", systemImage: state.isAdapting ? "sun.max.fill"
                                          : (state.isEnabled ? "sun.min" : "sun.max")) {
            ContentView(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { state.isEnabled },
                set: { state.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-brightness").font(.headline)
                    if let status = state.statusLine {
                        HStack(spacing: 4) {
                            Image(systemName: status.icon)
                            Text(status.text)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)

            if !state.builtInBrightnessAvailable {
                Label("Brightness control unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if state.isEnabled {
                AmbientSection(state: state)
            }

            if state.isAdapting {
                if state.displays.isEmpty {
                    Text("Detecting displays…").foregroundStyle(.secondary)
                } else {
                    ForEach(state.displays) { display in
                        DisplayRow(state: state, display: display)
                    }
                }

                Divider()
                PauseSection(state: state)
            }

            if let error = state.lastErrorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()
            LaunchAtLoginToggle()

            Divider()
            Button("About Lumos") { AboutPanel.show() }
            Button("Quit Lumos") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { state.popoverAppeared() }
        .onDisappear { state.popoverDisappeared() }
    }

}

/// The standard macOS About panel (icon, name, version, copyright from Info.plist).
enum AboutPanel {
    static func show() {
        // Lumos is a menu bar (LSUIElement) app, so it's never active on its own; without this
        // the panel opens behind the frontmost app. Taking focus also closes the menu popover.
        NSApp.activate()

        let link = "https://github.com/lenbrocki/lumos"
        let credits = NSAttributedString(string: "github.com/lenbrocki/lumos", attributes: [
            .link: URL(string: link)!,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            // An empty build version drops the "(1)" suffix; MARKETING_VERSION is the real version.
            .version: "",
        ])
    }
}

/// Login-item registration. `SMAppService` owns the state, so nothing is persisted here — the
/// registration itself is the source of truth.
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

struct LaunchAtLoginToggle: View {
    // Deliberately not seeded from `LaunchAtLogin.status`: this view is rebuilt on every flush
    // while the popover is open (~5/s), and that status call is a blocking system query whose
    // result SwiftUI would throw away after the first one. `onAppear` reads it instead.
    @State private var isOn = false
    @State private var error: String?
    @State private var needsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { isOn }, set: setEnabled)) {
                Text("Launch at login").frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)

            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }

            if needsSettings {
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
        .onAppear { refreshFromSystem() }
    }

    /// Re-read on appear only; there's no SMAppService change notification to observe. This also
    /// covers the user flipping Lumos off in System Settings while the app is running.
    private func refreshFromSystem() {
        let status = LaunchAtLogin.status
        isOn = status == .enabled

        if status == .requiresApproval {
            error = "Lumos needs to be approved in Login Items."
            needsSettings = true
        } else {
            error = nil
            needsSettings = false
        }
    }

    private func setEnabled(_ on: Bool) {
        var failure: String?
        do {
            try LaunchAtLogin.setEnabled(on)
        } catch {
            // These localize to bare domain codes ("SMAppServiceErrorDomain error 1"), which
            // tells the user nothing — say what failed and point at System Settings instead.
            failure = on ? "Couldn't turn on launch at login." : "Couldn't turn off launch at login."
        }

        refreshFromSystem()

        // `register()` can return without throwing while the system still leaves the item off,
        // so trust `status` over what was asked for and never show an unexplained snap-back.
        if failure == nil, isOn != on {
            failure = "macOS didn't accept the change."
        }
        // A `requiresApproval` message from refreshFromSystem() is more specific; keep it.
        if let failure, error == nil {
            error = failure
            needsSettings = true
        }
    }
}

/// Per-app pause (ignore list): turn auto-brightness off for the current app, and manage the
/// list of paused apps. A paused app holds whatever brightness you last set while in it.
struct PauseSection: View {
    @ObservedObject var state: AppState
    @State private var query = ""
    @State private var showAll = false

    /// Paused apps collapse to this many rows, with a "Show more" toggle for the rest.
    private let collapsedLimit = 3

    /// Paused apps other than the current one (which is shown above with its toggle).
    private var otherPaused: [AppState.IgnoredAppVM] {
        state.ignoredApps.filter { $0.id != state.currentApp?.bundleID }
    }

    private var searchResults: [AppCandidate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let paused = Set(state.ignoredApps.map(\.id))
        let matches = state.appCatalog.filter {
            !paused.contains($0.bundleID) && $0.name.localizedCaseInsensitiveContains(q)
        }
        // Names starting with the query first, then other matches; list is already name-sorted.
        let prefixed = matches.filter { $0.name.lowercased().hasPrefix(q.lowercased()) }
        let rest = matches.filter { !$0.name.lowercased().hasPrefix(q.lowercased()) }
        return Array((prefixed + rest).prefix(5))
    }

    private func add(_ app: AppCandidate) {
        state.addIgnoredApp(app)
        query = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pause for an app").font(.caption).foregroundStyle(.secondary)

            if let app = state.currentApp {
                Toggle(isOn: Binding(
                    get: { app.isIgnored },
                    set: { _ in state.togglePauseForCurrentApp() }
                )) {
                    Text(app.name).lineLimit(1)
                }
                .toggleStyle(.switch)
                .help("Hold a fixed brightness while \(app.name) is frontmost")
            } else {
                Text("Switch to another app to pause it here.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // Other paused apps (the current one is already shown above with its toggle).
            let others = otherPaused
            let collapsible = others.count > collapsedLimit
            ForEach(collapsible && !showAll ? Array(others.prefix(collapsedLimit)) : others) { app in
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Button {
                        state.removeIgnoredApp(app.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Resume auto-brightness for \(app.name)")
                }
                .font(.caption)
            }

            if collapsible {
                Button(showAll ? "Show less" : "Show \(others.count - collapsedLimit) more") {
                    showAll.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            // Search installed apps to pause one without switching to it.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Add an app to pause…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { if let first = searchResults.first { add(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

            let results = searchResults
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                if results.isEmpty {
                    Text(state.appCatalog.isEmpty ? "Loading apps…" : "No matching apps")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(results) { app in
                        Button { add(app) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                                Text(app.name).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Pause auto-brightness while \(app.name) is frontmost")
                    }
                }
            }
        }
        .onAppear { state.loadAppCatalog() }
    }
}

struct DisplayRow: View {
    @ObservedObject var state: AppState
    let display: AppState.DisplayVM

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                Text(display.name).fontWeight(.medium).lineLimit(1)
                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: "sun.min")
                Slider(
                    value: Binding(
                        get: { display.brightness },
                        set: { state.previewBrightness(display.id, $0) }
                    ),
                    in: 0 ... 1,
                    // Don't pass `display.brightness` here: on macOS 27 this closure is the one
                    // captured when the drag began, so it would commit the pre-drag value and
                    // snap the slider back. The engine commits the level it last previewed.
                    onEditingChanged: { editing in
                        if !editing { state.commitBrightness(display.id) }
                    }
                )
                Image(systemName: "sun.max")
            }

            HStack {
                Text("luminance \(Int((display.luminance * 100).rounded()))%")
                Spacer()
                Text("brightness \(Int((display.brightness * 100).rounded()))%")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Ambient-light gate: adapt only while the room is darker than a threshold. The switch sits
/// in the popover's column under Auto-brightness; while it is on, a card below it shows the
/// live reading against the threshold, so when the gate hasn't done what you expected the card
/// is the one place to look. The dwell and fade times are fixed.
struct AmbientSection: View {
    @ObservedObject var state: AppState

    private var settings: AmbientGateSettings { state.gateSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The three switches in the popover share the right edge, like a settings pane.
            Toggle(isOn: Binding(
                get: { settings.enabled },
                set: { state.gateSettings.enabled = $0 }
            )) {
                Text("Dark room only").frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!state.ambientAvailable)

            if !state.ambientAvailable {
                Text("Ambient light sensor unavailable on this macOS")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if settings.enabled {
                VStack(alignment: .leading, spacing: 6) {
                    AmbientLive(readout: state.ambientReadout,
                                threshold: settings.thresholdLux,
                                isAdapting: state.isAdapting,
                                onCommit: { lux in state.gateSettings.thresholdLux = LuxFormat.twoSignificant(lux) })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// The part of the card that follows the sensor: the rule, the bar and the reading line. It
/// observes `AmbientReadout` alone, so a new reading redraws these rows and nothing else.
private struct AmbientLive: View {
    @ObservedObject var readout: AmbientReadout
    let threshold: Double
    let isAdapting: Bool
    let onCommit: (Double) -> Void
    /// Threshold (lux) while the knob is being dragged; nil otherwise, so the committed value shows.
    @State private var dragging: Double?

    private var previewThreshold: Double { dragging ?? threshold }

    var body: some View {
        Text("Enable below \(LuxFormat.string(previewThreshold))")
            .monospacedDigit()
            .font(.caption2)
            .foregroundStyle(.secondary)

        LuxBar(lux: readout.lux, threshold: previewThreshold,
               pending: readout.pending,
               onDrag: { lux in dragging = lux },
               onCommit: { lux in onCommit(lux); dragging = nil })

        HStack {
            Text(reading).monospacedDigit()
            Spacer()
            if let pending = readout.pending {
                // Counts on its own clock: the pending value is constant for the whole dwell.
                TimelineView(.periodic(from: pending.since, by: 1)) { context in
                    let secs = Int(pending.remaining(at: context.date).rounded(.up))
                    Text(pending.towardDark ? "dark in \(secs) s" : "bright in \(secs) s")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The reading, or, with none, what the gate does about it; the line under the
    /// Auto-brightness toggle covers the bright-room pause.
    private var reading: String {
        if let lux = readout.lux { return "Room brightness: \(LuxFormat.string(lux))" }
        return isAdapting ? "Lid closed · adapting anyway" : "Lid closed · paused"
    }
}

/// The threshold control and the live reading on one log-scale bar. The zone left of the knob
/// is shaded: readings there enable auto-brightness, readings to the right pause it. The
/// reading is a dot, so the picture is "where the room is, against where it switches". The
/// release threshold (the gate's exit ratio above the knob) is not drawn. A thin line
/// underneath fills with the dwell while a flip is pending, and landmarks sit below the bar.
struct LuxBar: View {
    let lux: Double?
    let threshold: Double
    let pending: AmbientGate.Pending?
    /// Threshold (lux) under the pointer while dragging, then the final value once released.
    let onDrag: (Double) -> Void
    let onCommit: (Double) -> Void

    static let scaleMax = log10(AmbientGateSettings.thresholdRange.upperBound)
    private static let trackHeight: CGFloat = 10
    private static let knobSize = CGSize(width: 14, height: 22)
    private static let dotSize: CGFloat = 7
    private static let landmarks: [Double] = [10, 100, 1000]

    /// 0 ... 1 along the scale.
    static func position(_ v: Double) -> Double {
        let r = AmbientGateSettings.thresholdRange
        return log10(min(max(v, r.lowerBound), r.upperBound)) / scaleMax
    }

    /// The inverse: lux for a point along the scale, clamped to the settable range.
    static func lux(atFraction f: Double) -> Double {
        let r = AmbientGateSettings.thresholdRange
        return min(max(pow(10, min(max(f, 0), 1) * scaleMax), r.lowerBound), r.upperBound)
    }

    /// The scale is inset by half a knob at both ends, like the system slider, so the knob
    /// stays inside the track at the extremes.
    private static func x(_ v: Double, width w: CGFloat) -> CGFloat {
        knobSize.width / 2 + position(v) * (w - knobSize.width)
    }

    private static func fraction(atX x: CGFloat, width w: CGFloat) -> Double {
        (x - knobSize.width / 2) / max(w - knobSize.width, 1)
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                let x0 = Self.x(threshold, width: w)
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Rectangle().fill(Color.primary.opacity(0.18)).frame(width: x0)
                    }
                    .frame(height: Self.trackHeight)
                    .clipShape(Capsule())

                    if let lux {
                        Circle().fill(Color.primary.opacity(0.85))
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                            .frame(width: Self.dotSize, height: Self.dotSize)
                            .offset(x: Self.x(lux, width: w) - Self.dotSize / 2)
                    }

                    // The knob, drawn like the system slider's so it reads as the control it is.
                    Capsule()
                        .fill(Color.white)
                        .overlay(Capsule().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                        .shadow(color: Color.black.opacity(0.25), radius: 1, y: 0.5)
                        .frame(width: Self.knobSize.width, height: Self.knobSize.height)
                        .offset(x: x0 - Self.knobSize.width / 2)
                }
                .frame(height: Self.knobSize.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in onDrag(Self.lux(atFraction: Self.fraction(atX: v.location.x, width: w))) }
                        .onEnded { v in onCommit(Self.lux(atFraction: Self.fraction(atX: v.location.x, width: w))) }
                )
            }
            .frame(height: Self.knobSize.height)
            // No glide between readings: they arrive five times a second while the menu is open,
            // and animating each one would keep the display refreshing the whole time.

            // The dwell line redraws on its own clock while a flip is pending, so it moves
            // continuously; otherwise it is static and costs nothing.
            GeometryReader { geo in
                if let pending {
                    TimelineView(.animation) { context in
                        Rectangle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: geo.size.width * pending.progress(at: context.date))
                    }
                }
            }
            .frame(height: 2)

            GeometryReader { geo in
                ForEach(Self.landmarks, id: \.self) { v in
                    Text(String(Int(v)))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .position(x: Self.x(v, width: geo.size.width), y: 5)
                }
            }
            .frame(height: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Enable below \(LuxFormat.string(threshold))")
        .accessibilityValue(lux.map { "room " + LuxFormat.string($0).replacingOccurrences(of: "lx", with: "lux") } ?? "no reading")
        .accessibilityAdjustableAction { direction in
            let factor = direction == .increment ? 1.25 : 0.8
            onCommit(min(max(threshold * factor, AmbientGateSettings.thresholdRange.lowerBound),
                         AmbientGateSettings.thresholdRange.upperBound))
        }
    }
}
