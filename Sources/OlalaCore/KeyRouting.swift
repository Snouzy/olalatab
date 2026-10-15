import Carbon.HIToolbox
import CoreGraphics

/// What the switcher does with a keyboard event while its panel is open.
public enum SwitcherCommand: Equatable {
    case next, previous, commit, cancel
}

/// The key tap's rules, kept apart from the tap so they are tested without a keyboard.
public enum KeyRouting {
    public struct Decision: Equatable {
        public var command: SwitcherCommand?
        /// True to keep the event from reaching the app behind the panel.
        public var swallow: Bool

        public init(command: SwitcherCommand?, swallow: Bool) {
            self.command = command
            self.swallow = swallow
        }
    }

    /// Key presses drive the selection and never reach the app behind the panel. Releasing ⌥
    /// switches. Everything else, key releases included, passes through untouched: the
    /// WindowServer only re-arms the ⌥⇥ hot key once it has seen Tab come back up, so swallowing
    /// that release made the next ⌥⇥ do nothing.
    public static func route(_ type: CGEventType, keyCode: Int, flags: CGEventFlags) -> Decision {
        switch type {
        case .flagsChanged:
            return Decision(command: flags.contains(.maskAlternate) ? nil : .commit, swallow: false)
        case .keyDown:
            let command: SwitcherCommand?
            switch keyCode {
            case kVK_Tab: command = flags.contains(.maskShift) ? .previous : .next
            case kVK_DownArrow, kVK_RightArrow: command = .next
            case kVK_UpArrow, kVK_LeftArrow: command = .previous
            case kVK_Return, kVK_ANSI_KeypadEnter: command = .commit
            case kVK_Escape: command = .cancel
            default: command = nil
            }
            return Decision(command: command, swallow: true)
        default:
            return Decision(command: nil, swallow: false)
        }
    }
}
