/// Which row of the switcher is highlighted, and how Tab / ⇧Tab move it.
public struct Selection: Equatable {
    public let count: Int
    public private(set) var index: Int

    /// Starts on the window after the active one (the front-most in z order), or before it when
    /// `backwards`, so a quick ⌥⇥ goes to the next window. With a single window it stays on it:
    /// the panel still shows, so the user sees the switcher answered. Nil without windows.
    public init?(windows: [WindowInfo], backwards: Bool = false) {
        guard !windows.isEmpty else { return nil }
        count = windows.count
        let active = windows.indices.min { windows[$0].zIndex < windows[$1].zIndex }!
        index = active
        if backwards { previous() } else { next() }
    }

    public mutating func next() {
        index = (index + 1) % count
    }

    public mutating func previous() {
        index = (index + count - 1) % count
    }

    public mutating func select(_ row: Int) {
        if (0..<count).contains(row) { index = row }
    }
}
