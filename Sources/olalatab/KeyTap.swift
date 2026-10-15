import Carbon
import CoreGraphics
import Foundation
import OlalaCore
import os

/// Keyboard event tap that only runs while the switcher is open: Tab / ⇧Tab / arrows move the
/// selection, Return or releasing ⌥ switches, Escape cancels. Every other key press is swallowed
/// so it doesn't reach the app behind the panel.
///
/// Key releases are not even watched (see `KeyRouting` for why they must pass through).
///
/// The tap lives on its own thread: if the main thread is busy, keystrokes system-wide are not
/// held up behind it. The callback does O(1) work (read a key code, enqueue a command) and never
/// blocks.
final class KeyTap {
    /// Called on the main thread. `timestamp` is when the key event happened (nanoseconds since boot).
    var onCommand: ((SwitcherCommand, UInt64) -> Void)?

    private var port: CFMachPort?
    private let wanted = OSAllocatedUnfairLock(initialState: false)

    /// Creates the tap, disabled. Fails without Accessibility permission; `enable` retries.
    @discardableResult
    func install() -> Bool {
        if port != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: keyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        CGEvent.tapEnable(tap: port, enable: false)
        self.port = port
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "olalatab.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func enable() -> Bool {
        guard install(), let port else { return false }
        wanted.withLock { $0 = true }
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func disable() {
        wanted.withLock { $0 = false }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if wanted.withLock({ $0 }), let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let decision = KeyRouting.route(type, keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                                        flags: event.flags)
        if let command = decision.command { send(command, event) }
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func send(_ command: SwitcherCommand, _ event: CGEvent) {
        let timestamp = Clock.nanos(eventTimestamp: event.timestamp)
        DispatchQueue.main.async { [weak self] in self?.onCommand?(command, timestamp) }
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}
