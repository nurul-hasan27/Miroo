#if os(macOS)
import Foundation
import CoreVideo
import MirooCore
import MirooMedia
import MirooNet

/// Sending end: encoder -> FEC packets -> pacer -> UDP, adapted from receiver feedback.
public final class LinkStreamer: @unchecked Sendable {
    public struct Config {
        public var width: Int, height: Int, fps: Int, codec: Codec
        public var maxBitrate: Int
        public var startBitrate: Int
        public var maxPayload = 1360
        public init(width: Int, height: Int, fps: Int = 60, codec: Codec = .hevc, maxBitrate: Int = 30_000_000, startBitrate: Int = 5_000_000) {
            self.width = width; self.height = height; self.fps = fps; self.codec = codec
            self.maxBitrate = maxBitrate; self.startBitrate = min(startBitrate, maxBitrate)
        }
    }
    public struct Stats: Sendable {
        public var framesSent = 0, framesDropped = 0, recoveryFrames = 0
        public var bytesSent = 0
        public var encodeMsAvg = 0.0
        public var rttMs = 0.0, glassMs = 0.0, queueDelayMs = 0.0, lossPct = 0.0
        public var targetMbps = 0.0, paceMbps = 0.0
        public var sentMbps = 0.0, fps = 0.0
        public var recoveryRequests = 0
        public var encoderDrops = 0, submitDrops = 0, repairsServed = 0, repairPackets = 0
        /// Spacing of frames arriving from capture over the last second (source jitter): median / 95th percentile / worst.
        public var captureGapP50Ms = 0.0, captureGapP95Ms = 0.0, captureGapMaxMs = 0.0
    }

    static var noAdapt: Bool { ProcessInfo.processInfo.environment["MIROO_NO_ADAPT"] != nil }
    private let dbgT0 = LinkClock.nowUs()
    private func dts() -> String { String(format: "%8.1f", Double(LinkClock.nowUs() &- dbgT0) / 1000) }
    static let debug = ProcessInfo.processInfo.environment["MIROO_DEBUG_LINK"] != nil
    static var noAck: Bool { ProcessInfo.processInfo.environment["MIROO_NO_ACK"] != nil }
    public private(set) var stats = Stats()
    public var onLog: ((String) -> Void)?
    /// Touch/gesture events from the phone (already de-duplicated and ordered).
    public var onInput: (([InputEvent]) -> Void)?
    private let inputReceiver = InputReceiver()

    private let config: Config
    private let cipher: PacketCipher?
    private var knockSeq: UInt32 = 0
    private let encoder: LinkEncoder
    private let pacer: Pacer
    private let rate: RateController
    private let queue = DispatchQueue(label: "miroo.streamer", qos: .userInteractive)
    private var channel: UDPChannel?
    private var nextFrameId: UInt32 = 1
    private var nextPacketSeq: UInt32 = 0
    private var lastSentUs: UInt64 = 0
    private var inFlight = 0
    private var pending: (CVPixelBuffer, UInt32)?
    private var ackedSet = Set<Int32>()
    private var lastRecoveryBytes = 0
    private var lastRecoveryRequestUs: UInt64 = 0, lastRecoveryFrameSentUs: UInt64 = LinkClock.nowUs()
    private var lastEncoderBitrate: Int
    private var timer: DispatchSourceTimer?
    private var bytesWindowSent = 0, framesWindow = 0, lastWindowUs = LinkClock.nowUs()
    private var encodeUsAcc = 0.0, encodeCount = 0
    private var flowKnown = false
    private var lastFlushUs: UInt64 = 0
    private var captureGaps: [Double] = []
    private var lastSubmitUs: UInt64 = 0
    /// Idle keepalive spacing. Measured on a crowded 2.4 GHz link: 6 ms keepalives raised loss 15x (airtime contention), 40-50 ms is fine.
    private let keepaliveUs: UInt64 = UInt64(ProcessInfo.processInfo.environment["MIROO_KEEPALIVE_MS"].flatMap(Double.init).map { $0 * 1000 } ?? 50_000)
    private var tickN = 0
    private var history: [UInt32: (chunks: FrameChunks, nextRow: Int, lastRepairUs: UInt64)] = [:]
    private var historyOrder: [UInt32] = []
    public private(set) var repairsServed = 0, repairPackets = 0
    private var dropsAtLastFeedback = 0, lastDropCheckUs: UInt64 = 0
    /// True once any datagram from the receiver has arrived (UDP flow established).
    public var isConnected: Bool { flowKnown }

    public init(config: Config, channel: UDPChannel, cipher: PacketCipher? = nil) throws {
        self.config = config
        self.channel = channel
        self.cipher = cipher
        encoder = try LinkEncoder(config: .init(width: config.width, height: config.height, fps: config.fps,
                                                bitrate: config.startBitrate, codec: config.codec))
        var lim = RateController.Limits(); lim.startBitrate = config.startBitrate; lim.maxBitrate = config.maxBitrate
        rate = RateController(limits: lim)
        lastEncoderBitrate = config.startBitrate
        pacer = Pacer { [weak channel] bytes in
            guard let channel else { return }
            var b = bytes
            let t = LinkClock.nowUs32()
            b[20] = UInt8(t & 0xFF); b[21] = UInt8((t >> 8) & 0xFF); b[22] = UInt8((t >> 16) & 0xFF); b[23] = UInt8(t >> 24)
            if let c = cipher { guard let sealed = c.seal(b) else { return }; channel.send(sealed) } else { channel.send(b) }
        }
        pacer.setRate(bps: rate.paceRateBps)
        encoder.onFrame = { [weak self] ef in self?.queue.async { self?.encoded(ef) } }
        encoder.onDrop = { [weak self] in self?.queue.async { self?.encoderDropped() } }
        channel.onDatagram = { [weak self] buf, now in
            let copy = Data(buf)
            self?.queue.async {
                guard let self else { return }
                if let c = self.cipher {
                    // authenticate before anything else looks at the datagram
                    guard let plain = copy.withUnsafeBytes({ c.open($0) }) else { return }
                    plain.withUnsafeBytes { self.receive($0, nowUs: now) }
                } else { copy.withUnsafeBytes { self.receive($0, nowUs: now) } }
            }
        }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + .milliseconds(4), repeating: .milliseconds(4), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel(); timer = nil
        pacer.stop(); encoder.invalidate()
        channel?.cancel(); channel = nil
    }

    /// Datagram that opens the UDP flow on the phone (sent repeatedly until the first feedback arrives).
    public func knock() {
        queue.async { [self] in
            knockSeq &+= 1
            var w = ByteWriter()
            PacketHeader(kind: .hello, packetSeq: knockSeq, sendTimeUs: LinkClock.nowUs32()).write(into: &w)
            var b = w.bytes
            if let c = cipher { guard let sealed = c.seal(b) else { return }; b = sealed }
            channel?.send(b)
        }
    }

    // MARK: capture -> encode (newest frame wins)

    public func submit(_ pb: CVPixelBuffer, captureUs: UInt32) {
        queue.async { [self] in
            let nowSubmit = LinkClock.nowUs()
            if lastSubmitUs != 0 { captureGaps.append(Double(nowSubmit &- lastSubmitUs) / 1000) }
            lastSubmitUs = nowSubmit
            if inFlight >= 2 { if pending != nil { stats.submitDrops += 1 }; pending = (pb, captureUs); return }
            // congestion backlog: abandon queued old frames, restart from a recovery frame
            if pacer.oldestAgeUs > 100_000, LinkClock.nowUs() &- lastFlushUs > 400_000 {
                lastFlushUs = LinkClock.nowUs()
                pacer.flush(); encoder.requestRecovery(); stats.framesDropped += 1
                rate.onFlush(nowUs: lastFlushUs)
                encoder.setBitrate(rate.targetBitrate); lastEncoderBitrate = rate.targetBitrate
                onLog?("pacer backlog -> flush, recovery, bitrate \(rate.targetBitrate / 1000) kbps")
            }
            inFlight += 1
            encoder.encode(pb, captureUs: captureUs)
        }
    }

    private func encoderDropped() {
        inFlight = max(0, inFlight - 1)
        stats.encoderDrops += 1
        if let (pb, cap) = pending { pending = nil; inFlight += 1; encoder.encode(pb, captureUs: cap) }
    }

    private func encoded(_ ef: EncodedFrame) {
        inFlight = max(0, inFlight - 1)
        if let (pb, cap) = pending { pending = nil; inFlight += 1; encoder.encode(pb, captureUs: cap) }

        let payload = ef.envelope().serialize()
        // One Reed-Solomon block holds at most 255 packets (data + parity). Big frames use larger packets (up to the path MTU)
        // and keep as much parity as still fits; a frame that cannot be protected at all is not sent – it means the bitrate is
        // far too high for this content, so shrink it and restart from a fresh recovery frame.
        let blockLimit = 250
        var maxPayload = config.maxPayload
        var k0 = (payload.count + maxPayload - 1) / maxPayload
        var m = rate.parity(forDataPackets: k0)
        if ef.isRecovery { m = max(m + 2, Int((Double(k0) * 0.3).rounded(.up))) }   // the frame everything else depends on
        if k0 + m > blockLimit {
            maxPayload = 1400
            k0 = (payload.count + maxPayload - 1) / maxPayload
            m = min(m, blockLimit - k0)
        }
        if k0 > blockLimit - 6 {
            stats.framesDropped += 1
            rate.onFlush(nowUs: LinkClock.nowUs())
            encoder.setBitrate(rate.targetBitrate); lastEncoderBitrate = rate.targetBitrate
            encoder.requestRecovery()
            onLog?("frame of \(payload.count) bytes cannot be protected in one block -> bitrate \(rate.targetBitrate / 1000) kbps, new recovery frame")
            return
        }
        let fid = nextFrameId; nextFrameId &+= 1
        let chunks = Packetizer.split(payload: payload, frameId: fid, flags: ef.isRecovery ? [.recovery] : [], maxPayload: maxPayload)
        let dgs = Packetizer.packets(for: chunks, parity: m, firstSeq: nextPacketSeq, sendTimeUs: 0)
        if ef.isRecovery { history.removeAll(); historyOrder.removeAll() }     // older frames are obsolete: never serve repairs for them
        history[fid] = (chunks, m, 0)
        historyOrder.append(fid)
        if historyOrder.count > 24 { history[historyOrder.removeFirst()] = nil }
        nextPacketSeq &+= UInt32(dgs.count)
        // A recovery frame supersedes everything queued before it (old frames, repairs): drop those instead of sending them first.
        if ef.isRecovery, stats.framesSent > 0 { pacer.flush() }
        pacer.enqueue(dgs, keepOnFlush: ef.isRecovery)
        lastSentUs = LinkClock.nowUs()
        stats.framesSent += 1; stats.bytesSent += payload.count; bytesWindowSent += payload.count; framesWindow += 1
        if ef.isRecovery { lastRecoveryFrameSentUs = LinkClock.nowUs(); lastRecoveryBytes = payload.count; if stats.framesSent > 1 { rate.onRecovery(nowUs: lastRecoveryFrameSentUs) }; stats.recoveryFrames += 1; if Self.debug { print("[tx \(dts())] recovery frame id=\(fid) bytes=\(payload.count) parity=\(m) pkts=\(dgs.count) ltr=\(ef.ltrToken)") } }
        encodeUsAcc += Double(ef.encodeDoneUs &- ef.encodeStartUs); encodeCount += 1
    }

    // MARK: feedback

    private func receive(_ buf: UnsafeRawBufferPointer, nowUs: UInt64) {
        var r = ByteReader(buf)
        guard let h = PacketHeader.parse(&r) else { return }
        flowKnown = true
        if h.kind == .input {
            let evs = inputReceiver.ingest(UnsafeRawBufferPointer(rebasing: buf[PacketHeader.size...]))
            if !evs.isEmpty { onInput?(evs) }
            return
        }
        guard h.kind == .feedback else { return }
        let body = UnsafeRawBufferPointer(rebasing: buf[PacketHeader.size...])
        guard let fb = Feedback.parse(body) else { return }
        let now32 = UInt32(truncatingIfNeeded: nowUs)
        var rtt: Double?
        if fb.echoSendTimeUs != 0 { rtt = Double(LinkClock.diff32(now32, fb.echoSendTimeUs)) - Double(fb.holdUs) }
        if let r = rtt, r < 0 || r > 2_000_000 { rtt = nil }

        let sentBps = Double(bytesWindowSent) * 8 / max(0.05, Double(nowUs &- lastWindowUs) / 1e6)
        let drops = stats.encoderDrops
        let starved = drops - dropsAtLastFeedback > 0 && nowUs &- lastDropCheckUs > 100_000
        if nowUs &- lastDropCheckUs > 100_000 { dropsAtLastFeedback = drops; lastDropCheckUs = nowUs }
        rate.onFeedback(fb, nowUs: nowUs, rttUs: rtt, sentBitrate: sentBps, pacerBacklogUs: pacer.oldestAgeUs, starved: starved)
        if abs(rate.targetBitrate - lastEncoderBitrate) > lastEncoderBitrate / 20 {
            lastEncoderBitrate = rate.targetBitrate
            if !Self.noAdapt { encoder.setBitrate(rate.targetBitrate) }
        }
        pacer.setRate(bps: rate.paceRateBps)

        for r in fb.repairs { serveRepair(r, nowUs: nowUs) }
        let fresh = fb.ackedLTRTokens.filter { ackedSet.insert($0).inserted }
        if !fresh.isEmpty, !Self.noAck { encoder.acknowledge(tokens: fresh) }

        if fb.needRecovery, !encoder.hasPendingRecovery, nowUs &- lastRecoveryFrameSentUs > rate.recoveryCooldownUs(rttUs: rate.rttUs, lastRecoveryBytes: lastRecoveryBytes), nowUs &- lastRecoveryRequestUs > 30_000 {
            lastRecoveryRequestUs = nowUs
            stats.recoveryRequests += 1
            if Self.debug { print("[tx \(dts())] recovery requested by receiver (rtt \(Int(rate.rttUs))us)") }
            encoder.requestRecovery()
        }
        stats.rttMs = rate.rttUs / 1000
        stats.queueDelayMs = rate.queueDelayUs / 1000
        stats.lossPct = rate.lossRate * 100
        if fb.shownCaptureUs != 0 {
            let age = Double(LinkClock.diff32(now32, fb.shownCaptureUs)) - Double(fb.shownAgoUs) - rate.rttUs / 2
            if age > 0 && age < 2_000_000 { stats.glassMs = stats.glassMs == 0 ? age / 1000 : stats.glassMs * 0.9 + age / 10_000 }
        }
    }

    /// Incremental redundancy: mint `need` brand-new parity packets for a frame the receiver is stuck on.
    private func serveRepair(_ r: Repair, nowUs: UInt64) {
        guard var h = history[r.frameId], nowUs &- h.lastRepairUs > 8_000 else { return }
        let k = h.chunks.k
        let count = r.need == 255 ? k + 1 : min(Int(r.need) + 1, k + 2)
        let dgs = Packetizer.extraParity(for: h.chunks, fromRow: h.nextRow, count: count, firstSeq: nextPacketSeq, sendTimeUs: 0)
        guard !dgs.isEmpty else { return }
        nextPacketSeq &+= UInt32(dgs.count)
        h.nextRow += dgs.count; h.lastRepairUs = nowUs
        history[r.frameId] = h
        pacer.enqueueFront(dgs)
        repairsServed += 1; repairPackets += dgs.count
        if Self.debug { print("[tx \(dts())] repair frame \(r.frameId) need=\(r.need) sent \(dgs.count) parity packets") }
    }

    // MARK: periodic

    private func tick() {
        let now = LinkClock.nowUs()
        tickN += 1
        if tickN % 5 == 0 { rate.onSilence(nowUs: now) }
        if abs(rate.targetBitrate - lastEncoderBitrate) > lastEncoderBitrate / 20 {
            lastEncoderBitrate = rate.targetBitrate; if !Self.noAdapt { encoder.setBitrate(rate.targetBitrate) }
        }
        pacer.setRate(bps: rate.paceRateBps)
        // heartbeat probe so the receiver can notice a lost stream tail and keep RTT/delay estimates fresh
        if now &- lastSentUs > keepaliveUs {
            var w = ByteWriter()
            PacketHeader(kind: .probe, packetSeq: nextPacketSeq, frameId: nextFrameId &- 1, sendTimeUs: 0).write(into: &w)
            nextPacketSeq &+= 1
            pacer.enqueue([Datagram(bytes: w.bytes, isParity: false)])
            lastSentUs = now
        }
        if now &- lastWindowUs >= 1_000_000 {
            let dt = Double(now &- lastWindowUs) / 1e6
            stats.sentMbps = Double(bytesWindowSent) * 8 / dt / 1e6
            stats.fps = Double(framesWindow) / dt
            if encodeCount > 0 { stats.encodeMsAvg = encodeUsAcc / Double(encodeCount) / 1000; encodeUsAcc = 0; encodeCount = 0 }
            stats.targetMbps = Double(rate.targetBitrate) / 1e6
            stats.repairsServed = repairsServed; stats.repairPackets = repairPackets
            if !captureGaps.isEmpty { let g = captureGaps.sorted(); stats.captureGapP50Ms = g[g.count / 2]; stats.captureGapP95Ms = g[min(g.count - 1, Int(Double(g.count) * 0.95))]; stats.captureGapMaxMs = g.last!; captureGaps.removeAll(keepingCapacity: true) }
            stats.paceMbps = rate.paceRateBps / 1e6
            bytesWindowSent = 0; framesWindow = 0; lastWindowUs = now
        }
    }
}
#endif
