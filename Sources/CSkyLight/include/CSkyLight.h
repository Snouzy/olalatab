// Private macOS symbols used by olalatab, resolved at run time with dlsym so that a missing
// symbol makes olalatab fall back to public API instead of failing to launch.
//
//   _SLPSSetFrontProcessWithOptions  SkyLight   Brings a process to the front with a given window
//                                               as its front window (what the Dock and ⌘⇥ use).
//   SLPSPostEventRecordTo            SkyLight   Posts a raw WindowServer event record to a process;
//                                               olalatab posts the two records that make a window key.
//   _AXUIElementGetWindow            HIServices CGWindowID of an Accessibility window element.
//   GetProcessForPID                 HIServices PID → ProcessSerialNumber (public but marked
//                                               unavailable to Swift, so it is resolved here too).
//
// The same calls are used by yabai and AltTab; the event record layout comes from yabai
// (window_manager_make_key_window).
#pragma once
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

/// True when every symbol needed by olala_focus_window was found.
bool olala_focus_available(void);

/// Makes `pid` the front process with window `wid` key, without involving the target app's
/// main thread for the ordering. Returns false when a symbol is missing or a call fails.
bool olala_focus_window(pid_t pid, uint32_t wid);

/// CGWindowID of an Accessibility window element, or 0 when unknown.
uint32_t olala_ax_window_id(AXUIElementRef element);
