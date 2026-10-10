import Foundation

public enum PacketKind: UInt8, Sendable {
    case data = 1, parity = 2, feedback = 3, input = 4, hello = 5, probe = 6
}

public struct PacketFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    /// Frame can be decoded without the previous frame (IDR or LTR-refresh).
    public static let recovery = PacketFlags(rawValue: 1 << 0)
}

/// 24-byte datagram header. See Docs/MIROO_LINK_DESIGN.md.
public struct PacketHeader: Equatable, Sendable {
    public static let size = 24
    public static let magic: UInt8 = 0xB7
    public static let version: UInt8 = 1

    public var kind: PacketKind
    public var flags: PacketFlags
    public var packetSeq: UInt32
    public var frameId: UInt32
    public var frameLen: UInt32
    public var index: UInt8
    public var k: UInt8
    public var m: UInt8
    public var sendTimeUs: UInt32

    public init(kind: PacketKind, flags: PacketFlags = [], packetSeq: UInt32, frameId: UInt32 = 0,
                frameLen: UInt32 = 0, index: UInt8 = 0, k: UInt8 = 0, m: UInt8 = 0, sendTimeUs: UInt32 = 0) {
        self.kind = kind; self.flags = flags; self.packetSeq = packetSeq; self.frameId = frameId
        self.frameLen = frameLen; self.index = index; self.k = k; self.m = m; self.sendTimeUs = sendTimeUs
    }

    public func write(into w: inout ByteWriter) {
        w.u8(Self.magic)
        w.u8(Self.version << 4 | kind.rawValue)
        w.u16(flags.rawValue)
        w.u32(packetSeq)
        w.u32(frameId)
        w.u32(frameLen)
        w.u8(index); w.u8(k); w.u8(m); w.u8(0)
        w.u32(sendTimeUs)
    }

    public static func parse(_ r: inout ByteReader) -> PacketHeader? {
        guard r.remaining >= size, r.u8() == magic, let vk = r.u8(), vk >> 4 == version,
              let kind = PacketKind(rawValue: vk & 0x0F),
              let flags = r.u16(), let seq = r.u32(), let fid = r.u32(), let flen = r.u32(),
              let idx = r.u8(), let k = r.u8(), let m = r.u8(), r.u8() != nil, let st = r.u32()
        else { return nil }
        return PacketHeader(kind: kind, flags: PacketFlags(rawValue: flags), packetSeq: seq, frameId: fid,
                            frameLen: flen, index: idx, k: k, m: m, sendTimeUs: st)
    }
}

public enum Codec: UInt8, Sendable { case h264 = 0, hevc = 1 }

/// Metadata carried inside the (FEC protected) frame payload, followed by the length-prefixed bitstream.
public struct FrameEnvelope: Equatable, Sendable {
    public var codec: Codec
    /// True for frames that can start/resume decoding (IDR or LTR refresh).
    public var isRecovery: Bool
    /// LTR token the receiver must acknowledge once this frame decoded (0 = none).
    public var ltrToken: Int32
    public var captureUs: UInt32
    public var encodeDoneUs: UInt32
    /// SPS/PPS(/VPS) – present on recovery frames.
    public var parameterSets: [[UInt8]]
    public var bitstream: [UInt8]

    public init(codec: Codec, isRecovery: Bool, ltrToken: Int32, captureUs: UInt32, encodeDoneUs: UInt32,
                parameterSets: [[UInt8]], bitstream: [UInt8]) {
        self.codec = codec; self.isRecovery = isRecovery; self.ltrToken = ltrToken
        self.captureUs = captureUs; self.encodeDoneUs = encodeDoneUs
        self.parameterSets = parameterSets; self.bitstream = bitstream
    }

    public func serialize() -> [UInt8] {
        var w = ByteWriter(capacity: bitstream.count + 64)
        w.u8(codec.rawValue)
        w.u8(isRecovery ? 1 : 0)
        w.i32(ltrToken)
        w.u32(captureUs)
        w.u32(encodeDoneUs)
        w.u8(UInt8(parameterSets.count))
        for ps in parameterSets { w.u16(UInt16(ps.count)); w.raw(ps) }
        w.raw(bitstream)
        return w.bytes
    }

    public static func parse(_ bytes: [UInt8]) -> FrameEnvelope? {
        bytes.withUnsafeBytes { buf in
            var r = ByteReader(buf)
            guard let c = r.u8(), let codec = Codec(rawValue: c), let rec = r.u8(), let tok = r.i32(),
                  let cap = r.u32(), let enc = r.u32(), let n = r.u8() else { return nil }
            var sets = [[UInt8]]()
            for _ in 0..<Int(n) {
                guard let l = r.u16(), let ps = r.raw(Int(l)) else { return nil }
                sets.append(ps)
            }
            guard let bs = r.raw(r.remaining) else { return nil }
            return FrameEnvelope(codec: codec, isRecovery: rec != 0, ltrToken: tok, captureUs: cap,
                                 encodeDoneUs: enc, parameterSets: sets, bitstream: bs)
        }
    }
}

/// Receiver -> sender report, sent every ~8 ms while streaming and immediately on loss.
public struct Repair: Equatable, Sendable {
    public var frameId: UInt32
    public var need: UInt8
    public init(frameId: UInt32, need: UInt8) { self.frameId = frameId; self.need = need }
}

public struct Feedback: Equatable, Sendable {
    public var highestPacketSeq: UInt32 = 0
    public var packetsReceived: UInt16 = 0     // since last report
    public var packetsExpected: UInt16 = 0     // since last report (from seq gaps)
    public var framesLost: UInt16 = 0          // frames abandoned since last report (post-FEC)
    public var lastDecodedFrameId: UInt32 = 0
    public var needRecovery: Bool = false
    public var queueDelayUs: UInt32 = 0        // relative OWD above window minimum
    public var goodputKbps: UInt32 = 0
    public var burstCapacityKbps: UInt32 = 0   // packet-train dispersion estimate (0 = unknown)
    public var decodeUs: UInt16 = 0
    public var echoSendTimeUs: UInt32 = 0      // sender timestamp of latest packet, for RTT
    public var holdUs: UInt32 = 0              // time between receiving it and sending this report
    public var standingQueueUs: UInt32 = 0     // min queueing delay over the last ~100 ms (congestion signal)
    public var shownCaptureUs: UInt32 = 0      // capture timestamp (sender clock) of the newest frame handed to the display
    public var shownAgoUs: UInt32 = 0          // how long before this report that frame was handed to the display
    /// Frames the receiver cannot complete: (frameId, packets still needed; 255 = whole frame, never seen).
    public var repairs: [Repair] = []
    public var ackedLTRTokens: [Int32] = []

    public init() {}

    public func serialize() -> [UInt8] {
        var w = ByteWriter()
        w.u32(highestPacketSeq); w.u16(packetsReceived); w.u16(packetsExpected); w.u16(framesLost)
        w.u32(lastDecodedFrameId); w.u8(needRecovery ? 1 : 0)
        w.u32(queueDelayUs); w.u32(goodputKbps); w.u32(burstCapacityKbps); w.u16(decodeUs)
        w.u32(echoSendTimeUs); w.u32(holdUs); w.u32(shownCaptureUs); w.u32(shownAgoUs); w.u32(standingQueueUs)
        w.u8(UInt8(min(repairs.count, 8)))
        for r in repairs.prefix(8) { w.u32(r.frameId); w.u8(r.need) }
        w.u8(UInt8(min(ackedLTRTokens.count, 32)))
        for t in ackedLTRTokens.prefix(32) { w.i32(t) }
        return w.bytes
    }

    public static func parse(_ bytes: UnsafeRawBufferPointer) -> Feedback? {
        var r = ByteReader(bytes)
        var f = Feedback()
        guard let a = r.u32(), let b = r.u16(), let c = r.u16(), let d = r.u16(), let e = r.u32(), let g = r.u8(),
              let h = r.u32(), let i = r.u32(), let j = r.u32(), let l = r.u16(), let m = r.u32(), let n = r.u32(),
              let sc = r.u32(), let sa = r.u32(), let sq = r.u32(), let rc = r.u8() else { return nil }
        f.shownCaptureUs = sc; f.shownAgoUs = sa; f.standingQueueUs = sq
        for _ in 0..<Int(rc) { guard let id = r.u32(), let n = r.u8() else { return nil }; f.repairs.append(Repair(frameId: id, need: n)) }
        guard let cnt = r.u8() else { return nil }
        f.highestPacketSeq = a; f.packetsReceived = b; f.packetsExpected = c; f.framesLost = d
        f.lastDecodedFrameId = e; f.needRecovery = g != 0; f.queueDelayUs = h; f.goodputKbps = i
        f.burstCapacityKbps = j; f.decodeUs = l; f.echoSendTimeUs = m; f.holdUs = n
        for _ in 0..<Int(cnt) { guard let t = r.i32() else { return nil }; f.ackedLTRTokens.append(t) }
        return f
    }
}
