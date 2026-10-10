import Foundation

public struct AssembledFrame: Sendable {
    public var frameId: UInt32
    public var flags: PacketFlags
    public var payload: [UInt8]
    public var firstArrivalUs: UInt64
    public var lastArrivalUs: UInt64
    public var sendTimeUs: UInt32          // sender timestamp of the first packet seen
    public var packetsReceived: Int
    public var packetsTotal: Int
    public var repairedByFEC: Bool
}

/// Collects datagrams of a frame and completes it as soon as any `k` of `k + m` packets arrived.
/// Not thread safe: call from a single queue.
public final class FrameAssembler {
    private struct Partial {
        var k: Int, m: Int, frameLen: Int, chunk: Int
        var flags: PacketFlags
        var chunks: [Int: [UInt8]] = [:]
        var firstArrival: UInt64, lastArrival: UInt64
        var sendTime: UInt32
        var received = 0
        var repairAsks = 0
        var lastAskUs: UInt64 = 0
    }

    private var partials: [UInt32: Partial] = [:]
    /// Frames older than this are obsolete (a recovery frame superseded them); late packets for them are ignored.
    private var floor: UInt32?
    private var abandoned: [UInt32] = []          // ring of expired/dropped frame ids – late repair packets must not resurrect them
    private var completedIds: [UInt32] = []        // ring of recently completed frames (ignore late packets)
    private let completedKeep = 128

    public init() {}

    public var pendingCount: Int { partials.count }

    /// Returns the frame when this packet completes it.
    public func ingest(header h: PacketHeader, body: UnsafeRawBufferPointer, nowUs: UInt64) -> AssembledFrame? {
        guard h.kind == .data || h.kind == .parity, h.k > 0, Int(h.k) + Int(h.m) <= 255 else { return nil }
        if completedIds.contains(h.frameId) { return nil }
        if let f = floor, Int32(bitPattern: f &- h.frameId) > 0 { return nil }
        if abandoned.contains(h.frameId) { return nil }
        let k = Int(h.k), m = Int(h.m)
        let idx = h.kind == .data ? Int(h.index) : k + Int(h.index)
        guard h.kind == .data ? Int(h.index) < k : Int(h.index) + k <= 255 else { return nil }
        let frameLen = Int(h.frameLen)
        let chunk = (frameLen + k - 1) / k
        guard frameLen > 0, frameLen <= 8_000_000, body.count <= chunk else { return nil }

        var p = partials[h.frameId] ?? Partial(k: k, m: m, frameLen: frameLen, chunk: chunk, flags: h.flags,
                                               firstArrival: nowUs, lastArrival: nowUs, sendTime: h.sendTimeUs)
        guard p.k == k, p.m == m, p.frameLen == frameLen else { return nil }
        if p.chunks[idx] == nil {
            p.chunks[idx] = Array(body)
            p.received += 1
            p.lastArrival = nowUs
        }

        guard p.chunks.count >= k else { partials[h.frameId] = p; return nil }

        // Complete.
        partials[h.frameId] = nil
        completedIds.append(h.frameId)
        if completedIds.count > completedKeep { completedIds.removeFirst(completedIds.count - completedKeep) }

        var repaired = false
        var dataChunks = [[UInt8]]()
        dataChunks.reserveCapacity(k)
        if (0..<k).allSatisfy({ p.chunks[$0] != nil }) {
            for j in 0..<k { dataChunks.append(p.chunks[j]!) }
        } else {
            guard let rec = ReedSolomon.decode(k: k, m: m, size: chunk, chunks: p.chunks) else { return nil }
            dataChunks = rec
            repaired = true
        }
        var payload = [UInt8]()
        payload.reserveCapacity(frameLen)
        for c in dataChunks { payload.append(contentsOf: c) }
        if payload.count > frameLen { payload.removeLast(payload.count - frameLen) }
        return AssembledFrame(frameId: h.frameId, flags: p.flags, payload: payload, firstArrivalUs: p.firstArrival,
                              lastArrivalUs: p.lastArrival, sendTimeUs: p.sendTime, packetsReceived: p.received,
                              packetsTotal: k + m, repairedByFEC: repaired)
    }

    /// Frames with some packets present that stopped receiving for `idleUs`, as `(frameId, packetsStillNeeded)`.
    /// Marks them as asked; each frame may be asked up to `maxAsks` times, `retryUs` apart.
    public func repairNeeds(nowUs: UInt64, idleUs: UInt64, retryUs: UInt64, maxAsks: Int = 3) -> [(frameId: UInt32, need: Int)] {
        var out = [(frameId: UInt32, need: Int)]()
        for (id, p) in partials where nowUs &- p.lastArrival > idleUs && p.repairAsks < maxAsks && nowUs &- p.lastAskUs > retryUs {
            var q = p; q.repairAsks += 1; q.lastAskUs = nowUs; partials[id] = q
            out.append((id, max(1, p.k - p.chunks.count) + (p.repairAsks >= 1 ? 1 : 0)))
        }
        return out.sorted { $0.frameId < $1.frameId }
    }

    /// Drops frames that started arriving more than `olderThanUs` ago and are still incomplete.
    /// Returns their ids (these are lost for good).
    public func expire(nowUs: UInt64, olderThanUs: UInt64) -> [UInt32] {
        var lost = [UInt32]()
        for (id, p) in partials where nowUs &- p.firstArrival > olderThanUs {
            lost.append(id)
            partials[id] = nil
            noteAbandoned(id)
        }
        return lost.sorted()
    }

    /// A packet of frame `frameId` just arrived. Any *older* incomplete frame that has been silent for `idleUs`
    /// cannot still be in flight on an in-order path, so it is lost. Returns the lost ids.
    public func abandonStale(before frameId: UInt32, nowUs: UInt64, idleUs: UInt64) -> [UInt32] {
        var lost = [UInt32]()
        for (id, p) in partials where Int32(bitPattern: frameId &- id) > 0 && nowUs &- p.lastArrival > idleUs && p.repairAsks >= 3 {
            lost.append(id)
            partials[id] = nil
            noteAbandoned(id)
        }
        return lost.sorted()
    }

    public func hasPartial(_ id: UInt32) -> Bool { partials[id] != nil }
    public func wasCompleted(_ id: UInt32) -> Bool { completedIds.contains(id) }
    /// Forget incomplete frames older than `id` (a recovery frame made them irrelevant).
    public func dropOlder(than id: UInt32) {
        for k in partials.keys where Int32(bitPattern: id &- k) > 0 { partials[k] = nil }
        if floor == nil || Int32(bitPattern: id &- floor!) > 0 { floor = id }
    }
    private func noteAbandoned(_ id: UInt32) {
        abandoned.append(id)
        if abandoned.count > 256 { abandoned.removeFirst(abandoned.count - 256) }
    }

    public func reset() { partials.removeAll(); completedIds.removeAll(); abandoned.removeAll(); floor = nil }
}
