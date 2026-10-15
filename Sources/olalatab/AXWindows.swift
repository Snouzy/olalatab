import ApplicationServices
import CSkyLight
import Foundation

/// Accessibility elements of the front app's windows, fetched off the main thread.
///
/// AX calls are IPC to the target app's main thread: a busy or frozen app makes them wait. They
/// all run on one background queue with a 50 ms timeout, so the switcher itself never waits on
/// an app. Only used to raise the chosen window above the app's other windows.
final class AXWindows {
    static let timeout: Float = 0.05

    private let queue = DispatchQueue(label: "io.github.olalatab.ax", qos: .userInteractive)
    // Only touched on `queue`.
    private var pid: pid_t = 0
    private var elements: [UInt32: AXUIElement] = [:]

    init() {
        // Applies to every element created afterwards.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.timeout)
    }

    /// Starts fetching while the user picks a window: it is ready long before ⌥ is released.
    func prefetch(_ pid: pid_t) {
        queue.async { self.load(pid) }
    }

    /// Raises the window above its app's other windows, once the prefetch is done.
    func raise(pid: pid_t, windowID: UInt32) {
        queue.async {
            if self.pid != pid || self.elements[windowID] == nil { self.load(pid) }
            guard let element = self.elements[windowID] else { return }
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }

    private func load(_ pid: pid_t) {
        self.pid = pid
        elements = [:]
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windows = value as? [AXUIElement] else {
            debugLog("AX windows of \(pid): error \(status.rawValue)")
            return
        }
        for window in windows {
            let id = olala_ax_window_id(window)
            if id != 0 { elements[id] = window }
        }
    }
}
