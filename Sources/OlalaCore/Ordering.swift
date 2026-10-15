import Foundation

/// How the switcher lists windows. Every order is total (ties broken by window ID), so the list
/// never reshuffles between two presses unless a window actually changed.
public enum WindowOrder: String, Codable, CaseIterable {
    /// Oldest window first (increasing `CGWindowID`). Stable: using a window doesn't move it.
    case creation
    /// Most recently used first (the WindowServer's front-to-back order), like ⌘⇥.
    case recent
    /// Alphabetical, ignoring case and accents, numbers compared as numbers; untitled windows last.
    case title
    /// Reading order on screen: top to bottom, then left to right.
    case position

    public func sorted(_ windows: [WindowInfo]) -> [WindowInfo] {
        switch self {
        case .creation:
            return windows.sorted { $0.id < $1.id }
        case .recent:
            return windows.sorted { ($0.zIndex, $0.id) < ($1.zIndex, $1.id) }
        case .title:
            return windows.sorted { a, b in
                if a.title.isEmpty != b.title.isEmpty { return b.title.isEmpty }
                switch a.title.compare(b.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric]) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.id < b.id
                }
            }
        case .position:
            return windows.sorted { a, b in
                (a.frame.minY, a.frame.minX, a.id) < (b.frame.minY, b.frame.minX, b.id)
            }
        }
    }
}
