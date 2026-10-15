import Carbon.HIToolbox
import CoreGraphics
import Foundation
import XCTest
@testable import OlalaCore

private func window(_ id: UInt32, _ title: String = "", z: Int = 0,
                    x: CGFloat = 0, y: CGFloat = 0, pid: pid_t = 42) -> WindowInfo {
    WindowInfo(id: id, pid: pid, title: title, frame: CGRect(x: x, y: y, width: 400, height: 300), zIndex: z)
}

private func cgEntry(id: UInt32, pid: pid_t = 42, layer: Int = 0, alpha: Double = 1,
                     width: CGFloat = 400, height: CGFloat = 300, title: String? = "Doc") -> NSDictionary {
    var d: [String: Any] = [
        kCGWindowNumber as String: id,
        kCGWindowOwnerPID as String: pid,
        kCGWindowLayer as String: layer,
        kCGWindowAlpha as String: alpha,
        kCGWindowBounds as String: CGRect(x: 10, y: 20, width: width, height: height).dictionaryRepresentation,
    ]
    if let title { d[kCGWindowName as String] = title }
    return d as NSDictionary
}

final class OrderingTests: XCTestCase {
    let windows = [
        window(30, "beta", z: 0, x: 500, y: 0),
        window(10, "Écran 10", z: 2, x: 0, y: 400),
        window(20, "", z: 1, x: 0, y: 0),
        window(40, "ecran 9", z: 3, x: 100, y: 400),
    ]

    func ids(_ order: WindowOrder) -> [UInt32] { order.sorted(windows).map(\.id) }

    func testCreationIsIncreasingWindowID() {
        XCTAssertEqual(ids(.creation), [10, 20, 30, 40])
    }

    func testRecentIsFrontToBack() {
        XCTAssertEqual(ids(.recent), [30, 20, 10, 40])
    }

    func testTitleIgnoresCaseAndAccentsComparesNumbersAndPutsUntitledLast() {
        XCTAssertEqual(ids(.title), [30, 40, 10, 20])
    }

    func testTitleTiesAreBrokenByID() {
        let same = [window(5, "Doc"), window(3, "doc"), window(4, "DOC")]
        XCTAssertEqual(WindowOrder.title.sorted(same).map(\.id), [3, 4, 5])
    }

    func testPositionIsTopToBottomThenLeftToRight() {
        XCTAssertEqual(ids(.position), [20, 30, 10, 40])
    }

    func testEveryOrderIsStableAcrossInputPermutations() {
        for order in WindowOrder.allCases {
            XCTAssertEqual(order.sorted(windows.reversed()).map(\.id), ids(order), "\(order)")
        }
    }
}

final class SelectionTests: XCTestCase {
    func testNoSelectionWithoutWindows() {
        XCTAssertNil(Selection(windows: []))
    }

    func testSingleWindowStaysSelected() {
        var s = Selection(windows: [window(1)])!
        XCTAssertEqual(s.index, 0)
        s.next(); XCTAssertEqual(s.index, 0)
        s.previous(); XCTAssertEqual(s.index, 0)
        XCTAssertEqual(Selection(windows: [window(1)], backwards: true)?.index, 0)
    }

    func testStartsAfterTheActiveWindow() {
        // Active window (z 0) is in the middle of the list.
        let list = [window(1, z: 2), window(2, z: 0), window(3, z: 1)]
        XCTAssertEqual(Selection(windows: list)?.index, 2)
        XCTAssertEqual(Selection(windows: list, backwards: true)?.index, 0)
    }

    func testStartWrapsAroundWhenActiveIsLast() {
        let list = [window(1, z: 1), window(2, z: 2), window(3, z: 0)]
        XCTAssertEqual(Selection(windows: list)?.index, 0)
    }

    func testQuickSwitchInRecentOrderGoesToPreviousWindow() {
        let list = WindowOrder.recent.sorted([window(1, z: 1), window(2, z: 0), window(3, z: 2)])
        let selection = Selection(windows: list)!
        XCTAssertEqual(list[selection.index].id, 1)
    }

    func testTabAndShiftTabCycleAndWrap() {
        var s = Selection(windows: [window(1, z: 0), window(2, z: 1), window(3, z: 2)])!
        XCTAssertEqual(s.index, 1)
        s.next(); XCTAssertEqual(s.index, 2)
        s.next(); XCTAssertEqual(s.index, 0)
        s.previous(); XCTAssertEqual(s.index, 2)
        s.previous(); s.previous(); s.previous(); XCTAssertEqual(s.index, 2)
    }

    func testTwoWindowsToggle() {
        var s = Selection(windows: [window(1, z: 0), window(2, z: 1)])!
        XCTAssertEqual(s.index, 1)
        s.next(); XCTAssertEqual(s.index, 0)
        s.previous(); XCTAssertEqual(s.index, 1)
    }

    func testSelectIgnoresOutOfRangeRows() {
        var s = Selection(windows: [window(1, z: 0), window(2, z: 1)])!
        s.select(5); XCTAssertEqual(s.index, 1)
        s.select(0); XCTAssertEqual(s.index, 0)
    }
}

final class FilterTests: XCTestCase {
    func testKeepsOnlyNormalWindowsOfThePidInZOrder() {
        let list: NSArray = [
            cgEntry(id: 1, layer: 25),          // menu bar item
            cgEntry(id: 2, pid: 7),             // other app
            cgEntry(id: 3, title: "Front"),
            cgEntry(id: 4, alpha: 0),           // invisible
            cgEntry(id: 5, width: 5),           // helper window
            cgEntry(id: 6, title: nil),         // untitled
            cgEntry(id: 7, height: 1),
        ]
        let result = WindowFilter.windows(in: list, pid: 42)
        XCTAssertEqual(result.map(\.id), [3, 6])
        XCTAssertEqual(result.map(\.title), ["Front", ""])
        XCTAssertEqual(result.map(\.zIndex), [2, 5])
        XCTAssertEqual(result[0].frame, CGRect(x: 10, y: 20, width: 400, height: 300))
    }

    func testIgnoresMalformedEntries() {
        let list: NSArray = ["garbage", [kCGWindowOwnerPID as String: 42] as NSDictionary, cgEntry(id: 9)]
        XCTAssertEqual(WindowFilter.windows(in: list, pid: 42).map(\.id), [9])
    }
}

final class ConfigTests: XCTestCase {
    func testMissingFieldsUseDefaults() throws {
        XCTAssertEqual(try Config.decode(Data("{}".utf8)), Config(order: .creation))
    }

    func testDecodesEveryOrder() throws {
        for order in WindowOrder.allCases {
            XCTAssertEqual(try Config.decode(Data("{\"order\":\"\(order.rawValue)\"}".utf8)).order, order)
        }
    }

    func testUnknownOrderIsAClearError() {
        XCTAssertThrowsError(try Config.decode(Data("{\"order\":\"zorder\"}".utf8))) { error in
            XCTAssertEqual("\(error)", "\"order\" must be one of: creation, recent, title, position")
        }
    }

    func testDefaultConfigRoundTrips() throws {
        let json = try Config.default.jsonString()
        XCTAssertEqual(try Config.decode(Data(json.utf8)), Config.default)
    }
}

final class PercentilesTests: XCTestCase {
    func testNearestRank() {
        let p = Percentiles((1...100).map(Double.init))!
        XCTAssertEqual(p.p50, 50)
        XCTAssertEqual(p.p99, 99)
        XCTAssertEqual(p.max, 100)
        XCTAssertEqual(p.count, 100)
    }

    func testSingleSampleAndEmpty() {
        XCTAssertEqual(Percentiles([3])?.p99, 3)
        XCTAssertNil(Percentiles([]))
    }
}

final class KeyRoutingTests: XCTestCase {
    func route(_ type: CGEventType, _ key: Int, _ flags: CGEventFlags = .maskAlternate) -> KeyRouting.Decision {
        KeyRouting.route(type, keyCode: key, flags: flags)
    }

    func testTabAndShiftTabMoveAndAreSwallowed() {
        XCTAssertEqual(route(.keyDown, kVK_Tab), .init(command: .next, swallow: true))
        XCTAssertEqual(route(.keyDown, kVK_Tab, [.maskAlternate, .maskShift]), .init(command: .previous, swallow: true))
        XCTAssertEqual(route(.keyDown, kVK_DownArrow).command, .next)
        XCTAssertEqual(route(.keyDown, kVK_UpArrow).command, .previous)
    }

    func testReturnCommitsEscapeCancelsOtherKeysAreSwallowed() {
        XCTAssertEqual(route(.keyDown, kVK_Return).command, .commit)
        XCTAssertEqual(route(.keyDown, kVK_Escape).command, .cancel)
        XCTAssertEqual(route(.keyDown, kVK_ANSI_A), .init(command: nil, swallow: true))
    }

    /// Regression: swallowing Tab's release left the WindowServer thinking ⌥⇥ was still held, so
    /// the next ⌥⇥ was ignored ("I have to do it twice").
    func testKeyReleasesAlwaysPassThrough() {
        for key in [kVK_Tab, kVK_Escape, kVK_Return, kVK_ANSI_A] {
            XCTAssertEqual(route(.keyUp, key), .init(command: nil, swallow: false), "key \(key)")
        }
    }

    func testReleasingOptionCommitsAndPassesThrough() {
        XCTAssertEqual(route(.flagsChanged, kVK_Option, []), .init(command: .commit, swallow: false))
        XCTAssertEqual(route(.flagsChanged, kVK_Shift, [.maskAlternate, .maskShift]), .init(command: nil, swallow: false))
    }
}
