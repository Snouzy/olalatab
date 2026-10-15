import CoreGraphics
import Foundation

/// One window of the front app, as reported by the WindowServer.
public struct WindowInfo: Equatable {
    /// `CGWindowID`. The WindowServer hands them out in increasing order, so it doubles as creation order.
    public var id: UInt32
    public var pid: pid_t
    /// `kCGWindowName`; empty when the app gives none (or without Screen Recording permission).
    public var title: String
    /// Global coordinates, origin at the top-left of the main display (Core Graphics convention).
    public var frame: CGRect
    /// Position in the WindowServer's front-to-back list: 0 is the front-most.
    public var zIndex: Int

    public init(id: UInt32, pid: pid_t, title: String, frame: CGRect, zIndex: Int) {
        self.id = id
        self.pid = pid
        self.title = title
        self.frame = frame
        self.zIndex = zIndex
    }
}

public enum WindowFilter {
    /// Windows smaller than this on either side are helper windows (tooltips, drag images), not documents.
    public static let minimumSide: CGFloat = 20

    private static let pidKey = kCGWindowOwnerPID as NSString
    private static let layerKey = kCGWindowLayer as NSString
    private static let alphaKey = kCGWindowAlpha as NSString
    private static let boundsKey = kCGWindowBounds as NSString
    private static let numberKey = kCGWindowNumber as NSString
    private static let nameKey = kCGWindowName as NSString

    /// Keeps the normal windows of `pid` from `CGWindowListCopyWindowInfo` output, front-most first.
    /// Reads the dictionaries through `NSDictionary` without bridging them to Swift: with hundreds of
    /// windows on screen, only the owner PID of the other apps' windows is ever looked at.
    public static func windows(in list: NSArray, pid: pid_t) -> [WindowInfo] {
        var result: [WindowInfo] = []
        for (z, element) in list.enumerated() {
            guard let window = element as? NSDictionary,
                  (window.object(forKey: pidKey) as? NSNumber)?.int32Value == pid,
                  (window.object(forKey: layerKey) as? NSNumber)?.intValue == 0,
                  (window.object(forKey: alphaKey) as? NSNumber)?.doubleValue ?? 1 > 0,
                  let boundsDict = window.object(forKey: boundsKey) as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= minimumSide, frame.height >= minimumSide,
                  let id = (window.object(forKey: numberKey) as? NSNumber)?.uint32Value
            else { continue }
            let title = window.object(forKey: nameKey) as? String ?? ""
            result.append(WindowInfo(id: id, pid: pid, title: title, frame: frame, zIndex: z))
        }
        return result
    }
}
