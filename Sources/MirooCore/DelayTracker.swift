import Foundation

/// Estimates queueing delay without clock sync: relative one-way delay (recv - send, arbitrary constant offset)
/// minus its minimum over a sliding window (monotonic deque, amortized O(1)).
public final class DelayTracker {
    private var baseline: UInt32?
    private var times = [UInt64](), values = [Int32]()
    private var head = 0
    private let windowUs: UInt64
    private var ewma: Double = 0
    public private(set) var queueDelayUs: UInt32 = 0
    /// Minimum queueing delay seen over the last ~100 ms. Isolated Wi-Fi jitter spikes leave this low; a real
    /// standing queue (congestion) keeps it high.
    public private(set) var standingQueueUs: UInt32 = 0
    private var recentT = [UInt64](), recentV = [Int32](), recentHead = 0
    private let standingWindowUs: UInt64 = 100_000

    public init(windowUs: UInt64 = 5_000_000) { self.windowUs = windowUs }

    public func add(sendUs32: UInt32, recvUs: UInt64) {
        let raw = UInt32(truncatingIfNeeded: recvUs) &- sendUs32
        if baseline == nil { baseline = raw }
        let rel = Int32(bitPattern: raw &- baseline!)
        while values.count > head, values[values.count - 1] >= rel { values.removeLast(); times.removeLast() }
        values.append(rel); times.append(recvUs)
        while head < times.count, recvUs &- times[head] > windowUs { head += 1 }
        if head > 1024 { times.removeFirst(head); values.removeFirst(head); head = 0 }
        // short-window minimum (monotonic deque again)
        while recentV.count > recentHead, recentV[recentV.count - 1] >= rel { recentV.removeLast(); recentT.removeLast() }
        recentV.append(rel); recentT.append(recvUs)
        while recentHead < recentT.count, recvUs &- recentT[recentHead] > standingWindowUs { recentHead += 1 }
        if recentHead > 512 { recentT.removeFirst(recentHead); recentV.removeFirst(recentHead); recentHead = 0 }
        let minV = values[head]
        standingQueueUs = UInt32(max(0, Int64(recentV[recentHead]) - Int64(minV)))
        let q = Double(max(0, Int64(rel) - Int64(minV)))
        ewma = ewma == 0 ? q : ewma * 0.75 + q * 0.25
        queueDelayUs = UInt32(min(Double(UInt32.max), ewma))
    }

    public func reset() { baseline = nil; times.removeAll(); values.removeAll(); head = 0; ewma = 0; queueDelayUs = 0; standingQueueUs = 0; recentT.removeAll(); recentV.removeAll(); recentHead = 0 }
}
