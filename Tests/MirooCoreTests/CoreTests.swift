import XCTest
@testable import MirooCore

final class CoreTests: XCTestCase {
    func randBytes(_ n: Int, seed: UInt64) -> [UInt8] {
        var g = SplitMix(seed: seed)
        return (0..<n).map { _ in UInt8(truncatingIfNeeded: g.next()) }
    }

    func testReedSolomonRecoversAnyLossPattern() {
        for (k, m) in [(1, 1), (4, 2), (10, 3), (30, 6), (60, 10)] {
            let size = 97
            let data = (0..<k).map { randBytes(size, seed: UInt64($0 + 1)) }
            let parity = ReedSolomon.encode(data: data, m: m)
            var g = SplitMix(seed: UInt64(k * 31 + m))
            for _ in 0..<40 {
                var chunks = [Int: [UInt8]]()
                for i in 0..<k { chunks[i] = data[i] }
                for p in 0..<m { chunks[k + p] = parity[p] }
                var all = Array(0..<(k + m)); 
                // drop up to m random chunks
                let drop = Int(g.next() % UInt64(m + 1))
                for _ in 0..<drop { let i = Int(g.next() % UInt64(all.count)); chunks[all[i]] = nil; all.remove(at: i) }
                let rec = ReedSolomon.decode(k: k, m: m, size: size, chunks: chunks)
                XCTAssertEqual(rec, data, "k=\(k) m=\(m) drop=\(drop)")
            }
        }
    }

    func testReedSolomonFailsWhenTooManyLost() {
        let data = (0..<5).map { randBytes(10, seed: UInt64($0)) }
        let parity = ReedSolomon.encode(data: data, m: 2)
        var chunks = [Int: [UInt8]]()
        chunks[0] = data[0]; chunks[1] = data[1]; chunks[5] = parity[0]; chunks[6] = parity[1]
        XCTAssertNil(ReedSolomon.decode(k: 5, m: 2, size: 10, chunks: chunks))
    }

    func testHeaderRoundTrip() {
        let h = PacketHeader(kind: .parity, flags: [.recovery], packetSeq: 0xDEADBEEF, frameId: 77, frameLen: 12345,
                             index: 3, k: 12, m: 4, sendTimeUs: 99)
        var w = ByteWriter(); h.write(into: &w)
        XCTAssertEqual(w.bytes.count, PacketHeader.size)
        let parsed = w.bytes.withUnsafeBytes { var r = ByteReader($0); return PacketHeader.parse(&r) }
        XCTAssertEqual(parsed, h)
    }

    func testEnvelopeAndFeedbackRoundTrip() {
        let e = FrameEnvelope(codec: .hevc, isRecovery: true, ltrToken: -5, captureUs: 1, encodeDoneUs: 2,
                              parameterSets: [[1, 2, 3], [4, 5]], bitstream: randBytes(1000, seed: 1))
        XCTAssertEqual(FrameEnvelope.parse(e.serialize()), e)
        var f = Feedback(); f.highestPacketSeq = 9; f.needRecovery = true; f.ackedLTRTokens = [3, 4]; f.queueDelayUs = 1234
        let parsed = f.serialize().withUnsafeBytes { Feedback.parse($0) }
        XCTAssertEqual(parsed, f)
        XCTAssertNil(FrameEnvelope.parse([1, 2, 3]))
    }

    private func roundTrip(len: Int, m: Int, lossPct: Int, seed: UInt64) -> (ok: Bool, repaired: Bool) {
        let payload = randBytes(len, seed: seed)
        let dgs = Packetizer.packetize(payload: payload, frameId: 5, flags: [], parity: m, maxPayload: 1200,
                                       firstSeq: 0, sendTimeUs: 0)
        let asm = FrameAssembler()
        var g = SplitMix(seed: seed &+ 7)
        var result: AssembledFrame?
        for d in dgs.shuffledDeterministic(&g) {
            if Int(g.next() % 100) < lossPct { continue }
            d.bytes.withUnsafeBytes { buf in
                var r = ByteReader(buf)
                let h = PacketHeader.parse(&r)!
                let body = UnsafeRawBufferPointer(rebasing: buf[PacketHeader.size...])
                if let f = asm.ingest(header: h, body: body, nowUs: 1000) { result = f }
            }
        }
        guard let r = result else { return (false, false) }
        return (r.payload == payload, r.repairedByFEC)
    }

    func testPacketizeAssembleNoLoss() {
        for len in [1, 500, 1200, 1201, 5000, 60_000, 300_000] {
            let r = roundTrip(len: len, m: 2, lossPct: 0, seed: UInt64(len))
            XCTAssertTrue(r.ok, "len=\(len)")
        }
    }

    func testFECRepairsLossWithinParityBudget() {
        // 20 KB frame => k=17; m=4 tolerates 4 lost packets. Drop exactly 3 by seeded pattern.
        let payload = randBytes(20_000, seed: 3)
        let dgs = Packetizer.packetize(payload: payload, frameId: 1, flags: [], parity: 4, maxPayload: 1200,
                                       firstSeq: 0, sendTimeUs: 0)
        let asm = FrameAssembler()
        var out: AssembledFrame?
        for (i, d) in dgs.enumerated() where ![2, 9, 14].contains(i) {
            d.bytes.withUnsafeBytes { buf in
                var r = ByteReader(buf)
                let h = PacketHeader.parse(&r)!
                if let f = asm.ingest(header: h, body: UnsafeRawBufferPointer(rebasing: buf[PacketHeader.size...]), nowUs: 5) { out = f }
            }
        }
        XCTAssertEqual(out?.payload, payload)
        XCTAssertEqual(out?.repairedByFEC, true)
    }

    func testAssemblerExpiresIncompleteFrames() {
        let dgs = Packetizer.packetize(payload: randBytes(10_000, seed: 1), frameId: 9, flags: [], parity: 1,
                                       maxPayload: 1200, firstSeq: 0, sendTimeUs: 0)
        let asm = FrameAssembler()
        dgs.prefix(3).forEach { d in d.bytes.withUnsafeBytes { buf in
            var r = ByteReader(buf); let h = PacketHeader.parse(&r)!
            _ = asm.ingest(header: h, body: UnsafeRawBufferPointer(rebasing: buf[PacketHeader.size...]), nowUs: 100)
        } }
        XCTAssertEqual(asm.expire(nowUs: 5_000, olderThanUs: 10_000), [])
        XCTAssertEqual(asm.expire(nowUs: 20_000, olderThanUs: 10_000), [9])
        XCTAssertEqual(asm.pendingCount, 0)
    }

    private func frame(_ id: UInt32, recovery: Bool = false) -> AssembledFrame {
        AssembledFrame(frameId: id, flags: recovery ? [.recovery] : [], payload: [1], firstArrivalUs: 0, lastArrivalUs: 0,
                       sendTimeUs: 0, packetsReceived: 1, packetsTotal: 1, repairedByFEC: false)
    }

    func testSequencerInOrderAndRecovery() {
        let s = FrameSequencer(holdUs: 5_000)
        // stream must start with a recovery frame
        XCTAssertEqual(s.onFrame(frame(1), nowUs: 0).actions, [.requestRecovery])
        XCTAssertEqual(s.onFrame(frame(10, recovery: true), nowUs: 0).decode.map(\.frameId), [10])
        XCTAssertEqual(s.onFrame(frame(11), nowUs: 0).decode.map(\.frameId), [11])
        // frame 12 missing, 13 arrives early -> held, then 12 arrives -> both decode in order
        XCTAssertTrue(s.onFrame(frame(13), nowUs: 100).decode.isEmpty)
        XCTAssertEqual(s.onFrame(frame(12), nowUs: 200).decode.map(\.frameId), [12, 13])
        // frame 14 lost for good, 15 held -> after hold time we request recovery and drop 15
        XCTAssertTrue(s.onFrame(frame(15), nowUs: 1_000).decode.isEmpty)
        XCTAssertEqual(s.tick(nowUs: 2_000), [])
        XCTAssertEqual(s.tick(nowUs: 7_000), [.requestRecovery])
        XCTAssertTrue(s.onFrame(frame(16), nowUs: 8_000).decode.isEmpty)           // still waiting
        XCTAssertEqual(s.onFrame(frame(17, recovery: true), nowUs: 9_000).decode.map(\.frameId), [17])
        XCTAssertEqual(s.onFrame(frame(18), nowUs: 9_100).decode.map(\.frameId), [18])
    }

    func testSequencerAbandonedFrameBreaksChain() {
        let s = FrameSequencer()
        _ = s.onFrame(frame(1, recovery: true), nowUs: 0)
        XCTAssertEqual(s.onFramesAbandoned([2]), [.requestRecovery])
        XCTAssertTrue(s.waitingForRecovery)
    }

    func testDelayTrackerMeasuresQueueGrowth() {
        let d = DelayTracker()
        var t: UInt64 = 1_000_000
        for _ in 0..<200 { d.add(sendUs32: UInt32(truncatingIfNeeded: t) &- 3_000, recvUs: t); t += 1_000 }
        XCTAssertLessThan(d.queueDelayUs, 100)
        for _ in 0..<50 { d.add(sendUs32: UInt32(truncatingIfNeeded: t) &- 3_000 &- 8_000, recvUs: t); t += 1_000 }
        XCTAssertGreaterThan(d.queueDelayUs, 6_000)
    }

    func testInputRedundancySurvivesPacketLoss() {
        let tx = InputSender(redundancy: 4), rx = InputReceiver()
        var got = [InputEvent]()
        func deliver(_ p: [UInt8]) {
            p.withUnsafeBytes { buf in
                var r = ByteReader(buf); let h = PacketHeader.parse(&r)!
                XCTAssertEqual(h.kind, .input)
                got += rx.ingest(UnsafeRawBufferPointer(rebasing: buf[PacketHeader.size...]))
            }
        }
        tx.add(.down, x: 0.1, y: 0.2); deliver(tx.packet(nowUs32: 1))
        tx.add(.move, x: 0.2, y: 0.2); _ = tx.packet(nowUs32: 2)             // lost
        tx.add(.move, x: 0.3, y: 0.2); _ = tx.packet(nowUs32: 3)             // lost
        tx.add(.up, x: 0.3, y: 0.2);   deliver(tx.packet(nowUs32: 4))        // recovers the two lost moves + up
        XCTAssertEqual(got.map(\.kind), [.down, .move, .move, .up])
        XCTAssertEqual(got.map(\.seq), [1, 2, 3, 4])
        deliver(tx.packet(nowUs32: 5))                                        // duplicate datagram adds nothing
        XCTAssertEqual(got.count, 4)
    }

    func testOutageClockFreezesDuringSilence() {
        var c = OutageClock(thresholdUs: 60_000)
        var real: UInt64 = 1_000_000
        var v = c.advance(real: real, packet: true)
        // link alive: virtual tracks real
        for _ in 0..<10 { real += 5_000; v = c.advance(real: real, packet: true) }
        let before = v
        // 200 ms of total silence: first 60 ms count fully, the remaining 140 ms at 1/20 speed
        for _ in 0..<40 { real += 5_000; v = c.advance(real: real, packet: false) }
        XCTAssertLessThan(v - before, 80_000, "virtual time must nearly stop during an outage")
        XCTAssertGreaterThan(v - before, 55_000)
        // link returns: the interval that ended in silence still counts slowly, then full speed again
        let resumed = v
        real += 5_000; v = c.advance(real: real, packet: true)      // +250 (silent interval at 1/20)
        real += 5_000; v = c.advance(real: real, packet: true)      // +5000
        XCTAssertEqual(v - resumed, 5_250, accuracy: 300)
    }

    func testRSThroughputIsFast() {
        // 100 KB frame, 5 parity: must encode in well under a millisecond-ish budget per frame on Apple silicon
        let payload = randBytes(100_000, seed: 2)
        measure {
            _ = Packetizer.packetize(payload: payload, frameId: 1, flags: [], parity: 5, maxPayload: 1200,
                                     firstSeq: 0, sendTimeUs: 0)
        }
    }
}

extension Array {
    func shuffledDeterministic(_ g: inout SplitMix) -> [Element] {
        var a = self
        for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, Int(g.next() % UInt64(i + 1))) }
        return a
    }
}
