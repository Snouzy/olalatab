import CoreGraphics
import Foundation
import os

/// Monotonic clock in nanoseconds, same time base as keyboard event timestamps (time since boot,
/// excluding sleep).
enum Clock {
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Carbon `EventTime`: seconds since boot.
    static func nanos(eventTime seconds: Double) -> UInt64 { UInt64(seconds * 1e9) }

    /// `CGEventTimestamp`: nanoseconds since boot on Apple Silicon (checked against
    /// CLOCK_UPTIME_RAW; the headers don't say). `millis(from:to:)` rejects anything implausible.
    static func nanos(eventTimestamp: CGEventTimestamp) -> UInt64 { eventTimestamp }

    /// Time from `start` to `end` in milliseconds, or nil when the start time is implausible
    /// (in the future, or more than a second ago): the caller then uses its own start time.
    static func millis(from start: UInt64, to end: UInt64) -> Double? {
        guard start <= end, end - start < 1_000_000_000 else { return nil }
        return Double(end - start) / 1e6
    }
}

let signposter = OSSignposter(subsystem: "io.github.olalatab", category: .pointsOfInterest)

private let timestampFormatter = ISO8601DateFormatter()
var debugLogging = false

func log(_ message: String) {
    print("[\(timestampFormatter.string(from: Date()))] \(message)")
}

func debugLog(_ message: @autoclosure () -> String) {
    if debugLogging { log(message()) }
}
