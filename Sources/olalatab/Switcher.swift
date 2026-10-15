import AppKit
import CSkyLight
import OlalaCore

/// Durations of one opening, in milliseconds.
struct OpenTiming {
    /// From the ⌥⇥ key event to the panel drawn, handed to the WindowServer and made visible.
    var fromKey: Double
    /// From the hot-key handler starting to the same point (excludes event delivery to olalatab).
    var fromHandler: Double
    /// Listing, filtering and sorting the windows.
    var list: Double
    var windowCount: Int
}

/// Ties the hot key, the window list, the panel, the key tap and focusing together.
/// Everything here runs on the main thread.
final class Switcher {
    /// Bench hooks.
    var onOpened: ((OpenTiming) -> Void)?
    var onSwitched: ((_ windowID: UInt32, _ releaseTime: UInt64) -> Void)?

    private let config: Config
    private let panel = SwitcherPanel()
    private let tap = KeyTap()
    private let ax = AXWindows()
    private var icons: [pid_t: CGImage] = [:]

    private var windows: [WindowInfo] = []
    private var selection: Selection?
    private var isOpen: Bool { selection != nil }

    init(config: Config) {
        self.config = config
        tap.onCommand = { [weak self] command, time in self?.handle(command, time: time) }
        panel.onClick = { [weak self] row in
            self?.selection?.select(row)
            self?.commit(time: Clock.now())
        }
        if !tap.install() { log("Key tap unavailable: allow olalatab in Accessibility, then make restart.") }
        panel.warmUp()
        // The icon cache follows running apps, so it never grows past them.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.icons[app.processIdentifier] = nil
            }
        }
    }

    // MARK: Opening

    func hotKeyPressed(backwards: Bool, eventTime: UInt64) {
        let start = Clock.now()
        debugLog("hot key \(backwards ? "⌥⇧⇥" : "⌥⇥"), open: \(isOpen), front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        if isOpen {
            // The tap normally swallows Tab while open; this only runs if the hot key fires anyway.
            handle(backwards ? .previous : .next, time: start)
            return
        }
        let interval = signposter.beginInterval("open")
        defer { signposter.endInterval("open", interval) }

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let listInterval = signposter.beginInterval("list")
        let listed = Self.windows(of: pid, order: config.order)
        signposter.endInterval("list", listInterval)
        let listedAt = Clock.now()
        guard let selection = Selection(windows: listed, backwards: backwards) else {
            debugLog("no window for pid \(pid) on this Space")
            return
        }

        // ⌥ already released (a quick ⌥⇥): switch right away, no panel.
        if !Self.optionHeld() {
            debugLog("⌥ already released: quick switch")
            ax.prefetch(pid)
            focus(listed[selection.index], releaseTime: start)
            return
        }
        let checkedAt = Clock.now()

        windows = listed
        self.selection = selection
        let steps = panel.show(listed.map(\.title), icon: icon(for: app), selected: selection.index, on: screen(of: listed))
        let end = Clock.now()

        // Off the critical path: the panel is already on its way to the screen.
        ax.prefetch(pid)
        if !tap.enable() { log("Key tap unavailable: Tab, Escape and ⌥ release won't be seen.") }
        // ⌥ released between the first check and the tap starting: the tap missed it.
        if !Self.optionHeld() {
            debugLog("⌥ released while opening: switching now")
            commit(time: Clock.now())
        }

        let timing = OpenTiming(fromKey: Clock.millis(from: eventTime, to: end) ?? Double(end - start) / 1e6,
                                fromHandler: Double(end - start) / 1e6,
                                list: Double(listedAt - start) / 1e6,
                                windowCount: listed.count)
        signposter.emitEvent("opened", "\(listed.count) windows, \(timing.fromKey) ms from key")
        // Always logged when over one 60 Hz frame (rare, so free at rest); every opening with --debug.
        if debugLogging || timing.fromKey > 16 {
            log(String(format: "%@open: %d windows, %.2f ms from key, handler %.2f = list %.2f + flags %.2f + show %.2f (layout %.2f, draw %.2f, flush %.2f, alpha %.2f)",
                       timing.fromKey > 16 ? "slow " : "", listed.count, timing.fromKey, timing.fromHandler, timing.list,
                       Double(checkedAt - listedAt) / 1e6, Double(end - checkedAt) / 1e6, steps[0], steps[1], steps[2], steps[3]))
        }
        onOpened?(timing)
    }

    private static func optionHeld() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }

    /// The front app's windows on the current Space, from one WindowServer call (no IPC to the app).
    static func windows(of pid: pid_t, order: WindowOrder) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) else { return [] }
        return order.sorted(WindowFilter.windows(in: list as NSArray, pid: pid))
    }

    // MARK: While open

    private func handle(_ command: SwitcherCommand, time: UInt64) {
        debugLog("tap \(command), open: \(isOpen)")
        guard isOpen else { return }
        switch command {
        case .next: selection?.next()
        case .previous: selection?.previous()
        case .commit: commit(time: time)
        case .cancel: close()
        }
        if let index = selection?.index { panel.select(index) }
    }

    private func commit(time: UInt64) {
        guard let selection else { return }
        let target = windows[selection.index]
        close()
        focus(target, releaseTime: time)
    }

    private func close() {
        selection = nil
        windows = []
        tap.disable()
        panel.hide()
    }

    // MARK: Focusing

    private func focus(_ window: WindowInfo, releaseTime: UInt64) {
        let interval = signposter.beginInterval("switch")
        if !olala_focus_window(window.pid, window.id) {
            debugLog("SkyLight focus unavailable, using public activation")
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
        }
        ax.raise(pid: window.pid, windowID: window.id)
        signposter.endInterval("switch", interval)
        if debugLogging { Self.logFront(expected: window, after: 0.15) }
        debugLog(String(format: "switch to %u: requested %.2f ms after the key event", window.id,
                        Clock.millis(from: releaseTime, to: Clock.now()) ?? -1))
        onSwitched?(window.id, releaseTime)
    }

    /// Debug only: says whether the switch actually brought the window to the front.
    private static func logFront(expected: WindowInfo, after delay: Double) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let front = list.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
            let id = front?[kCGWindowNumber as String] as? UInt32 ?? 0
            let owner = front?[kCGWindowOwnerName as String] as? String ?? "?"
            var focused: CFTypeRef?
            let app = AXUIElementCreateApplication(expected.pid)
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
            let keyID = focused.map { olala_ax_window_id(unsafeBitCast($0, to: AXUIElement.self)) } ?? 0
            let frontApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid
            log("switch check \(expected.id): front window \(id == expected.id ? "ok" : "FAILED (\(owner) \(id))"), "
                + "key window \(keyID == expected.id ? "ok" : "FAILED (\(keyID))"), front app \(frontApp ? "ok" : "FAILED")")
        }
    }

    // MARK: Helpers

    /// One small pre-rendered icon per app, so rows never resample a 1024 px icon.
    private func icon(for app: NSRunningApplication) -> CGImage? {
        if let cached = icons[app.processIdentifier] { return cached }
        guard let source = app.icon else { return nil }
        let side: CGFloat = 20
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * scale), pixelsHigh: Int(side * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        icons[app.processIdentifier] = rep.cgImage
        return rep.cgImage
    }

    /// The screen of the active window (the front-most), so the panel appears where the user looks.
    private func screen(of windows: [WindowInfo]) -> NSScreen {
        let screens = NSScreen.screens
        guard let active = windows.min(by: { $0.zIndex < $1.zIndex }), let primary = screens.first else {
            return NSScreen.main ?? screens[0]
        }
        // Core Graphics frames have their origin at the top-left of the primary screen.
        let center = NSPoint(x: active.frame.midX, y: primary.frame.maxY - active.frame.midY)
        return screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? primary
    }
}
