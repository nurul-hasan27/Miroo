import Foundation

public struct Datagram: Sendable {
    public var bytes: [UInt8]
    public var isParity: Bool
    public init(bytes: [UInt8], isParity: Bool) { self.bytes = bytes; self.isParity = isParity }
}

/// A frame split into `k` equal chunks (last one zero padded) – everything needed to mint more parity later.
public struct FrameChunks: Sendable {
    public var frameId: UInt32
    public var flags: PacketFlags
    public var frameLen: Int
    public var chunks: [[UInt8]]
    public var k: Int { chunks.count }
    public var chunkSize: Int { chunks[0].count }
}

public enum Packetizer {
    public static func split(payload: [UInt8], frameId: UInt32, flags: PacketFlags, maxPayload: Int) -> FrameChunks {
        let len = payload.count
        let k = max(1, (len + maxPayload - 1) / maxPayload)
        let chunk = (len + k - 1) / k
        var chunks = [[UInt8]]()
        chunks.reserveCapacity(k)
        for i in 0..<k {
            let lo = min(len, i * chunk), hi = min(len, lo + chunk)
            var c = Array(payload[lo..<hi])
            if c.count < chunk { c += [UInt8](repeating: 0, count: chunk - c.count) }
            chunks.append(c)
        }
        return FrameChunks(frameId: frameId, flags: flags, frameLen: len, chunks: chunks)
    }

    private static func packet(_ f: FrameChunks, kind: PacketKind, index: Int, m: Int, body: ArraySlice<UInt8>, seq: UInt32, sendTimeUs: UInt32) -> Datagram {
        var w = ByteWriter(capacity: PacketHeader.size + body.count)
        PacketHeader(kind: kind, flags: f.flags, packetSeq: seq, frameId: f.frameId, frameLen: UInt32(f.frameLen),
                     index: UInt8(index), k: UInt8(f.k), m: UInt8(min(255, m)), sendTimeUs: sendTimeUs).write(into: &w)
        w.raw(body)
        return Datagram(bytes: w.bytes, isParity: kind == .parity)
    }

    /// Data packets followed by `m` parity packets (rows 0..<m).
    public static func packets(for f: FrameChunks, parity m: Int, firstSeq: UInt32, sendTimeUs: UInt32) -> [Datagram] {
        precondition(f.k + m <= 255, "frame too large for single RS block")
        let parity = m > 0 ? (0..<m).map { ReedSolomon.parityChunk(data: f.chunks, row: $0) } : []
        var out = [Datagram](); out.reserveCapacity(f.k + m)
        var seq = firstSeq
        for i in 0..<f.k {
            let sent = min(f.chunkSize, max(0, f.frameLen - i * f.chunkSize))   // last data chunk is sent without padding
            out.append(packet(f, kind: .data, index: i, m: m, body: f.chunks[i][0..<sent], seq: seq, sendTimeUs: sendTimeUs)); seq &+= 1
        }
        for p in 0..<m { out.append(packet(f, kind: .parity, index: p, m: m, body: parity[p][0..<f.chunkSize], seq: seq, sendTimeUs: sendTimeUs)); seq &+= 1 }
        return out
    }

    /// Fresh parity packets (rows `fromRow..<fromRow+count`) for a frame already sent (incremental redundancy).
    public static func extraParity(for f: FrameChunks, fromRow: Int, count: Int, firstSeq: UInt32, sendTimeUs: UInt32) -> [Datagram] {
        let rows = max(0, min(count, 255 - f.k - fromRow))
        var out = [Datagram](); var seq = firstSeq
        for p in fromRow..<(fromRow + rows) {
            out.append(packet(f, kind: .parity, index: p, m: fromRow + rows, body: ReedSolomon.parityChunk(data: f.chunks, row: p)[0...], seq: seq, sendTimeUs: sendTimeUs)); seq &+= 1
        }
        return out
    }

    /// Convenience used by tests and the simple path.
    public static func packetize(payload: [UInt8], frameId: UInt32, flags: PacketFlags, parity m: Int,
                                 maxPayload: Int, firstSeq: UInt32, sendTimeUs: UInt32) -> [Datagram] {
        packets(for: split(payload: payload, frameId: frameId, flags: flags, maxPayload: maxPayload), parity: m, firstSeq: firstSeq, sendTimeUs: sendTimeUs)
    }
}
