import Foundation
import CoreVideo
import MirooCore
import MirooMedia
import MirooNet

/// Receiving end of the video link (runs on the phone; also on a Mac for tests).
/// All state is confined to `queue`.
public final class LinkReceiver: @unchecked Sendable {
    public struct Stats: Sendable {
        public var framesDisplayed = 0, framesDecodeFailed = 0, framesRepaired = 0, framesLost = 0
        public var recoveryRequests = 0
        public var packets = 0, bytes = 0
        public var decodeMsAvg = 0.0
        public var queueDelayMs = 0.0
        public var lossPct = 0.0
        public var fps = 0.0, mbps = 0.0
        /// Spacing between frames handed to the display over the last second (smoothness): median, 95th percentile, worst.
        public var gapP50Ms = 0.0, gapP95Ms = 0.0, gapMaxMs = 0.0
    }

    public var onFrame: ((CVPixelBuffer) -> Void)?
    /// Authenticated encryption for every datagram in both directions (nil = plaintext, tests only).
    public var cipher: PacketCipher?
    public private(set) var stats = Stats()
    /// Real time (µs) the last media packet arrived; 0 before any. Queue-confined.
    public private(set) var lastMediaUs: UInt64 = 0

    private let queue: DispatchQueue
    private var channel: UDPChannel?
    private let asm = FrameAssembler()
    private let seq = FrameSequencer(holdUs: 32_000)
    private let delay = DelayTracker()
    private var profile = LossProfile()
    private var outage = OutageClock()
    /// Outage beyond which the sender no longer holds the lost frames: go straight to a recovery frame on resume.
    private let longOutageUs: UInt64 = 400_000
    /// More fully-missing frames than this: skip repairs, ask for a recovery frame.
    private let maxRepairFrames = 3
    public var lossProfile: LossProfile.Snapshot { profile.snap }
    public var stallLog: [(atMs: Int, gapMs: Int)] { profile.stalls }
    private let decoder = LinkDecoder()
    private var timer: DispatchSourceTimer?

    // feedback accounting
    private var maxSeq: UInt32?
    private var lastReportMaxSeq: UInt32?
    private var receivedSinceReport = 0
    private var lostFramesSinceReport = 0
    private var lastDecodedFrameId: UInt32 = 0
    private var lastEchoSend: UInt32 = 0, lastEchoRecvUs: UInt64 = 0
    private var ackedTokens: [Int32] = []
    private var bytesWindow: [(UInt64, Int)] = []
    private var decodeUsAcc = 0.0, decodeCount = 0
    private var shownCaptureUs: UInt32 = 0, shownAtUs: UInt64 = 0
    private var framesSince = 0, bytesSince = 0, lastRateUs: UInt64 = 0
    private var gapSamples: [Double] = []
    private var lastShownRealUs: UInt64 = 0
    private var frameIdForEnvelope: [UInt32: UInt32] = [:]
    private var fbSeq: UInt32 = 0
    private var lastFeedbackUs: UInt64 = 0

    public init(queue: DispatchQueue) {
        self.queue = queue
        decoder.onDecoded = { [weak self] f in self?.decoded(f) }
        decoder.onError = { [weak self] st in
            self?.queue.async { self?.stats.framesDecodeFailed += 1; self?.requestRecoveryNow() }
        }
    }

    /// - Parameter first: the datagram that opened the flow, already authenticated by the caller (processed after attaching).
    public func attach(_ ch: UDPChannel, first: [UInt8]? = nil, firstAtUs: UInt64 = 0) {
        timer?.cancel(); timer = nil
        if let old = channel, old !== ch { old.onDatagram = nil; old.cancel() }
        // fresh stream state (a new flow means a new sender session / reconfiguration)
        outage = OutageClock(); profile = LossProfile(); asm.reset(); seq.reset(); delay.reset(); maxSeq = nil; lastReportMaxSeq = nil; receivedSinceReport = 0
        lostFramesSinceReport = 0; ackedTokens.removeAll(); shownCaptureUs = 0; shownAtUs = 0; lastDecodedFrameId = 0
        channel = ch
        ch.onDatagram = { [weak self] buf, now in self?.receiveDatagram(buf, nowUs: now) }
        if let first { first.withUnsafeBytes { receiveDatagram($0, nowUs: firstAtUs == 0 ? LinkClock.nowUs() : firstAtUs) } }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + .milliseconds(4), repeating: .milliseconds(4), leeway: .microseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel(); timer = nil
        decoder.invalidate()
        channel?.cancel(); channel = nil
    }

    // MARK: receive path (queue)

    private func receiveDatagram(_ buf: UnsafeRawBufferPointer, nowUs: UInt64) {
        if let c = cipher {
            guard let plain = c.open(buf) else { return }          // forged / corrupted / wrong-session: drop silently
            plain.withUnsafeBytes { receive($0, nowUs: nowUs) }
        } else { receive(buf, nowUs: nowUs) }
    }

    /// Seals (if encrypted) and sends one datagram to the sender.
    private func transmit(_ bytes: [UInt8]) {
        guard let ch = channel else { return }
        if let c = cipher { guard let sealed = c.seal(bytes) else { return }; ch.send(sealed) } else { ch.send(bytes) }
    }

    private func receive(_ buf: UnsafeRawBufferPointer, nowUs: UInt64) {
        var r = ByteReader(buf)
        guard let h = PacketHeader.parse(&r) else { return }
        let silence = outage.silenceUs(real: nowUs)
        let vNow = outage.advance(real: nowUs, packet: true)
        if silence > longOutageUs { handle(seq.forceRecovery()) }
        // loss accounting (any media-path packet carries the global sequence)
        if h.kind == .data || h.kind == .parity || h.kind == .probe {
            if maxSeq == nil || Int32(bitPattern: h.packetSeq &- maxSeq!) > 0 { maxSeq = h.packetSeq }
            if lastReportMaxSeq == nil { lastReportMaxSeq = h.packetSeq &- 1 }
            receivedSinceReport += 1
            stats.packets += 1; stats.bytes += buf.count
            bytesSince += buf.count
            bytesWindow.append((nowUs, buf.count))
            lastEchoSend = h.sendTimeUs; lastEchoRecvUs = nowUs; lastMediaUs = nowUs
            delay.add(sendUs32: h.sendTimeUs, recvUs: nowUs)
            profile.ingest(seq: h.packetSeq, nowUs: nowUs)
        }
        switch h.kind {
        case .probe:
            seq.noteAnnounced(h.frameId)
        case .data, .parity:
            let body = UnsafeRawBufferPointer(rebasing: buf[PacketHeader.size...])
            seq.noteAnnounced(h.frameId)
            if let f = asm.ingest(header: h, body: body, nowUs: vNow) {
                if Self.debug, f.flags.contains(.recovery) { print("[rx \(dts())] recovery frame id=\(f.frameId) complete, pkts \(f.packetsReceived)/\(f.packetsTotal)") }
                if f.repairedByFEC { stats.framesRepaired += 1 }
                if f.flags.contains(.recovery) { asm.dropOlder(than: f.frameId) }
                let res = seq.onFrame(f, nowUs: vNow)
                for fr in res.decode { feed(fr) }
                handle(res.actions)
            }
        case .hello:
            sendFeedback(nowUs: nowUs)
        default: break
        }
    }

    private func feed(_ fr: AssembledFrame) {
        guard let env = FrameEnvelope.parse(fr.payload) else { stats.framesDecodeFailed += 1; requestRecoveryNow(); return }
        lastDecodedFrameId = fr.frameId
        decoder.decode(env)
    }

    private func decoded(_ f: DecodedFrame) {
        let nowUs = LinkClock.nowUs()
        onFrame?(f.pixelBuffer)                       // display immediately, straight from the decoder callback
        queue.async { [self] in
            stats.framesDisplayed += 1; framesSince += 1
            if lastShownRealUs != 0 { gapSamples.append(Double(nowUs &- lastShownRealUs) / 1000) }
            lastShownRealUs = nowUs
            shownCaptureUs = f.envelope.captureUs; shownAtUs = nowUs
            decodeUsAcc += Double(f.decodeUs); decodeCount += 1
            if f.envelope.ltrToken != 0 {
                ackedTokens.append(f.envelope.ltrToken)
                if ackedTokens.count > 8 { ackedTokens.removeFirst(ackedTokens.count - 8) }
                sendFeedback(nowUs: LinkClock.nowUs())     // ack quickly so LTR refs become usable
            }
        }
    }

    static let debug = ProcessInfo.processInfo.environment["MIROO_DEBUG_LINK"] != nil
    private let dbgT0 = LinkClock.nowUs()
    private func dts() -> String { String(format: "%8.1f", Double(LinkClock.nowUs() &- dbgT0) / 1000) }
    private func handle(_ actions: [SequencerAction]) {
        for a in actions where a == .requestRecovery { stats.recoveryRequests += 1; if Self.debug { print("[rx \(dts())] request recovery (expectedNext=\(String(describing: seq.expectedNext)))") }; requestRecoveryNow() }
    }

    private func requestRecoveryNow() { sendFeedback(nowUs: LinkClock.nowUs(), forceRecovery: true) }

    // MARK: periodic

    private var tickCount = 0
    private func tick() {
        let now = LinkClock.nowUs()
        let vNow = outage.advance(real: now, packet: false)
        collectRepairs(nowUs: vNow, realNowUs: now)
        let lost = asm.expire(nowUs: vNow, olderThanUs: 32_000)
        if !lost.isEmpty { stats.framesLost += lost.count; lostFramesSinceReport += lost.count; handle(seq.onFramesAbandoned(lost)) }
        handle(seq.tick(nowUs: vNow, sawIncomplete: asm.pendingCount > 0))
        tickCount += 1
        if maxSeq == nil { if tickCount % 3 == 0 { sendFeedbackStub() } }     // flow not confirmed yet: keep poking the sender
        else if tickCount % 2 == 0 { sendFeedback(nowUs: now) }
        if now &- lastRateUs >= 1_000_000 {
            let dt = Double(now &- max(lastRateUs, now &- 1_000_000)) / 1e6
            stats.fps = Double(framesSince) / dt
            stats.mbps = Double(bytesSince) * 8 / dt / 1e6
            stats.queueDelayMs = Double(delay.queueDelayUs) / 1000
            if decodeCount > 0 { stats.decodeMsAvg = decodeUsAcc / Double(decodeCount) / 1000; decodeUsAcc = 0; decodeCount = 0 }
            if !gapSamples.isEmpty {
                let g = gapSamples.sorted()
                stats.gapP50Ms = g[g.count / 2]; stats.gapP95Ms = g[min(g.count - 1, Int(Double(g.count) * 0.95))]; stats.gapMaxMs = g.last!
                gapSamples.removeAll(keepingCapacity: true)
            }
            framesSince = 0; bytesSince = 0; lastRateUs = now
        }
    }

    // MARK: repair requests

    private var pendingRepairs: [Repair] = []
    private var askedWhole: [UInt32: (asks: Int, lastUs: UInt64)] = [:]
    public private(set) var repairRequestsSent = 0

    /// Frames stuck mid-way, or never seen at all although later frames exist, are repaired with fresh parity
    /// instead of waiting for the sender to start a new reference chain.
    private func collectRepairs(nowUs: UInt64, realNowUs: UInt64) {
        if seq.waitingForRecovery { return }        // the chain is being rebuilt from a recovery frame: repairs of old frames are pointless
        var reps = asm.repairNeeds(nowUs: nowUs, idleUs: 4_000, retryUs: 22_000, maxAsks: 2).map { Repair(frameId: $0.frameId, need: UInt8(min(250, $0.need))) }
        if !seq.waitingForRecovery, let exp = seq.expectedNext, let hi = seq.highestSeen, Int32(bitPattern: hi &- exp) > 0 {
            // Many frames missing outright (long outage): one fresh recovery frame is cheaper than re-sending them all.
            var wholeMissing = 0
            var probe = exp
            while Int32(bitPattern: hi &- probe) >= 0, wholeMissing <= maxRepairFrames {
                if !asm.hasPartial(probe), !seq.isHeld(probe), !asm.wasCompleted(probe) { wholeMissing += 1 }
                probe &+= 1
            }
            if wholeMissing > maxRepairFrames { handle(seq.forceRecovery()); return }
            var id = exp
            var n = 0
            while Int32(bitPattern: hi &- id) >= 0, n < 4 {
                if !asm.hasPartial(id), !seq.isHeld(id), !asm.wasCompleted(id) {
                    let st = askedWhole[id] ?? (0, 0)
                    // a frame id that exists but never produced a packet: tail frames might just be in flight, so wait a bit
                    if st.asks < 2, nowUs &- st.lastUs > 22_000, id != hi || realNowUs &- lastEchoRecvUs > 8_000 {
                        askedWhole[id] = (st.asks + 1, nowUs)
                        reps.append(Repair(frameId: id, need: 255))
                    }
                }
                id &+= 1; n += 1
            }
            askedWhole = askedWhole.filter { Int32(bitPattern: $0.key &- exp) >= -2 }
        }
        guard !reps.isEmpty else { return }
        pendingRepairs.append(contentsOf: reps.prefix(8))
        repairRequestsSent += reps.count
        if Self.debug { print("[rx \(dts())] repair request \(reps.map { "\($0.frameId):\($0.need)" })") }
        sendFeedback(nowUs: realNowUs)
    }

    private func sendFeedback(nowUs: UInt64, forceRecovery: Bool = false) {
        guard let ch = channel, let hi = maxSeq else { return }
        var fb = Feedback()
        fb.highestPacketSeq = hi
        let expected = Int(Int32(bitPattern: hi &- (lastReportMaxSeq ?? hi)))
        fb.packetsExpected = UInt16(clamping: max(0, expected))
        fb.packetsReceived = UInt16(clamping: receivedSinceReport)
        fb.framesLost = UInt16(clamping: lostFramesSinceReport)
        lastReportMaxSeq = hi; receivedSinceReport = 0; lostFramesSinceReport = 0
        fb.lastDecodedFrameId = lastDecodedFrameId
        fb.needRecovery = forceRecovery || seq.waitingForRecovery
        fb.queueDelayUs = delay.queueDelayUs
        fb.standingQueueUs = delay.standingQueueUs
        bytesWindow.removeAll { nowUs &- $0.0 > 200_000 }
        fb.goodputKbps = UInt32(Double(bytesWindow.reduce(0) { $0 + $1.1 }) * 8 / 0.2 / 1000)
        fb.echoSendTimeUs = lastEchoSend
        fb.holdUs = UInt32(truncatingIfNeeded: nowUs &- lastEchoRecvUs)
        fb.shownCaptureUs = shownCaptureUs
        fb.shownAgoUs = shownAtUs == 0 ? 0 : UInt32(truncatingIfNeeded: nowUs &- shownAtUs)
        fb.ackedLTRTokens = ackedTokens
        fb.repairs = Array(pendingRepairs.prefix(8)); pendingRepairs.removeAll()
        fbSeq &+= 1
        var w = ByteWriter()
        PacketHeader(kind: .feedback, packetSeq: fbSeq, sendTimeUs: UInt32(truncatingIfNeeded: nowUs)).write(into: &w)
        w.raw(fb.serialize())
        transmit(w.bytes)
        lastFeedbackUs = nowUs
    }

    /// Sends a raw datagram (e.g. an input packet) to the sender on the established flow.
    public func sendRaw(_ bytes: [UInt8]) { queue.async { [self] in transmit(bytes) } }

    /// Until the first media packet arrived, keep poking the sender so it learns the flow.
    public func sendHelloIfNeeded() { queue.async { [self] in if maxSeq == nil { sendFeedbackStub() } } }
    private func sendFeedbackStub() {
        var w = ByteWriter()
        fbSeq &+= 1
        PacketHeader(kind: .feedback, packetSeq: fbSeq, sendTimeUs: LinkClock.nowUs32()).write(into: &w)
        w.raw(Feedback().serialize())
        transmit(w.bytes)
    }

    /// Mac-side/test helper: announce ourselves so the sender learns the UDP flow.
    public func sendHello() {
        var w = ByteWriter()
        fbSeq &+= 1
        PacketHeader(kind: .hello, packetSeq: fbSeq, sendTimeUs: LinkClock.nowUs32()).write(into: &w)
        transmit(w.bytes)
    }
}
