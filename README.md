<img src=".github/assets/icon.svg" width="72" alt="">

# olalatab

⌥ Option + Tab shows the windows of the app in front and switches to the one you pick. Like ⌘⇥, but for windows, and fast: measured below with up to 300 windows open.

One small background app, one optional JSON file, no Dock icon, no network. The code is free software under the MIT license.

[![License: MIT](https://img.shields.io/badge/license-MIT-141a2e)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-2346d8)](#run-it)
[![CI](https://github.com/Snouzy/olalatab/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Snouzy/olalatab/actions/workflows/ci.yml)

## How it works

```
⌥⇥ ─Carbon hot key─▶ window list ─▶ panel ─▶ key tap (only while open) ─▶ focus
                     (WindowServer)  (Core Text)  Tab ⇧Tab Esc ⌥-release     (SkyLight)
```

- **At rest it does nothing.** ⌥⇥ is a Carbon global hot key: the WindowServer matches it, so olalatab sees no keyboard event while you type and never wakes up. The keyboard tap that follows Tab, ⇧Tab, Escape and the ⌥ release is enabled only while the panel is open, on its own thread, with an O(1) callback.
- **The list is one WindowServer call.** `CGWindowListCopyWindowInfo` (current Space, on screen, so minimized windows are left out), filtered on the front app's PID. Titles come from the same call (Screen Recording permission), not from Accessibility, so a busy app can't slow the list down.
- **The panel exists before you press.** A non-activating `NSPanel` is created at launch and stays on screen, fully transparent and letting clicks through. Opening it redraws the visible rows (12 at most, with Core Text) and makes it opaque, so the system never has to rebuild its surfaces; the front app keeps focus while you choose. olalatab also opts out of App Nap, which otherwise throttles it after a few seconds idle.
- **Switching talks to the WindowServer, not to the app.** `_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo` bring the app forward with that window key, as yabai and AltTab do. `AXRaise` then puts the window above the app's other windows, from a background queue with a 50 ms timeout: a frozen app can't block olalatab.

A quick ⌥⇥ (press and release) switches to the next window without showing the panel. With a single window the panel still shows it, so you can see the switcher answered.

## Run it

```sh
make install
```

Swift 5.9 or later (Xcode or the Command Line Tools) on macOS 13 or later. This builds `~/Applications/Olalatab.app`, writes a default config and registers a LaunchAgent, so olalatab **starts by itself at login** and restarts if it crashes.

Then, once: `make permissions` opens System Settings. Allow `Olalatab.app` in **Accessibility** (to see Tab and ⌥ while the panel is open, and raise windows) and in **Screen Recording** (to read window titles; olalatab never captures the screen). Then `make restart`.

| Command | What it does |
|---|---|
| `make restart` | Reload after editing the config or granting permission |
| `make stop` | Stop it until the next login or `make restart` |
| `make logs` | Follow the log (`~/Library/Logs/olalatab.log`) |
| `make test` | Unit tests, no keyboard needed |
| `make bench` | Latency benchmark (takes over the keyboard and screen for ~10 minutes) |
| `make idle` | CPU, wake-ups and memory at rest |
| `make uninstall` | Remove the app and the LaunchAgent, keep the config |

`olalatab --debug` logs each opening with its timings.

## Configure

`~/.config/olalatab/config.json`, then `make restart`:

```json
{ "order": "creation" }
```

| `order` | Windows listed |
|---|---|
| `creation` (default) | oldest first. Stable: using a window doesn't move it |
| `recent` | most recently used first, like ⌘⇥ |
| `title` | alphabetically, ignoring case and accents; untitled windows last |
| `position` | in reading order on screen: top to bottom, then left to right |

In the panel: Tab / ↓ / → next, ⇧Tab / ↑ / ← previous, release ⌥ or Return to switch, Escape to cancel, or click a row.

## Performance

> These figures were measured before three later fixes: the panel now stays on screen instead of being hidden, key releases always pass through the tap, and App Nap is off. With presses ~1.5 s apart, as a person types, openings that took 16 to 36 ms before the first fix now mostly stay under 16 ms. `make bench` now also runs spaced cases (`TextEdit-100-spaced`, `Chrome-100-spaced`) to measure exactly that.

Measured on an M5 Max (macOS 26.6, 120 Hz display), 200 ⌥⇥ presses per case, posted as real keyboard events by `make bench`. Each press goes through the whole path: hot key, window list, panel, key tap, one more Tab, ⌥ release, switch. A frozen app (`SIGSTOP`) sits in the background during every case. Times in milliseconds.

| Case | Windows | Open p50 | Open p99 | List p50 | List p99 | Switch p50 | Switch p99 | Failures |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| TextEdit | 10 | 3.01 | 6.61 | 0.96 | 4.52 | 22.1 | 38.6 | 0 |
| Chrome | 10 | 3.08 | 5.30 | 0.95 | 3.55 | 22.5 | 25.7 | 0 |
| TextEdit | 100 | **3.14** | **6.10** | 1.47 | 2.16 | 35.7 | 51.8 | 0 |
| Chrome | 100 | **3.54** | **13.52** | 1.92 | 2.49 | 42.8 | 85.0 | 0 |
| TextEdit | 300 | 5.77 | 12.61 | 3.70 | 10.47 | 94.7 | 195.4 | 0 |
| Chrome | 300 | 6.05 | 17.90 | 3.85 | 12.08 | 94.4 | 217.7 | 28 switches > 1 s |
| Frozen app (`SIGSTOP`) | 3 | 3.46 | 11.66 | 1.04 | 3.15 | – | – | 50 switches (expected) |

- **Open**: from the timestamp of the ⌥⇥ key event to the panel's frame handed to the WindowServer (`CATransaction.flush`). The WindowServer shows it at the next refresh, up to 8.3 ms later at 120 Hz; that part is the same for any app and isn't counted. Delivery of the key event to olalatab is ~0.05 ms.
- **List**: the `CGWindowListCopyWindowInfo` call plus filtering and sorting, included in Open.
- **Switch**: from the ⌥ release event until the chosen window is the front-most window in the WindowServer's list. olalatab's own part ends 1.5 ms after the release (it has asked SkyLight for the switch). The rest is the WindowServer and the target app reordering their windows, and it grows with the app's window count. Those 28 Chrome switches took more than the bench's 1 s limit; no opening failed.
- **Frozen app**: the switcher opens just as fast on a hung app, and nothing ever waits on it (Accessibility calls are off the main thread with a 50 ms timeout). Switching *to* a frozen app's window can't complete, since the app itself has to process it: those are the 50 failures.

Targets: panel visible in < 8 ms p50 and < 16 ms p99 with 100 windows, met with both apps. At 300 windows p50 stays under 8 ms; Chrome's p99 is 17.9 ms, just over 16, and most of it is the WindowServer call listing 300+ windows.

**At rest** (`make idle`, 60 s): 0.0 % CPU, 2 wake-ups a minute, 0 s of CPU time. Memory footprint 18 MB, of which 7.5 MB are the panel's surfaces, kept between two openings so they don't have to be recreated: freeing them would save memory at the cost of every opening.

What made it fast, measured during development on the fixture app with 100 windows (30 to 60 presses per row, so the p99 is rougher than above):

| Change | Open p50 | Open p99 |
|---|---:|---:|
| `NSTableView` + `NSTextField` cells on a blurred `NSVisualEffectView` | 16.05 | 28.26 |
| One view drawing only the visible rows with Core Text, opaque background | 3.07 | 7.55 |
| Key tap and Accessibility prefetch moved after the frame is sent | 3.44 | 4.39 |

The table cost about 0.4 ms per visible row to lay out and draw, and the blur made each frame slower as more windows sat behind the panel. Tried and dropped: listing only the front app's windows with the private `SLSGetOnScreenWindowList` and then `CGWindowListCreateDescriptionFromArray`. At 300 windows it took 4.5 ms against 2.8 ms for the public call. A cache maintained from Accessibility notifications (the plan's variant b) was not built: the on-demand call already meets the target, and it would keep olalatab talking to apps in the background.

## Private API

Each private symbol is resolved at run time with `dlsym` ([`CSkyLight.h`](Sources/CSkyLight/include/CSkyLight.h)): if a macOS update removes one, olalatab falls back to public API instead of failing to start.

| Symbol | Framework | Used for | Fallback |
|---|---|---|---|
| `_SLPSSetFrontProcessWithOptions` | SkyLight | bring the app forward on a given window | `NSRunningApplication.activate` |
| `SLPSPostEventRecordTo` | SkyLight | make that window key (two synthetic event records, layout from yabai) | same |
| `_AXUIElementGetWindow` | HIServices | match an Accessibility window to its `CGWindowID`, to raise the right one | window not raised above its siblings |
| `GetProcessForPID` | HIServices | PID → process serial number for the two SkyLight calls (public, but unavailable to Swift) | same as above |

## Repository

- `Sources/OlalaCore/`: window filtering, the four orders, Tab cycling, config, percentiles. No AppKit, fully unit-tested.
- `Sources/olalatab/`: hot key, key tap, panel, focusing, Accessibility prefetch, and the in-app benchmark.
- `Sources/CSkyLight/`: the C bridge to the private symbols.
- `Sources/olala-fixture/`: a tiny app with N windows, used by the benchmark (and frozen with `SIGSTOP`).
- `bench/`: `run.sh` (latency) and `idle.sh` (CPU and memory at rest).
- `support/`: the app's `Info.plist` and the LaunchAgent template.

## Caveats

- SkyLight is private Apple API. AltTab and yabai rely on the same calls, but a macOS update could change them; olalatab then falls back to public activation.
- `make install` signs the app with your Apple Development or Developer ID certificate when your keychain has one, and macOS keeps both permissions across updates. Without one the app is signed ad hoc: after each update, turn it off and on in both lists, then `make restart`.
- Only windows on the current Space are listed, by design. Minimized windows aren't either.

## License

Copyright (C) 2026 Snouzy and the olalatab contributors. [MIT](LICENSE).
