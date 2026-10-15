import AppKit
import CSkyLight
import Foundation
import OlalaCore

let usage = """
usage: olalatab [--config <path>] [--debug] [--print-default-config]
       olalatab --bench [--iterations N] [--label L] [--target-pid P] [--expect-windows N] [--freeze-target] [--out file.json]

  --config <path>          Config file (default: ~/.config/olalatab/config.json)
  --debug                  Log every opening with its timings
  --print-default-config   Print the built-in config as JSON and exit
  --bench                  Post real ⌥⇥ presses to the front app (or --target-pid) and report
                           p50 / p99 latencies; olalatab must not already be running
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("olalatab: \(message)\n".utf8))
    exit(1)
}

// Under launchd stdout is a file: flush each line so the log is readable live.
setvbuf(stdout, nil, _IOLBF, 0)

var configURL = Config.defaultURL
var benchOptions: Bench.Options?
var args = CommandLine.arguments.dropFirst()
func value(for flag: String) -> String {
    guard let value = args.popFirst() else { fail("\(flag) needs a value") }
    return value
}
while let arg = args.popFirst() {
    switch arg {
    case "--config": configURL = URL(fileURLWithPath: (value(for: arg) as NSString).expandingTildeInPath)
    case "--debug": debugLogging = true
    case "--print-default-config":
        print(try Config.default.jsonString())
        exit(0)
    case "--bench": benchOptions = benchOptions ?? Bench.Options()
    case "--iterations": benchOptions = benchOptions ?? .init(); benchOptions!.iterations = Int(value(for: arg)) ?? 200
    case "--label": benchOptions = benchOptions ?? .init(); benchOptions!.label = value(for: arg)
    case "--target-pid": benchOptions = benchOptions ?? .init(); benchOptions!.targetPID = pid_t(value(for: arg))
    case "--expect-windows": benchOptions = benchOptions ?? .init(); benchOptions!.expectWindows = Int(value(for: arg)) ?? 2
    case "--freeze-target": benchOptions = benchOptions ?? .init(); benchOptions!.freezeTarget = true
    case "--out": benchOptions = benchOptions ?? .init(); benchOptions!.out = URL(fileURLWithPath: value(for: arg))
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        fail("unknown argument \(arg)\n\(usage)")
    }
}

let config: Config
if FileManager.default.fileExists(atPath: configURL.path) {
    do { config = try Config.load(from: configURL) } catch { fail("invalid config \(configURL.path): \(error)") }
} else {
    config = .default
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// App Nap throttles a background app with no visible window: after ~30 s idle, the first ⌥⇥ took
// ~60 ms instead of ~3 ms. Opting out costs nothing at rest, since olalatab has no timer to fire.
let noAppNap = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "⌥⇥ must answer within a frame")

let accessibility = AXIsProcessTrusted()
let screenRecording = CGPreflightScreenCaptureAccess()
log("Permissions: accessibility \(accessibility ? "yes" : "no"), screen recording (window titles) \(screenRecording ? "yes" : "no"), SkyLight focus \(olala_focus_available() ? "yes" : "no").")
if !screenRecording { CGRequestScreenCaptureAccess() }

let switcher = Switcher(config: config)
let hotKey = HotKey { backwards, eventTime in switcher.hotKeyPressed(backwards: backwards, eventTime: eventTime) }
guard hotKey.register() else { fail("⌥⇥ is already taken (is olalatab already running? make stop / launchctl bootout)") }
log("olalatab running: ⌥⇥, order \(config.order.rawValue).")

if let options = benchOptions {
    Task { @MainActor in
        let report = await Bench(switcher: switcher, options: options).run()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let out = options.out, let data = try? encoder.encode(report) {
            try? data.write(to: out)
        }
        print(Bench.markdownRow(report))
        exit(report.iterations > 0 ? 0 : 1)
    }
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalSources = [SIGINT, SIGTERM].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { exit(0) }
    source.resume()
    return source
}

app.run()
