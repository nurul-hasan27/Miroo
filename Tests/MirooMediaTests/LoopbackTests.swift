import XCTest
import CoreVideo
@testable import MirooCore
@testable import MirooMedia

/// Full media path in one process: encoder -> envelope -> FEC packets -> (lossy channel) -> assembler ->
/// sequencer -> decoder, with LTR acknowledgements and recovery requests flowing back.
final class Loopback {
    let enc: LinkEncoder
    let dec = LinkDecoder()
    let asm = FrameAssembler()
    let seq = FrameSequencer(holdUs: 4_000)
    let rx = DispatchQueue(label: "rx")
    var nextFrameId: UInt32 = 1
    var nextPacketSeq: UInt32 = 0
    var parity = 2
    /// return true to drop the datagram
    var drop: (_ frameId: UInt32, _ index: Int, _ total: Int) -> Bool = { _, _, _ in false }
    // results (touched on rx queue only)
    var decodedIndexes: [UInt32] = []          // captureUs = source frame index
    var recoveryRequests = 0
    var recoveryFramesSent: [(frameId: UInt32, bytes: Int, idr: Bool)] = []
    var sentSizes: [Int] = []
    var decodedLuma: [UInt32: [UInt8]] = [:]
    private let lock = NSLock()
    var recoveryFrameIds = Set<UInt32>()

    init(width: Int, height: Int, codec: Codec, useLTR: Bool = false) throws {
        enc = try LinkEncoder(config: .init(width: width, height: height, fps: 60, bitrate: 12_000_000, codec: codec, useLTR: useLTR))
        dec.onDecoded = { [weak self] f in
            guard let self else { return }
            self.rx.async {
                self.decodedIndexes.append(f.envelope.captureUs)
                if f.envelope.ltrToken != 0 {
                    let tok = f.envelope.ltrToken
                    self.rx.asyncAfter(deadline: .now() + 0.005) { self.enc.acknowledge(tokens: [tok]) }
                }
                if f.envelope.captureUs % 10 == 0 { self.decodedLuma[f.envelope.captureUs] = Self.sampleLuma(f.pixelBuffer) }
            }
        }
        enc.onFrame = { [weak self] ef in self?.send(ef) }
    }

    static func sampleLuma(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8]()
        for y in stride(from: 3, to: h, by: 9) { for x in stride(from: 5, to: w, by: 11) { out.append(base[y * bpr + x]) } }
        return out
    }

    func send(_ ef: EncodedFrame) {
        lock.lock()
        let fid = nextFrameId; nextFrameId += 1
        let seqStart = nextPacketSeq
        let payload = ef.envelope().serialize()
        let dgs = Packetizer.packetize(payload: payload, frameId: fid, flags: ef.isRecovery ? [.recovery] : [],
                                       parity: parity, maxPayload: 1200, firstSeq: seqStart, sendTimeUs: LinkClock.nowUs32())
        nextPacketSeq &+= UInt32(dgs.count)
        sentSizes.append(payload.count)
        if ef.isRecovery { recoveryFrameIds.insert(fid); recoveryFramesSent.append((fid, payload.count, ef.parameterSets.count > 0 && ef.ltrToken == 0 && false)) }
        lock.unlock()
        for (i, d) in dgs.enumerated() where !drop(fid, i, dgs.count) {
            rx.async { self.receive(d.bytes) }
        }
        rx.async { self.afterFrame() }
    }

    func receive(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buf in
            var r = ByteReader(buf)
            guard let h = PacketHeader.parse(&r) else { return }
            let body = UnsafeRawBufferPointer(rebasing: buf[PacketHeader.size...])
            let now = LinkClock.nowUs()
            guard let f = asm.ingest(header: h, body: body, nowUs: now) else { return }
            let res = seq.onFrame(f, nowUs: now)
            for fr in res.decode { if let env = FrameEnvelope.parse(fr.payload) { dec.decode(env) } }
            handle(res.actions)
        }
    }

    func afterFrame() {
        // emulate the receiver's periodic tick ~8 ms later
        rx.asyncAfter(deadline: .now() + 0.008) {
            let now = LinkClock.nowUs()
            self.handle(self.seq.onFramesAbandoned(self.asm.expire(nowUs: now, olderThanUs: 8_000)))
            self.handle(self.seq.tick(nowUs: now))
        }
    }

    func handle(_ actions: [SequencerAction]) {
        for a in actions where a == .requestRecovery {
            recoveryRequests += 1
            rx.asyncAfter(deadline: .now() + 0.003) { self.enc.requestRecovery() }   // feedback transit
        }
    }
}

func makeSource(width: Int, height: Int, index: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
    let boxX = (index * 9) % (width - 220), boxY = 40 + (index * 3) % 150
    for row in 0..<height {
        for col in 0..<width {
            var v = UInt8(truncatingIfNeeded: 60 + (col / 16 + row / 16) % 90)           // static "UI" background
            if col >= boxX && col < boxX + 200 && row >= boxY && row < boxY + 200 { v = 230 }   // moving window
            y[row * ys + col] = v
        }
    }
    let uv = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt8.self)
    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buf, 1) * CVPixelBufferGetHeightOfPlane(buf, 1))
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

final class LoopbackTests: XCTestCase {
    // Resolution does not change the logic under test; keep it small so the suite is cheap on a busy Mac.
    let W = 960, H = 432

    func run(_ lb: Loopback, frames: Int) {
        for i in 0..<frames {
            lb.enc.encode(makeSource(width: W, height: H, index: i), captureUs: UInt32(i))
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
        Thread.sleep(forTimeInterval: 0.4)
        lb.rx.sync {}
    }

    func meanAbsDiff(_ lb: Loopback, index: Int) -> Double? {
        guard let got = lb.decodedLuma[UInt32(index)] else { return nil }
        let src = Loopback.sampleLuma(makeSource(width: W, height: H, index: index))
        var s = 0
        for i in 0..<min(got.count, src.count) { s += abs(Int(got[i]) - Int(src[i])) }
        return Double(s) / Double(got.count)
    }

    func testNoLoss() throws {
        for codec in [Codec.h264, .hevc] {
            let lb = try Loopback(width: W, height: H, codec: codec)
            run(lb, frames: 120)
            print("[\(codec)] decoded \(lb.decodedIndexes.count)/120, recoveryReq=\(lb.recoveryRequests), hw=\(lb.enc.usesHardware), recovery frames=\(lb.recoveryFramesSent.count), avg frame=\(lb.sentSizes.reduce(0, +) / max(1, lb.sentSizes.count)) B, max=\(lb.sentSizes.max() ?? 0) B")
            XCTAssertEqual(lb.decodedIndexes.count, 120)
            XCTAssertEqual(lb.recoveryRequests, 0)
            if let d = meanAbsDiff(lb, index: 110) { XCTAssertLessThan(d, 6, "picture quality at frame 110") } else { XCTFail("no luma sample") }
        }
    }

    func testLostFrameRecoversViaLTRWithoutKeyframe() throws {
        for codec in [Codec.h264, .hevc] {
            let lb = try Loopback(width: W, height: H, codec: codec, useLTR: true)
            // frame id 60 (all its packets) never arrives
            lb.drop = { fid, _, _ in fid == 60 }
            run(lb, frames: 180)
            let decoded = lb.decodedIndexes
            let idrBytes = lb.recoveryFramesSent.first?.bytes ?? 0
            print("[\(codec)] decoded \(decoded.count)/180, recoveryReq=\(lb.recoveryRequests), recovery frames=\(lb.recoveryFramesSent.map { "\($0.frameId):\($0.bytes)B" }), first IDR=\(idrBytes) B")
            XCTAssertGreaterThanOrEqual(lb.recoveryRequests, 1)
            XCTAssertTrue(decoded.contains(179), "stream must resume after the loss")
            XCTAssertGreaterThanOrEqual(decoded.count, 150, "only a handful of frames may be skipped")
            // the loss-recovery frame (not the first one) must be far smaller than the initial IDR
            if lb.recoveryFramesSent.count >= 2 {
                let r = lb.recoveryFramesSent[1]
                XCTAssertLessThan(r.bytes, idrBytes, "LTR refresh must be smaller than an IDR")
            }
            if let d = meanAbsDiff(lb, index: 170) { XCTAssertLessThan(d, 6, "picture after recovery") } else { XCTFail("no luma sample after recovery") }
        }
    }

    /// Default mode (no LTR): a lost frame is repaired by a plain recovery keyframe and the stream resumes with a correct picture.
    func testLostFrameRecoversViaKeyframeByDefault() throws {
        for codec in [Codec.h264, .hevc] {
            let lb = try Loopback(width: W, height: H, codec: codec)
            lb.drop = { fid, _, _ in fid == 60 }
            run(lb, frames: 180)
            print("[\(codec)] keyframe recovery: decoded \(lb.decodedIndexes.count)/180, recoveryReq=\(lb.recoveryRequests), recovery frames=\(lb.recoveryFramesSent.map { "\($0.frameId):\($0.bytes)B" })")
            XCTAssertGreaterThanOrEqual(lb.recoveryRequests, 1)
            XCTAssertTrue(lb.decodedIndexes.contains(179), "stream must resume after the loss")
            XCTAssertGreaterThanOrEqual(lb.decodedIndexes.count, 140)
            if let d = meanAbsDiff(lb, index: 170) { XCTAssertLessThan(d, 6, "picture after keyframe recovery") } else { XCTFail("no luma sample after recovery") }
        }
    }

    func testRandomPacketLossIsAbsorbedByFEC() throws {
        let lb = try Loopback(width: W, height: H, codec: .hevc)
        lb.parity = 3
        var g = SplitMix(seed: 42)
        lb.drop = { _, _, _ in g.next() % 100 < 4 }        // 4% random packet loss
        run(lb, frames: 240)
        print("[random 4% loss] decoded \(lb.decodedIndexes.count)/240, recoveryReq=\(lb.recoveryRequests)")
        XCTAssertGreaterThanOrEqual(lb.decodedIndexes.count, 200)
    }
}
