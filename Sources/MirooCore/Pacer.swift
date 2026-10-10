import Foundation
import Darwin

/// Spreads datagrams over time at a target rate instead of dumping a whole frame on the NIC at once.
/// Dedicated high-priority thread, sub-millisecond precision via `mach_wait_until`.
public final class Pacer: @unchecked Sendable {
    private struct Item { var bytes: [UInt8]; var enqueuedUs: UInt64; var keepOnFlush = false }
    private let send: ([UInt8]) -> Void
    private let cond = NSCondition()
    private var queue = [Item]()
    private var head = 0
    private var running = true
    private var rateBps: Double = 40_000_000
    private var nextFreeUs: UInt64 = 0
    private var queuedBytes = 0
    private var thread: Thread?
    private var timebase = mach_timebase_info_data_t()
    /// Datagrams allowed to leave back-to-back before spacing kicks in.
    public var burstPackets = 2

    public init(send: @escaping ([UInt8]) -> Void) {
        self.send = send
        mach_timebase_info(&timebase)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "miroo.pacer"; t.qualityOfService = .userInteractive; t.threadPriority = 1.0
        thread = t; t.start()
    }

    public func stop() {
        cond.lock(); running = false; cond.broadcast(); cond.unlock()
    }

    public func setRate(bps: Double) {
        cond.lock(); rateBps = max(500_000, bps); cond.unlock()
    }

    /// - Parameter keepOnFlush: survives `flush()` (recovery frames: the receiver is waiting for them).
    public func enqueue(_ datagrams: [Datagram], keepOnFlush: Bool = false) {
        let now = LinkClock.nowUs()
        cond.lock()
        for d in datagrams { queue.append(Item(bytes: d.bytes, enqueuedUs: now, keepOnFlush: keepOnFlush)); queuedBytes += d.bytes.count }
        cond.signal(); cond.unlock()
    }

    /// Repair packets jump the queue: they unblock decoding of a frame the receiver is already waiting for.
    public func enqueueFront(_ datagrams: [Datagram]) {
        let now = LinkClock.nowUs()
        cond.lock()
        let items = datagrams.map { Item(bytes: $0.bytes, enqueuedUs: now) }
        queue.insert(contentsOf: items, at: head)
        for d in datagrams { queuedBytes += d.bytes.count }
        cond.signal(); cond.unlock()
    }

    /// Drops everything not yet sent except datagrams marked `keepOnFlush`. Returns the number of datagrams dropped.
    @discardableResult
    public func flush() -> Int {
        cond.lock(); defer { cond.unlock() }
        let pending = Array(queue[head...])
        let kept = pending.filter { $0.keepOnFlush }
        queue = kept; head = 0
        queuedBytes = kept.reduce(0) { $0 + $1.bytes.count }
        return pending.count - kept.count
    }

    public var backlogBytes: Int { cond.lock(); defer { cond.unlock() }; return queuedBytes }
    /// Age of the oldest datagram still waiting.
    public var oldestAgeUs: UInt64 {
        cond.lock(); defer { cond.unlock() }
        guard head < queue.count else { return 0 }
        return LinkClock.nowUs() &- queue[head].enqueuedUs
    }

    private func loop() {
        while true {
            cond.lock()
            while running && head >= queue.count { cond.wait() }
            if !running { cond.unlock(); return }
            let item = queue[head]; head += 1
            if head > 256 && head * 2 > queue.count { queue.removeFirst(head); head = 0 }
            queuedBytes -= item.bytes.count
            let rate = rateBps
            cond.unlock()

            let now = LinkClock.nowUs()
            let slack = UInt64(Double(burstPackets) * 1_300.0 * 8.0 / rate * 1_000_000.0)
            let depart = max(nextFreeUs, now &- min(now, slack))
            if depart > now { sleepUntil(us: depart) }
            send(item.bytes)
            let sent = max(depart, now)
            nextFreeUs = sent + UInt64(Double(item.bytes.count) * 8.0 / rate * 1_000_000.0)
        }
    }

    private func sleepUntil(us: UInt64) {
        let now = LinkClock.nowUs()
        guard us > now else { return }
        let deltaNs = (us - now) * 1000
        let ticks = deltaNs * UInt64(timebase.denom) / UInt64(timebase.numer)
        mach_wait_until(mach_absolute_time() + ticks)
    }
}
