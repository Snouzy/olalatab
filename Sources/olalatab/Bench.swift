import AppKit
import Carbon
import CSkyLight
import OlalaCore

/// End-to-end benchmark run inside the real app: it posts real ⌥⇥ keyboard events, so each
/// iteration goes through the hot key, the window list, the panel, the key tap and the switch,
/// exactly like a user press.
@MainActor
final class Bench {
    struct Options {
        var iterations = 200
        var warmUp = 2
        var label = ""
        var targetPID: pid_t?
        var expectWindows = 2
        var out: URL?
        /// SIGSTOP the target once it is in front, SIGCONT at the end: ⌥⇥ on a hung app.
        var freezeTarget = false
    }

    struct Report: Encodable {
        var label: String
        var windows: Int
        var iterations: Int
        var failedOpens: Int
        var failedSwitches: Int
        var openFromKey: Percentiles?
        var openInHandler: Percentiles?
        var list: Percentiles?
        var switchToFront: Percentiles?
    }

    private let switcher: Switcher
    private let options: Options
    private let source = CGEventSource(stateID: .hidSystemState)
    private var opened: OpenTiming?
    private var switched: (windowID: UInt32, releaseTime: UInt64)?

    init(switcher: Switcher, options: Options) {
        self.switcher = switcher
        self.options = options
        switcher.onOpened = { [weak self] timing in self?.opened = timing }
        switcher.onSwitched = { [weak self] id, time in self?.switched = (id, time) }
    }

    func run() async -> Report {
        guard let pid = await prepareTarget() else {
            log("bench: no front app with \(options.expectWindows) windows")
            return Report(label: options.label, windows: 0, iterations: 0, failedOpens: 0, failedSwitches: 0)
        }
        let windowCount = Switcher.windows(of: pid, order: .creation).count
        log("bench \(options.label): pid \(pid), \(windowCount) windows, \(options.iterations) iterations")
        if options.freezeTarget { kill(pid, SIGSTOP) }
        defer { if options.freezeTarget { kill(pid, SIGCONT) } }

        var fromKey: [Double] = [], inHandler: [Double] = [], list: [Double] = [], toFront: [Double] = []
        var failedOpens = 0, failedSwitches = 0
        for i in 0..<(options.iterations + options.warmUp) {
            opened = nil
            switched = nil
            postOption(down: true)
            try? await Task.sleep(nanoseconds: 5_000_000)
            postTab()
            guard let timing = await waitFor({ self.opened }) else {
                failedOpens += 1
                postOption(down: false)
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            // One more Tab through the key tap, as a user cycling would.
            try? await Task.sleep(nanoseconds: 20_000_000)
            postTab()
            try? await Task.sleep(nanoseconds: 20_000_000)
            postOption(down: false)
            let front = await waitFor({ self.switched }).map { s in
                Task.detached(priority: .userInitiated) { Self.waitUntilFront(s.windowID, since: s.releaseTime) }
            }
            let frontMillis = await front?.value
            if i >= options.warmUp {
                fromKey.append(timing.fromKey)
                inHandler.append(timing.fromHandler)
                list.append(timing.list)
                if let frontMillis { toFront.append(frontMillis) } else { failedSwitches += 1 }
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return Report(label: options.label, windows: windowCount, iterations: options.iterations,
                      failedOpens: failedOpens, failedSwitches: failedSwitches,
                      openFromKey: Percentiles(fromKey), openInHandler: Percentiles(inHandler),
                      list: Percentiles(list), switchToFront: Percentiles(toFront))
    }

    /// Brings the target app to the front and waits until it shows the expected number of windows.
    private func prepareTarget() async -> pid_t? {
        let deadline = Clock.now() + 60_000_000_000
        while Clock.now() < deadline {
            if let pid = options.targetPID {
                let windows = Switcher.windows(of: pid, order: .recent)
                if windows.count >= options.expectWindows {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                        _ = olala_focus_window(pid, windows[0].id)
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return pid }
                }
            } else if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                      Switcher.windows(of: pid, order: .creation).count >= options.expectWindows {
                return pid
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    private func waitFor<T>(_ value: () -> T?, timeout: UInt64 = 1_000_000_000) async -> T? {
        let deadline = Clock.now() + timeout
        while Clock.now() < deadline {
            if let v = value() { return v }
            try? await Task.sleep(nanoseconds: 500_000)
        }
        return nil
    }

    /// Milliseconds from ⌥ release until `windowID` is the front-most normal window, or nil after 1 s.
    nonisolated private static func waitUntilFront(_ windowID: UInt32, since release: UInt64) -> Double? {
        let deadline = Clock.now() + 1_000_000_000
        while Clock.now() < deadline {
            if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray?,
               let front = list.lazy.compactMap({ $0 as? NSDictionary })
                   .first(where: { ($0.object(forKey: kCGWindowLayer as NSString) as? NSNumber)?.intValue == 0 }),
               (front.object(forKey: kCGWindowNumber as NSString) as? NSNumber)?.uint32Value == windowID {
                return Clock.millis(from: release, to: Clock.now())
            }
            usleep(250)
        }
        let front = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])?
            .first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        debugLog("switch to \(windowID) not seen; front is \(front?[kCGWindowNumber as String] ?? "?") of \(front?[kCGWindowOwnerName as String] ?? "?")")
        return nil
    }

    private func postOption(down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Option), keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? .maskAlternate : []
        event.post(tap: .cghidEventTap)
    }

    private func postTab() {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Tab), keyDown: down) else { continue }
            event.flags = .maskAlternate
            event.post(tap: .cghidEventTap)
        }
    }

    static func markdownRow(_ r: Report) -> String {
        func ms(_ p: Percentiles?, _ k: KeyPath<Percentiles, Double>) -> String {
            p.map { String(format: "%.2f", $0[keyPath: k]) } ?? "–"
        }
        return "| \(r.label) | \(r.windows) | \(ms(r.openFromKey, \.p50)) | \(ms(r.openFromKey, \.p99)) | "
            + "\(ms(r.openInHandler, \.p50)) | \(ms(r.list, \.p50)) | \(ms(r.list, \.p99)) | "
            + "\(ms(r.switchToFront, \.p50)) | \(ms(r.switchToFront, \.p99)) | \(r.failedOpens + r.failedSwitches) |"
    }
}
