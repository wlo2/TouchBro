import ApplicationServices
import AppKit
import Foundation

/// Decides whether one button press becomes a force click, from the pressure frames during it.
struct ForcePressDetector {
    static let ratioThreshold: Float = 1.9
    static let minimumDelta: Float = 170
    static let warmup: TimeInterval = 0.06

    private(set) var baseline: Float?
    private(set) var peak: Float = 0
    private var startedAt: TimeInterval = 0

    mutating func begin(at time: TimeInterval) {
        baseline = nil
        peak = 0
        startedAt = time
    }

    /// Feeds one frame of the current press; true when the press reads as a force click.
    mutating func feed(pressure: Float, at time: TimeInterval) -> Bool {
        peak = max(peak, pressure)
        guard let current = baseline else {
            baseline = pressure
            return false
        }
        if time - startedAt < Self.warmup {
            baseline = min(current, pressure)
            return false
        }
        let base = max(current, 0.001)
        return peak / base >= Self.ratioThreshold && peak - base >= Self.minimumDelta
    }
}

final class ForceClickMonitor: ObservableObject {
    private let minimumTriggerGap: TimeInterval = 0.25
    // A finger lands 0.1-0.3 s before the click; the selection captured then must still count.
    private let landingSelectionMaxAge: TimeInterval = 0.5
    private let axMessagingTimeout: Float = 0.2

    private let bridge = MultitouchBridge.shared
    private let stateQueue = DispatchQueue(label: "touchbro.force.state", qos: .utility)
    private let bridgeControlQueue = DispatchQueue(label: "touchbro.force.bridge.control", qos: .utility)

    private var leftButtonDown = false
    private var triggerInCurrentPress = false
    private var lastTriggerTime: TimeInterval = 0
    private var detector = ForcePressDetector()
    private var selectedTextAtPressStart: String?
    private var lastKnownSelectedText: String?
    private var lastKnownSelectionAt: TimeInterval = 0
    private var suppressSelectionCaptureUntil: TimeInterval = 0
    private var lastLandingRefreshAt: TimeInterval = 0

    private var globalLeftDownMonitor: Any?
    private var globalLeftUpMonitor: Any?
    private var permissionObservers: [NSObjectProtocol] = []
    private var permissionPollTimer: DispatchSourceTimer?
    private var lastPermissionState: Bool?

    init() {
        TouchBroDebugLog.write("ForceClickMonitor init")
        installButtonMonitors()
        installPermissionObservers()

        bridge.onFrame = { [weak self] maxPressure, maxState, touchCount, landing in
            self?.stateQueue.async {
                self?.handleFrameLocked(
                    maxPressure: maxPressure,
                    maxState: maxState,
                    touchCount: touchCount,
                    landing: landing
                )
            }
        }
        refreshPermissionState(reason: "init")
    }

    deinit {
        removePermissionObservers()
        removeButtonMonitors()
        stopPermissionPolling()
        bridge.setCaptureEnabled(false)
        bridge.stop()
    }

    func refreshPermissionState(reason: String = "manual") {
        bridgeControlQueue.async {
            self.refreshPermissionStateLocked(reason: reason)
        }
    }

    private func installButtonMonitors() {
        DispatchQueue.main.async {
            if self.globalLeftDownMonitor == nil {
                self.globalLeftDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                    self?.stateQueue.async {
                        self?.beginPressLocked()
                    }
                }
            }

            if self.globalLeftUpMonitor == nil {
                self.globalLeftUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
                    self?.stateQueue.async {
                        self?.endPressLocked()
                    }
                }
            }
        }
    }

    private func installPermissionObservers() {
        let nc = NotificationCenter.default

        let becameActive = nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPermissionState(reason: "app-became-active")
        }

        permissionObservers = [becameActive]
    }

    private func removePermissionObservers() {
        let nc = NotificationCenter.default
        for observer in permissionObservers {
            nc.removeObserver(observer)
        }
        permissionObservers.removeAll()
    }

    private func removeButtonMonitors() {
        DispatchQueue.main.async {
            if let globalLeftDownMonitor = self.globalLeftDownMonitor {
                NSEvent.removeMonitor(globalLeftDownMonitor)
                self.globalLeftDownMonitor = nil
            }
            if let globalLeftUpMonitor = self.globalLeftUpMonitor {
                NSEvent.removeMonitor(globalLeftUpMonitor)
                self.globalLeftUpMonitor = nil
            }
        }
    }

    private func refreshPermissionStateLocked(reason: String) {
        let granted = Permissions.accessibilityGranted

        if lastPermissionState != granted {
            lastPermissionState = granted
            TouchBroDebugLog.write("Accessibility \(granted ? "granted" : "needed") (\(reason))")
        }

        if granted {
            stopPermissionPollingLocked()
            bridge.start()
            bridge.setCaptureEnabled(true)
        } else {
            bridge.setCaptureEnabled(false)
            bridge.stop()
            startPermissionPollingLocked()
        }
    }

    private func startPermissionPollingLocked() {
        guard permissionPollTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: bridgeControlQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.refreshPermissionStateLocked(reason: "poll")
        }
        permissionPollTimer = timer
        timer.resume()
    }

    private func stopPermissionPolling() {
        bridgeControlQueue.async {
            self.stopPermissionPollingLocked()
        }
    }

    private func stopPermissionPollingLocked() {
        permissionPollTimer?.cancel()
        permissionPollTimer = nil
    }

    private func beginPressLocked() {
        let now = ProcessInfo.processInfo.systemUptime

        leftButtonDown = true
        triggerInCurrentPress = false
        detector.begin(at: now)
        selectedTextAtPressStart = recentKnownSelectionLocked(now: now, maxAge: landingSelectionMaxAge)
            ?? fetchSelectedTextFromAX()
    }

    private func endPressLocked() {
        let wasTriggered = triggerInCurrentPress

        leftButtonDown = false
        triggerInCurrentPress = false
        selectedTextAtPressStart = nil

        if !wasTriggered {
            refreshSelectionCacheLocked()
        }
    }

    private func refreshSelectionCacheLocked() {
        guard Shortcut.isCopy else {
            lastKnownSelectedText = nil
            lastKnownSelectionAt = 0
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now >= suppressSelectionCaptureUntil else { return }

        let selectedText = fetchSelectedTextFromAX()
        if let selectedText, !selectedText.isEmpty {
            lastKnownSelectedText = selectedText
            lastKnownSelectionAt = now
        } else {
            lastKnownSelectedText = nil
            lastKnownSelectionAt = 0
        }
    }

    private func fetchSelectedTextFromAX() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        // Set on the system-wide element, this bounds every AX call; the ~6 s default lets a hung app stall us.
        AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeout)
        if let focusedElement = copyAXElementAttribute(
            from: systemWide,
            attribute: kAXFocusedUIElementAttribute as CFString
        ) {
            if let selected = copySelectedText(from: focusedElement) {
                return selected
            }
        }

        if let focusedWindow = copyAXElementAttribute(
            from: systemWide,
            attribute: kAXFocusedWindowAttribute as CFString
        ) {
            if let selected = copySelectedText(from: focusedWindow) {
                return selected
            }
        }

        return nil
    }

    private func copyAXElementAttribute(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        guard let value else { return nil }
        let axElement = value as! AXUIElement
        return axElement
    }

    private func copySelectedText(from element: AXUIElement) -> String? {
        if let text = copySelectedTextAttribute(from: element) {
            return text
        }
        if let text = copySelectedTextByRange(from: element) {
            return text
        }
        return nil
    }

    private func copySelectedTextAttribute(from element: AXUIElement) -> String? {
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success else {
            return nil
        }

        if let selectedText = selectedValue as? String, !selectedText.isEmpty {
            return selectedText
        }

        if let selectedAttributedText = selectedValue as? NSAttributedString {
            let text = selectedAttributedText.string
            if !text.isEmpty {
                return text
            }
        }

        return nil
    }

    private func copySelectedTextByRange(from element: AXUIElement) -> String? {
        var rangeValueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValueRef
        ) == .success else {
            return nil
        }
        guard let rangeValueRef else { return nil }
        let rangeValue = rangeValueRef as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.length > 0 else { return nil }

        var selectedByRange: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &selectedByRange
        ) == .success else {
            return nil
        }

        if let text = selectedByRange as? String, !text.isEmpty {
            return text
        }

        if let attributed = selectedByRange as? NSAttributedString {
            let text = attributed.string
            if !text.isEmpty {
                return text
            }
        }

        return nil
    }

    private func recentKnownSelectionLocked(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        maxAge: TimeInterval = 1.2
    ) -> String? {
        guard now - lastKnownSelectionAt <= maxAge else { return nil }
        return lastKnownSelectedText
    }

    private func selectionSnapshotForTriggerLocked(now: TimeInterval) -> String? {
        if let selectedTextAtPressStart, !selectedTextAtPressStart.isEmpty {
            return selectedTextAtPressStart
        }
        return recentKnownSelectionLocked(now: now, maxAge: 0.20)
    }

    private func handleFrameLocked(maxPressure: Float, maxState: Int32, touchCount: Int, landing: Bool) {
        let now = ProcessInfo.processInfo.systemUptime

        guard leftButtonDown else {
            // Grab the selection as the finger lands, before the click can clear it.
            if landing, now - lastLandingRefreshAt >= 0.1,
               UserDefaults.standard.bool(forKey: DefaultsKeys.isEnabled) {
                lastLandingRefreshAt = now
                refreshSelectionCacheLocked()
            }
            return
        }
        guard maxPressure > 0 else { return }
        guard UserDefaults.standard.bool(forKey: DefaultsKeys.isEnabled) else { return }

        if let currentApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            let excludedApps = UserDefaults.standard.stringArray(forKey: DefaultsKeys.excludedApps) ?? []
            if excludedApps.contains(currentApp) {
                return
            }
        }

        guard detector.feed(pressure: maxPressure, at: now) else { return }
        guard !triggerInCurrentPress else { return }
        guard now - lastTriggerTime >= minimumTriggerGap else { return }

        triggerInCurrentPress = true
        suppressSelectionCaptureUntil = now + 0.35
        lastTriggerTime = now

        let selectedText = selectionSnapshotForTriggerLocked(now: now)
        let isCopyShortcut = Shortcut.isCopy

        DispatchQueue.main.async {
            let allowSyntheticFallback = !isCopyShortcut || selectedText == nil
            ShortcutRunner.postConfiguredShortcut(
                selectedTextOverride: selectedText,
                allowSyntheticCopyFallback: allowSyntheticFallback
            )
        }

        let baseline = max(detector.baseline ?? 0, 0.001)
        TouchBroDebugLog.write(
            String(
                format: "MT force detected (peak=%.1f b=%.1f d=%.1f r=%.2f s=%d t=%d) -> trigger now",
                detector.peak, baseline, detector.peak - baseline, detector.peak / baseline, maxState, touchCount
            )
        )
    }
}

enum TouchBroDebugLog {
    private static let queue = DispatchQueue(label: "touchbro.debug.log", qos: .background)
    private static let envDebugEnabled = ProcessInfo.processInfo.environment["TOUCHBRO_DEBUG"] == "1"

    static var isEnabled: Bool {
        envDebugEnabled || UserDefaults.standard.bool(forKey: DefaultsKeys.debugLogging)
    }

    static func write(_ message: String) {
        guard isEnabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        queue.async {
            // Per-user temp dir: a fixed name in the shared /tmp could be pre-planted as a symlink.
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TouchBro-debug.log")
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        defer { try? handle.close() }
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                    }
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}
