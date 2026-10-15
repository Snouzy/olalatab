import AppKit
import OlalaCore

/// The switcher window: created and put on screen once at launch, then never taken off. Between
/// uses it is fully transparent and lets clicks through; opening it is a redraw of the rows and
/// an alpha change. Ordering a window out lets the system drop its surfaces, and putting it back
/// cost 10 to 35 ms whenever the switcher had been idle for a second or more.
///
/// It never becomes key or active: the front app keeps focus while the user picks a window.
/// The list is one view that draws only its visible rows with Core Text, so 300 windows cost
/// the same to show as 12. (An NSTableView with NSTextField cells cost ~0.4 ms per visible row
/// to lay out and draw, and a blurred NSVisualEffectView background made every frame slower as
/// more windows sat behind it: see the README.)
final class SwitcherPanel: NSPanel {
    static let width: CGFloat = 640

    /// A click on a row (row index).
    var onClick: ((Int) -> Void)? {
        get { list.onClick }
        set { list.onClick = newValue }
    }

    private let list = WindowListView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = list
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Puts the (invisible) panel on screen once, drawn, so the first real opening doesn't pay for
    /// font loading or the backing store either.
    func warmUp() {
        hide()
        layOut((0..<WindowListView.maxVisibleRows).map { "Warm-up \($0)" }, icon: nil, selected: 0,
               on: NSScreen.main ?? NSScreen.screens[0])
        orderFrontRegardless()
        displayIfNeeded()
    }

    /// Draws the new rows, hands them to the WindowServer, and only then makes the panel opaque,
    /// so the previous list never flashes.
    /// Returns how long each step took, in milliseconds: layout, draw, flush, alpha.
    @discardableResult
    func show(_ titles: [String], icon: CGImage?, selected: Int, on screen: NSScreen) -> [Double] {
        var marks = [Clock.now()]
        layOut(titles, icon: icon, selected: selected, on: screen)
        marks.append(Clock.now())
        displayIfNeeded()
        marks.append(Clock.now())
        CATransaction.flush()
        marks.append(Clock.now())
        ignoresMouseEvents = false
        alphaValue = 1
        marks.append(Clock.now())
        return zip(marks.dropFirst(), marks).map { Double($0 - $1) / 1e6 }
    }

    func hide() {
        alphaValue = 0
        ignoresMouseEvents = true
    }

    private func layOut(_ titles: [String], icon: CGImage?, selected: Int, on screen: NSScreen) {
        list.update(titles: titles, icon: icon, selected: selected)
        let size = NSSize(width: Self.width, height: list.preferredHeight)
        let visible = screen.visibleFrame
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(),
                           y: (visible.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        if frame != self.frame { setFrame(frame, display: false) }
    }

    func select(_ row: Int) {
        list.select(row)
    }
}

/// Draws the visible rows (icon, title, selection) directly; keeps the selection in view.
private final class WindowListView: NSView {
    static let rowHeight: CGFloat = 30
    static let maxVisibleRows = 12
    static let inset: CGFloat = 8
    static let iconSize: CGFloat = 20
    static let textX: CGFloat = 46
    static let font = NSFont.systemFont(ofSize: 13)

    var onClick: ((Int) -> Void)?

    private var titles: [String] = []
    private var icon: CGImage?
    private var selected = 0
    private var firstVisible = 0

    var preferredHeight: CGFloat {
        CGFloat(min(titles.count, Self.maxVisibleRows)) * Self.rowHeight + 2 * Self.inset
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(titles: [String], icon: CGImage?, selected: Int) {
        self.titles = titles
        self.icon = icon
        firstVisible = 0
        select(selected)
        needsDisplay = true
    }

    func select(_ row: Int) {
        guard titles.indices.contains(row) else { return }
        let previous = (selected, firstVisible)
        selected = row
        if row < firstVisible { firstVisible = row }
        if row >= firstVisible + Self.maxVisibleRows { firstVisible = row - Self.maxVisibleRows + 1 }
        if firstVisible != previous.1 {
            needsDisplay = true
        } else {
            setNeedsDisplay(rowRect(previous.0))
            setNeedsDisplay(rowRect(row))
        }
    }

    override func mouseDown(with event: NSEvent) {
        debugLog("mouse down at \(convert(event.locationInWindow, from: nil)), click count \(event.clickCount)")
        let y = convert(event.locationInWindow, from: nil).y - Self.inset
        guard y >= 0 else { return }
        let row = firstVisible + Int(y / Self.rowHeight)
        if titles.indices.contains(row) { onClick?(row) }
    }

    private func rowRect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: Self.inset + CGFloat(row - firstVisible) * Self.rowHeight,
               width: bounds.width, height: Self.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let background = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        context.clear(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        background.fill()

        let last = min(titles.count, firstVisible + Self.maxVisibleRows)
        for row in firstVisible..<last {
            let rect = rowRect(row)
            guard rect.intersects(dirtyRect) else { continue }
            let isSelected = row == selected
            if isSelected {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
            if let icon {
                let iconRect = CGRect(x: 16, y: rect.minY + (Self.rowHeight - Self.iconSize) / 2,
                                      width: Self.iconSize, height: Self.iconSize)
                // The context is flipped: draw the image upright.
                context.saveGState()
                context.translateBy(x: 0, y: iconRect.maxY + iconRect.minY)
                context.scaleBy(x: 1, y: -1)
                context.draw(icon, in: iconRect)
                context.restoreGState()
            }
            drawTitle(titles[row], in: rect, selected: isSelected, context: context)
        }
    }

    private func drawTitle(_ title: String, in rect: NSRect, selected: Bool, context: CGContext) {
        let color: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let text = NSAttributedString(string: title.isEmpty ? "Sans titre" : title,
                                      attributes: [.font: Self.font, .foregroundColor: color])
        let width = bounds.width - Self.textX - 16
        var line = CTLineCreateWithAttributedString(text)
        if CTLineGetTypographicBounds(line, nil, nil, nil) > width {
            let ellipsis = CTLineCreateWithAttributedString(
                NSAttributedString(string: "…", attributes: [.font: Self.font, .foregroundColor: color]))
            line = CTLineCreateTruncatedLine(line, width, .end, ellipsis) ?? line
        }
        let baseline = rect.minY + (Self.rowHeight + Self.font.capHeight) / 2
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: Self.textX, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
