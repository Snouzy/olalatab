import AppKit

// A plain app with a few windows, used by the bench: as a stable target, and frozen with
// SIGSTOP to check that a hung app never blocks olalatab.
let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 3
let app = NSApplication.shared
app.setActivationPolicy(.regular)
var windows: [NSWindow] = []
for i in 1...count {
    let window = NSWindow(contentRect: NSRect(x: 120 + 40 * i, y: 200 + 30 * i, width: 480, height: 320),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Fixture \(i)"
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
}
app.activate(ignoringOtherApps: true)
app.run()
