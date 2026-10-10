import Foundation

/// Monotonic microsecond clock. Only differences on the same device are meaningful;
/// cross-device values are used only as "relative one-way delay" (see `DelayTracker`).
public enum LinkClock {
    @inline(__always)
    public static func nowUs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000
    }
    @inline(__always)
    public static func nowUs32() -> UInt32 { UInt32(truncatingIfNeeded: nowUs()) }

    /// Wrap-safe difference `a - b` of two 32-bit microsecond timestamps.
    @inline(__always)
    public static func diff32(_ a: UInt32, _ b: UInt32) -> Int32 { Int32(bitPattern: a &- b) }
}
