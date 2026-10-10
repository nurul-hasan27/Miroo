import Foundation

/// A clock for loss-detection timers that (almost) stops while the link is dead.
///
/// Wi-Fi regularly stalls for 50-150 ms: every packet in that window is lost or delayed, including our repair
/// requests. Timers running on the wall clock expire *during* the outage, so by the time the link returns the receiver
/// has already given up on frames that a repair could still fix. This clock runs at full speed while packets arrive
/// and at 1/20 speed after `thresholdUs` of silence, so repair attempts get their full time budget after the stall.
public struct OutageClock {
    public let thresholdUs: UInt64
    private var virtual: UInt64 = 0
    private var lastReal: UInt64 = 0
    private var lastPacketReal: UInt64 = 0

    public init(thresholdUs: UInt64 = 60_000) { self.thresholdUs = thresholdUs }

    /// Silence before `real` (0 until the first packet).
    public func silenceUs(real: UInt64) -> UInt64 { lastPacketReal == 0 ? 0 : real &- lastPacketReal }

    /// Advances and returns the virtual time. Call with `packet: true` when a datagram arrives.
    public mutating func advance(real: UInt64, packet: Bool) -> UInt64 {
        if lastReal == 0 { virtual = real; lastReal = real; if packet { lastPacketReal = real }; return virtual }
        let dt = real &- lastReal
        lastReal = real
        let silence = lastPacketReal == 0 ? 0 : real &- lastPacketReal
        virtual &+= silence > thresholdUs ? dt / 20 : dt
        if packet { lastPacketReal = real }
        return virtual
    }
}
