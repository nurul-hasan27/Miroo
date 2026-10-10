import Foundation

/// Classifies what the network does to the packet stream: random vs bursty loss, reordering, and arrival gaps.
public final class LossProfile {
    public struct Snapshot: Sendable {
        public var received = 0, lost = 0, reordered = 0, duplicates = 0
        /// Loss bursts by length: [1, 2, 3, 4-7, 8+]
        public var bursts = [0, 0, 0, 0, 0]
        public var maxArrivalGapMs = 0.0
        public var lossPct: Double { received + lost > 0 ? Double(lost) / Double(received + lost) * 100 : 0 }
    }
    public private(set) var snap = Snapshot()
    /// Notable stalls: (ms since first packet, gap ms)
    public private(set) var stalls: [(atMs: Int, gapMs: Int)] = []
    private var firstUs: UInt64 = 0
    private var expected: UInt32?
    private var missing: [UInt32: UInt64] = [:]       // seq -> time first noticed missing
    private var lastArrivalUs: UInt64 = 0
    private let graceUs: UInt64

    public init(graceUs: UInt64 = 100_000) { self.graceUs = graceUs }

    @inline(__always) private func after(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }

    public func ingest(seq: UInt32, nowUs: UInt64) {
        if firstUs == 0 { firstUs = nowUs }
        if lastArrivalUs != 0 {
            let gap = Double(nowUs &- lastArrivalUs) / 1000
            snap.maxArrivalGapMs = max(snap.maxArrivalGapMs, gap)
            if gap > 45, stalls.count < 64 { stalls.append((Int((nowUs &- firstUs) / 1000), Int(gap))) }
        }
        lastArrivalUs = nowUs
        guard let exp = expected else { expected = seq &+ 1; snap.received += 1; return }
        if seq == exp { expected = exp &+ 1; snap.received += 1 }
        else if after(seq, exp) {
            let gap = Int(seq &- exp)
            if gap < 10_000 { for k in 0..<gap { missing[exp &+ UInt32(k)] = nowUs } }
            expected = seq &+ 1; snap.received += 1
        } else if missing.removeValue(forKey: seq) != nil { snap.reordered += 1; snap.received += 1 }
        else { snap.duplicates += 1 }
        expire(nowUs)
    }

    /// Missing packets older than the grace period are real losses; group consecutive ones into bursts.
    private func expire(_ nowUs: UInt64) {
        let old = missing.filter { nowUs &- $0.value > graceUs }.keys.sorted { after($1, $0) }
        guard !old.isEmpty else { return }
        for k in old { missing[k] = nil }
        snap.lost += old.count
        var run = 1
        for i in 1..<max(1, old.count) + (old.count > 1 ? 0 : 0) where old.count > 1 {
            if old[i] == old[i - 1] &+ 1 { run += 1 } else { record(run); run = 1 }
        }
        record(run)
    }
    private func record(_ len: Int) { snap.bursts[len == 1 ? 0 : len == 2 ? 1 : len == 3 ? 2 : len < 8 ? 3 : 4] += 1 }
}
