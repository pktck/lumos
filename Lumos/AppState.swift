import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// Observable state for the menu bar UI. Owns the `DisplayCoordinator` and mirrors its
/// per-display state into view models for SwiftUI.
@MainActor
final class AppState: ObservableObject {
    struct DisplayVM: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let isBuiltIn: Bool
        var luminance: Double
        var brightness: Double
        var corrections: Int
    }

    struct IgnoredAppVM: Identifiable {
        let id: String   // bundle ID
        let name: String
    }
    /// The frontmost app the "pause" control acts on, and whether it's currently paused.
    struct CurrentAppVM {
        let bundleID: String
        let name: String
        let isIgnored: Bool
    }

    /// The user's toggle: "I want Lumos adapting". Per-session on purpose; it starts off.
    @Published var isEnabled = false
    /// True while the coordinator is running. Equal to `isEnabled` unless something is holding
    /// the engines back on the user's behalf.
    @Published private(set) var isAdapting = false
    /// The ambient-light gate's decision: true while the room counts as dark.
    @Published private(set) var gateIsDark = false
    @Published var displays: [DisplayVM] = []
    @Published var ignoredApps: [IgnoredAppVM] = []
    @Published var currentApp: CurrentAppVM?
    @Published var hasScreenPermission = false
    @Published var lastErrorMessage: String?
    /// True when enabled but no screen frames are arriving — almost always a blocked/revoked
    /// Screen Recording permission. Surfaced so the failure isn't silent.
    @Published var captureBlocked = false

    let builtInBrightnessAvailable: Bool

    private let coordinator = DisplayCoordinator()

    // Ambient-light gate: adapt only while the room is dark. Settings arrive in a later commit;
    // until then the gate is on with the AmbientGate defaults (dark below 50 lx).
    private let gateEnabled = true
    private let ambient = AmbientLightMonitor(source: CompositeLuxSource())
    private let gate = AmbientGate()
    private var polling = false
    private var latestLux: Double?          // unflushed live value
    private var sensorUnreadable = false    // symbols resolved, but the last reading was nil (lid closed)
    var ambientAvailable: Bool { ambient.isAvailable }

    // Live values + throttled flush so the popover doesn't rebuild on every frame.
    private var lumByID: [CGDirectDisplayID: Double] = [:]
    private var briByID: [CGDirectDisplayID: Double] = [:]
    private var correctionsByID: [CGDirectDisplayID: Int] = [:]
    private var flushScheduled = false
    /// Whether the menu popover is currently open; UI flushes are skipped while it's closed.
    private var popoverVisible = false

    // Watchdog: detect "enabled but never received a first frame" (capture blocked).
    private var receivedAnyFrame = false
    private var captureWatchdog: Timer?

    init() {
        builtInBrightnessAvailable = BuiltInBrightnessBackend().isAvailable
        hasScreenPermission = LuminanceSampler.hasPermission()

        coordinator.onDisplaysChanged = { [weak self] in self?.rebuildDisplays() }
        coordinator.onUpdate = { [weak self] id, lum, bri in
            guard let self else { return }
            self.receivedAnyFrame = true
            if self.captureBlocked { self.captureBlocked = false }
            if self.lastErrorMessage != nil { self.lastErrorMessage = nil }
            self.lumByID[id] = lum
            self.briByID[id] = bri
            self.scheduleFlush()
        }
        coordinator.onLearn = { [weak self] id in
            self?.correctionsByID[id, default: 0] += 1
            self?.rebuildDisplays()
        }
        coordinator.onError = { [weak self] error in
            self?.lastErrorMessage = error.localizedDescription
        }
        coordinator.onIgnoreStateChanged = { [weak self] in self?.refreshIgnoreState() }

        gate.onChange = { [weak self] dark in
            guard let self else { return }
            NSLog("Lumos: ambient gate %@ (%.0f lx)", dark ? "dark" : "bright", self.latestLux ?? -1)
            self.gateIsDark = dark
            self.reconcile()
        }

        activateIfLaunchedAtLogin()
    }

    /// Auto-brightness is a per-session switch: it always starts off. That's fine when you open
    /// Lumos by hand, but someone who turned on "Launch at login" wants it *adapting* at login,
    /// not a menu bar icon sitting idle until they notice. So follow the login item.
    private func activateIfLaunchedAtLogin() {
        guard LaunchAtLogin.isEnabled else { return }
        // `setEnabled(true)` asks for Screen Recording when it's missing. At login there is no
        // user action behind that panel, so only start when access is already granted and let
        // the menu toggle do the asking otherwise.
        guard hasScreenPermission else { return }

        setEnabled(true)
    }

    func setEnabled(_ on: Bool) {
        if on {
            // The Screen Recording request stays on the user's click, where there is a user
            // action behind the panel.
            if !LuminanceSampler.hasPermission() {
                LuminanceSampler.requestPermission()
            }
            hasScreenPermission = LuminanceSampler.hasPermission()
        }
        isEnabled = on
        reconcile()
    }

    /// The single place that decides whether the sensor is polled and whether the engines run.
    /// Idempotent and cheap: call it after any input changes.
    private func reconcile() {
        let gateArmed = isEnabled && gateEnabled && ambient.isAvailable
        gateArmed ? startPolling() : stopPolling()

        let shouldRun: Bool
        if !isEnabled {
            shouldRun = false
        } else if !gateEnabled {
            shouldRun = true                                   // stock Lumos
        } else if !ambient.isAvailable || sensorUnreadable {
            shouldRun = true                                   // fail open: no reading, adapt anyway
        } else {
            shouldRun = gate.isDark
        }

        if shouldRun, !isAdapting { startEngines() }
        if !shouldRun, isAdapting { stopEngines() }
    }

    private func startPolling() {
        guard !polling else { return }
        polling = true
        ambient.start { [weak self] lux in                     // main thread, ~1 Hz
            guard let self else { return }
            self.latestLux = lux
            let wasUnreadable = self.sensorUnreadable
            self.sensorUnreadable = (lux == nil)
            self.gate.ingest(lux: lux)                          // may call onChange, which reconciles
            if wasUnreadable != self.sensorUnreadable { self.reconcile() }
        }
    }

    private func stopPolling() {
        guard polling else { return }
        polling = false
        ambient.stop()
        gate.reset()
        latestLux = nil
        sensorUnreadable = false
        gateIsDark = false
    }

    private func startEngines() {
        lastErrorMessage = nil
        captureBlocked = false
        receivedAnyFrame = false
        coordinator.start()
        startCaptureWatchdog()
        isAdapting = true
    }

    private func stopEngines() {
        coordinator.stop()
        captureWatchdog?.invalidate(); captureWatchdog = nil
        captureBlocked = false
        lumByID.removeAll(); briByID.removeAll()
        displays = []
        ignoredApps = []
        currentApp = nil
        isAdapting = false
    }

    // MARK: - Per-app pause (ignore list)

    /// Toggles whether the current frontmost app pauses auto-brightness.
    func togglePauseForCurrentApp() {
        guard let app = currentApp else { return }
        coordinator.toggleIgnore(bundleID: app.bundleID, name: app.name)
    }

    func removeIgnoredApp(_ bundleID: String) {
        coordinator.removeIgnored(bundleID: bundleID)
    }

    func addIgnoredApp(_ app: AppCandidate) {
        coordinator.addIgnored(bundleID: app.bundleID, name: app.name)
    }

    /// Apps offered by the pause search. Empty until `loadAppCatalog()` finishes.
    @Published private(set) var appCatalog: [AppCandidate] = []
    private var catalogLoading = false

    /// Scans installed apps in the background. Re-scans on each call (cheap, and picks up apps
    /// installed since last time); overlapping calls are dropped.
    func loadAppCatalog() {
        guard !catalogLoading else { return }
        catalogLoading = true
        Task { [weak self] in
            let apps = await Task.detached(priority: .userInitiated) { AppCatalog.load() }.value
            self?.appCatalog = apps
            self?.catalogLoading = false
        }
    }

    private func refreshIgnoreState(force: Bool = false) {
        guard force || popoverVisible else { return }
        ignoredApps = coordinator.ignoredApps.map { IgnoredAppVM(id: $0.bundleID, name: $0.name) }
        if let app = coordinator.pausableApp {
            currentApp = CurrentAppVM(bundleID: app.bundleID, name: app.name,
                                      isIgnored: coordinator.isIgnored(app.bundleID))
        } else {
            currentApp = nil
        }
    }

    /// If no frame arrives within a few seconds of enabling, capture is blocked (permission).
    private func startCaptureWatchdog() {
        captureWatchdog?.invalidate()
        captureWatchdog = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkCaptureWatchdog()
            }
        }
    }

    private func checkCaptureWatchdog() {
        guard isAdapting, !receivedAnyFrame else { return }
        hasScreenPermission = LuminanceSampler.hasPermission()
        captureBlocked = true
    }

    // MARK: - Slider corrections

    func previewBrightness(_ id: CGDirectDisplayID, _ value: Double) {
        coordinator.previewBrightness(displayID: id, value)
        briByID[id] = value
        updateBrightness(id, value)
    }

    func commitBrightness(_ id: CGDirectDisplayID) {
        guard let value = coordinator.commitBrightness(displayID: id) else { return }
        briByID[id] = value
    }

    func resetLearning(_ id: CGDirectDisplayID) {
        coordinator.resetLearning(displayID: id)
        correctionsByID[id] = 0
        rebuildDisplays()
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - View-model mirroring

    /// The menu popover re-renders its content whenever `displays` changes — even while it's
    /// closed (MenuBarExtra keeps the content alive). So while it's closed we keep the latest
    /// frame values in the dictionaries but skip the SwiftUI flush entirely; on open we do one
    /// forced rebuild and then flush live. This is what keeps idle CPU near zero while content
    /// is changing on screen (e.g. a blinking caret produces frames we'd otherwise render for).
    func popoverAppeared() {
        popoverVisible = true
        rebuildDisplays(force: true)
        refreshIgnoreState(force: true)
    }

    func popoverDisappeared() { popoverVisible = false }

    private func scheduleFlush() {
        guard popoverVisible, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.flushScheduled = false
            self?.rebuildDisplays()
        }
    }

    private func rebuildDisplays(force: Bool = false) {
        guard force || popoverVisible else { return }
        displays = coordinator.displays.map { info in
            DisplayVM(id: info.displayID,
                      name: info.name,
                      isBuiltIn: info.isBuiltIn,
                      luminance: lumByID[info.displayID] ?? 0,
                      brightness: briByID[info.displayID] ?? 0,
                      corrections: correctionsByID[info.displayID] ?? 0)
        }
    }

    /// Updates just one display's brightness in place (used during live slider drags).
    private func updateBrightness(_ id: CGDirectDisplayID, _ value: Double) {
        guard let idx = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[idx].brightness = value
    }
}
