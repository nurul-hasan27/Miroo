//
//  Phase8ATests.swift
//  Miroo
//
//  Automated Verification Test Suite for Miroo Phase 8A:
//  Transport Abstraction + UDP Video Transport + Bounded Jitter Buffer + TCP Baseline
//

import Foundation
import MirooNetworking

func assertCondition(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        print("❌ FAIL [Line \(line)]: \(message)")
        exit(1)
    }
}

@main
struct Phase8ATests {
    static func main() async {
        print("==================================================================")
        print("    Miroo Phase 8A: Transport Abstraction & UDP Test Suite       ")
        print("==================================================================")

        testUDPPacketSerializationDeserialization()
        testPacketFragmentation()
        testFrameReassemblyInOrder()
        testFrameReassemblyOutOfOrder()
        testPacketLossDetection()
        testIncompleteFrameDeadlineDrop()
        testStaleFrameDropOnNewerArrival()
        testStaleFrameFragmentsRejected()
        testSessionTokenValidation()
        testRegistrationPayloadSerialization()
        testBoundedJitterBufferDepthLimit()
        testTCPControlMessages()
        testStreamConfigTransportPayload()
        testRegressionPhase6A_TouchSerialization()
        testRegressionPhase6B_ScrollAndRightClickSerialization()
        testSequenceDiscontinuityKeyframeRecovery()
        testMultiFrameContinuousStreaming()
        testRenderViewportLayoutLandscapeHardwareSafeAreas()

        print("\n==================================================================")
        print("🎉 ALL 18 PHASE 8A & STABILIZATION AUTOMATED TESTS PASSED SUCCESSFULLY!")
        print("==================================================================")
    }

    // 1. Packet Serialization & Deserialization
    static func testUDPPacketSerializationDeserialization() {
        print("\n[Test 1] UDP Packet Serialization & Deserialization...")
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        let original = MirooUDPPacket(
            flags: .keyframe,
            sessionToken: 777888,
            packetSequenceNumber: 1042,
            frameSequenceNumber: 42,
            fragmentIndex: 2,
            fragmentCount: 5,
            ptsNanoseconds: 1234567890,
            captureTimestampNs: 100000000,
            encodeStartTimestampNs: 101000000,
            encodeCompleteTimestampNs: 103000000,
            networkSendTimestampNs: 104000000,
            encodeDurationUs: 2000,
            macQueueDelayUs: 1000,
            payload: payload
        )

        let bytes = original.serialize()
        assertCondition(bytes.count == MirooUDPPacket.headerSize + payload.count, "Serialized size mismatch")

        guard let parsed = MirooUDPPacket.deserialize(from: bytes) else {
            assertCondition(false, "Failed to deserialize valid MirooUDPPacket")
            return
        }

        assertCondition(parsed.isKeyframe == true, "Keyframe flag mismatch")
        assertCondition(parsed.sessionToken == 777888, "Session token mismatch")
        assertCondition(parsed.packetSequenceNumber == 1042, "Packet sequence mismatch")
        assertCondition(parsed.frameSequenceNumber == 42, "Frame sequence mismatch")
        assertCondition(parsed.fragmentIndex == 2, "Fragment index mismatch")
        assertCondition(parsed.fragmentCount == 5, "Fragment count mismatch")
        assertCondition(parsed.ptsNanoseconds == 1234567890, "PTS mismatch")
        assertCondition(parsed.captureTimestampNs == 100000000, "Capture timestamp mismatch")
        assertCondition(parsed.encodeStartTimestampNs == 101000000, "Encode start timestamp mismatch")
        assertCondition(parsed.encodeCompleteTimestampNs == 103000000, "Encode complete timestamp mismatch")
        assertCondition(parsed.networkSendTimestampNs == 104000000, "Network send timestamp mismatch")
        assertCondition(parsed.encodeDurationUs == 2000, "Encode duration mismatch")
        assertCondition(parsed.macQueueDelayUs == 1000, "Queue delay mismatch")
        assertCondition(parsed.payload == payload, "Payload content mismatch")
        print("  ✓ Correct 76-byte binary header with full stage timestamps & payload verified.")
    }

    // 2. Packet Fragmentation
    static func testPacketFragmentation() {
        print("\n[Test 2] MTU-Safe Frame Fragmentation...")
        let frameSize = 4500
        var dummyData = Data(count: frameSize)
        for i in 0..<frameSize {
            dummyData[i] = UInt8(i % 256)
        }

        var packetSeq: UInt32 = 100
        let timing = VideoFrameTiming(
            captureTimestampNs: 500,
            encodeStartTimestampNs: 600,
            encodeCompleteTimestampNs: 800,
            networkSendTimestampNs: 900,
            encodeDurationUs: 200,
            macQueueDelayUs: 100
        )

        let packets = MirooUDPPacket.fragment(
            sequence: 55,
            pts: 987654321,
            isKeyframe: true,
            annexBData: dummyData,
            timing: timing,
            sessionToken: 12345,
            startPacketSeq: &packetSeq,
            maxPayload: 1200
        )

        // 4500 / 1200 = 3 chunks of 1200 + 1 chunk of 900 = 4 chunks
        assertCondition(packets.count == 4, "Expected 4 fragments for 4500 bytes, got \(packets.count)")
        assertCondition(packetSeq == 104, "packetSequenceCounter must advance to 104")

        for (idx, p) in packets.enumerated() {
            assertCondition(p.frameSequenceNumber == 55, "Frame sequence must match")
            assertCondition(p.fragmentIndex == UInt16(idx), "Fragment index must match")
            assertCondition(p.fragmentCount == 4, "Fragment count must be 4")
            assertCondition(p.sessionToken == 12345, "Session token must match")
            assertCondition(p.isKeyframe == true, "Keyframe flag must match")
            assertCondition(p.payload.count <= 1200, "Fragment size must be <= 1200 bytes")
        }
        assertCondition(packets[3].payload.count == 900, "Last chunk must be 900 bytes")
        print("  ✓ 4500-byte frame fragmented safely into 4 MTU-safe chunks (<1200 bytes).")
    }

    // 3. Frame Reassembly in Order
    static func testFrameReassemblyInOrder() {
        print("\n[Test 3] Complete Frame Reassembly in Order...")
        let frameSize = 3500
        var originalData = Data(count: frameSize)
        for i in 0..<frameSize {
            originalData[i] = UInt8((i * 7) % 256)
        }

        let token: UInt32 = 999111
        let jitterBuffer = UDPBoundedJitterBuffer(sessionToken: token, maxPendingFrames: 4, frameTimeoutMs: 100.0)

        var completedPayload: Data?
        var completedSeq: UInt64?
        var isKey: Bool?

        jitterBuffer.onFrameCompleted = { seq, pts, keyframe, data, timing, recvNs in
            completedSeq = seq
            completedPayload = data
            isKey = keyframe
        }

        var pktSeq: UInt32 = 1
        let packets = MirooUDPPacket.fragment(
            sequence: 101,
            pts: 555555,
            isKeyframe: true,
            annexBData: originalData,
            timing: nil,
            sessionToken: token,
            startPacketSeq: &pktSeq,
            maxPayload: 1000
        )

        assertCondition(packets.count == 4, "Should create 4 packets")

        for p in packets {
            let serialized = p.serialize()
            let accepted = jitterBuffer.ingestPacket(data: serialized)
            assertCondition(accepted, "Packet must be accepted")
        }

        assertCondition(completedSeq == 101, "Delivered sequence must be 101")
        assertCondition(isKey == true, "Delivered isKeyframe must be true")
        assertCondition(completedPayload == originalData, "Delivered payload must match originalData exactly")
        assertCondition(jitterBuffer.framesReconstructed == 1, "framesReconstructed counter must be 1")
        print("  ✓ All 4 fragments ingested in order and reconstructed into exact original frame.")
    }

    // 4. Frame Reassembly Out of Order
    static func testFrameReassemblyOutOfOrder() {
        print("\n[Test 4] Frame Reassembly Out of Order (Scrambled Arrivals)...")
        let frameSize = 2500
        var originalData = Data(count: frameSize)
        for i in 0..<frameSize {
            originalData[i] = UInt8((i * 13) % 256)
        }

        let token: UInt32 = 888222
        let jitterBuffer = UDPBoundedJitterBuffer(sessionToken: token, maxPendingFrames: 4, frameTimeoutMs: 100.0)

        var completedPayload: Data?

        jitterBuffer.onFrameCompleted = { seq, pts, keyframe, data, timing, recvNs in
            completedPayload = data
        }

        var pktSeq: UInt32 = 50
        let packets = MirooUDPPacket.fragment(
            sequence: 200,
            pts: 1000,
            isKeyframe: false,
            annexBData: originalData,
            timing: nil,
            sessionToken: token,
            startPacketSeq: &pktSeq,
            maxPayload: 1000
        )

        assertCondition(packets.count == 3, "Should create 3 packets (1000, 1000, 500)")

        // Ingest in scrambled order: Index 2, Index 0, Index 1
        let order = [2, 0, 1]
        for idx in order {
            let p = packets[idx]
            jitterBuffer.ingestPacket(data: p.serialize())
        }

        assertCondition(completedPayload == originalData, "Reassembled payload from scrambled fragments must match originalData")
        assertCondition(jitterBuffer.framesReconstructed == 1, "Reconstructed count must be 1")
        print("  ✓ Out-of-order fragments [2, 0, 1] correctly buffered and assembled.")
    }

    // 5. Packet Loss Detection
    static func testPacketLossDetection() {
        print("\n[Test 5] Missing Packet Sequence Gap Detection...")
        let token: UInt32 = 111333
        let jitterBuffer = UDPBoundedJitterBuffer(sessionToken: token, maxPendingFrames: 4, frameTimeoutMs: 100.0)

        let p1 = MirooUDPPacket(sessionToken: token, packetSequenceNumber: 100, frameSequenceNumber: 1, fragmentIndex: 0, fragmentCount: 2, ptsNanoseconds: 0, payload: Data([0x01]))
        let p3 = MirooUDPPacket(sessionToken: token, packetSequenceNumber: 103, frameSequenceNumber: 1, fragmentIndex: 1, fragmentCount: 2, ptsNanoseconds: 0, payload: Data([0x02]))

        jitterBuffer.ingestPacket(data: p1.serialize())
        assertCondition(jitterBuffer.packetsLost == 0, "No loss yet")

        // Jump from 100 to 103 -> packets 101 and 102 are missing (2 lost)
        jitterBuffer.ingestPacket(data: p3.serialize())
        assertCondition(jitterBuffer.packetsLost == 2, "Expected 2 lost packets detected, got \(jitterBuffer.packetsLost)")
        print("  ✓ Sequence gap (100 -> 103) detected 2 lost packets accurately.")
    }

    // 6. Incomplete Frame Deadline Drop
    static func testIncompleteFrameDeadlineDrop() {
        print("\n[Test 6] Incomplete Frame Deadline Drop & IDR Request...")
        let token: UInt32 = 444555
        // Set short timeout of 15ms for test speed
        let jitterBuffer = UDPBoundedJitterBuffer(sessionToken: token, maxPendingFrames: 4, frameTimeoutMs: 15.0)

        var keyframeNeededCalled = false
        jitterBuffer.onKeyframeNeeded = {
            keyframeNeededCalled = true
        }

        // Send fragment 0 of 2 for a keyframe
        let p1 = MirooUDPPacket(flags: .keyframe, sessionToken: token, packetSequenceNumber: 1, frameSequenceNumber: 50, fragmentIndex: 0, fragmentCount: 2, ptsNanoseconds: 0, payload: Data([0xAA]))
        jitterBuffer.ingestPacket(data: p1.serialize())

        assertCondition(jitterBuffer.currentPendingCount == 1, "Pending count should be 1")

        // Sleep 30ms to exceed 15ms deadline
        Thread.sleep(forTimeInterval: 0.030)

        // Ingest a packet from a new frame to trigger purge
        let pNext = MirooUDPPacket(sessionToken: token, packetSequenceNumber: 2, frameSequenceNumber: 51, fragmentIndex: 0, fragmentCount: 1, ptsNanoseconds: 0, payload: Data([0xBB]))
        jitterBuffer.ingestPacket(data: pNext.serialize())

        assertCondition(jitterBuffer.incompleteFramesDropped >= 1, "Incomplete frame must be dropped")
        assertCondition(keyframeNeededCalled == true, "onKeyframeNeeded callback must be invoked when incomplete keyframe expires")
        print("  ✓ Expired incomplete keyframe purged after deadline timeout; IDR recovery requested.")
    }

    // 7. Stale Frame Drop on Newer Arrival
    static func testStaleFrameDropOnNewerArrival() {
        print("\n[Test 7] Fresh Frame > Stale Frame (Older Pending Drop)...")
        let token: UInt32 = 666777
        let jitterBuffer = UDPBoundedJitterBuffer(sessionToken: token, maxPendingFrames: 4, frameTimeoutMs: 200.0)

        // Frame 10: only send fragment 0 of 2 (incomplete)
        let f10_p0 = MirooUDPPacket(sessionToken: token, packetSequenceNumber: 1, frameSequenceNumber: 10, fragmentIndex: 0, fragmentCount: 2, ptsNanoseconds: 10, payload: Data([0x10]))
        jitterBuffer.ingestPacket(data: f10_p0.serialize())
        assertCondition(jitterBuffer.currentPendingCount == 1, "Pending should be 1")

        // Frame 11: complete (1 of 1 fragment)
        let f11_p0 = MirooUDPPacket(sessionToken: token, packetSequenceNumber: 2, frameSequenceNumber: 11, fragmentIndex: 0, fragmentCount: 1, ptsNanoseconds: 20, payload: Data([0x11]))
        var deliveredSeq: UInt64 = 0
        jitterBuffer.onFrameCompleted = { seq, _, _, _, _, _ in
            deliveredSeq = seq
        }

        jitterBuffer.ingestPacket(data: f11_p0.serialize())

        assertCondition(deliveredSeq == 11, "Frame 11 should be delivered immediately")
        assertCondition(jitterBuffer.staleFramesDropped >= 1, "Older incomplete frame 10 must be dropped as stale")
        assertCondition(jitterBuffer.currentPendingCount == 0, "No pending frames remaining")
        print("  ✓ Newer complete frame delivered; stale pending frame dropped without latency penalty.")
    }

    // 8. Stale Frame Fragments Rejected
    static func testStaleFrameFragmentsRejected() {
        print("\n[Test 8] Rejection of Delayed Stale Fragments...")
        let token: UInt32 = 888999
        let jitterBuffer = UDPBoundedJitterBuffer(sessionToken: token, maxPendingFrames: 4, frameTimeoutMs: 200.0)

        // Frame 5 delivers completely
        let f5 = MirooUDPPacket(sessionToken: token, packetSequenceNumber: 1, frameSequenceNumber: 5, fragmentIndex: 0, fragmentCount: 1, ptsNanoseconds: 0, payload: Data([0x05]))
        jitterBuffer.ingestPacket(data: f5.serialize())

        let dropsBefore = jitterBuffer.staleFramesDropped

        // Now a delayed fragment for frame 4 arrives
        let delayed_f4 = MirooUDPPacket(sessionToken: token, packetSequenceNumber: 2, frameSequenceNumber: 4, fragmentIndex: 0, fragmentCount: 2, ptsNanoseconds: 0, payload: Data([0x04]))
        let accepted = jitterBuffer.ingestPacket(data: delayed_f4.serialize())

        assertCondition(accepted, "Ingest packet returns true")
        assertCondition(jitterBuffer.staleFramesDropped == dropsBefore + 1, "Delayed fragment with seq <= lastDelivered must be dropped")
        print("  ✓ Fragments of already-delivered or stale frames discarded immediately.")
    }

    // 9. Session Token Validation
    static func testSessionTokenValidation() {
        print("\n[Test 9] Session Token Validation (Foreign Traffic Isolation)...")
        let jitterBuffer = UDPBoundedJitterBuffer(sessionToken: 123456, maxPendingFrames: 4, frameTimeoutMs: 100.0)

        // Packet with wrong session token
        let roguePacket = MirooUDPPacket(sessionToken: 999999, packetSequenceNumber: 1, frameSequenceNumber: 1, fragmentIndex: 0, fragmentCount: 1, ptsNanoseconds: 0, payload: Data([0xFF]))
        let processed = jitterBuffer.ingestPacket(data: roguePacket.serialize())

        assertCondition(!processed, "Packet with wrong session token must be rejected")
        assertCondition(jitterBuffer.packetsReceived == 0, "Rejected packet must not be counted in valid received packets")
        print("  ✓ Foreign / stale UDP session packets rejected cleanly.")
    }

    // 10. Registration Payload Serialization
    static func testRegistrationPayloadSerialization() {
        print("\n[Test 10] UDP Registration Payload Serialization...")
        let original = UDPRegistrationPayload(sessionToken: 0xCAFEBABE)
        let bytes = original.serialize()
        assertCondition(bytes.count == 8, "Registration packet must be exactly 8 bytes")

        guard let parsed = UDPRegistrationPayload.deserialize(from: bytes) else {
            assertCondition(false, "Failed to deserialize valid registration payload")
            return
        }

        assertCondition(parsed.sessionToken == 0xCAFEBABE, "Session token mismatch")
        print("  ✓ 8-byte UDP registration datagram serialized and deserialized.")
    }

    // 11. Bounded Jitter Buffer Depth Limit
    static func testBoundedJitterBufferDepthLimit() {
        print("\n[Test 11] Bounded Jitter Buffer Capacity Enforcement (Max 4 Pending Frames)...")
        let token: UInt32 = 333222
        let jitterBuffer = UDPBoundedJitterBuffer(sessionToken: token, maxPendingFrames: 4, frameTimeoutMs: 1000.0)

        // Insert fragment 0 of 2 for 4 distinct frames: 1, 2, 3, 4
        for f in 1...4 {
            let p = MirooUDPPacket(sessionToken: token, packetSequenceNumber: UInt32(f), frameSequenceNumber: UInt64(f), fragmentIndex: 0, fragmentCount: 2, ptsNanoseconds: 0, payload: Data([UInt8(f)]))
            jitterBuffer.ingestPacket(data: p.serialize())
        }
        assertCondition(jitterBuffer.currentPendingCount == 4, "Buffer should hold 4 pending frames")

        // Ingest fragment 0 of 2 for 5th frame: frame 1 should be dropped to keep count <= 4
        let p5 = MirooUDPPacket(sessionToken: token, packetSequenceNumber: 5, frameSequenceNumber: 5, fragmentIndex: 0, fragmentCount: 2, ptsNanoseconds: 0, payload: Data([0x05]))
        jitterBuffer.ingestPacket(data: p5.serialize())

        assertCondition(jitterBuffer.currentPendingCount == 4, "Buffer count must remain bounded at 4")
        assertCondition(jitterBuffer.incompleteFramesDropped == 1, "Oldest frame must be dropped")
        print("  ✓ Bounded window strictly caps pending frames at max capacity (4), dropping oldest incomplete.")
    }

    // 12. TCP Control Messages
    static func testTCPControlMessages() {
        print("\n[Test 12] TCP Control Messages (KEYFRAME_REQUEST, SET_TRANSPORT)...")

        // Keyframe request
        let kfMsg = MirooMessage.keyframeRequest(reason: "recovery_test")
        let kfSerialized = kfMsg.serialize()
        guard let kfHeader = MirooHeader.deserialize(from: kfSerialized) else {
            assertCondition(false, "Failed to deserialize header for keyframe request")
            return
        }
        assertCondition(kfHeader.messageType == .keyframeRequest, "Expected message type keyframeRequest")
        let kfParsed = MirooMessage(header: kfHeader, payload: kfSerialized.subdata(in: MirooHeader.headerSize..<kfSerialized.count))
        let kfPayload = kfParsed.decodeKeyframeRequest()
        assertCondition(kfPayload?.reason == "recovery_test", "Keyframe request reason mismatch")

        // Set transport
        let stMsg = MirooMessage.setTransport(transport: "UDP", udpPort: 51042, sessionToken: 789123)
        let stSerialized = stMsg.serialize()
        guard let stHeader = MirooHeader.deserialize(from: stSerialized) else {
            assertCondition(false, "Failed to deserialize header for set transport")
            return
        }
        assertCondition(stHeader.messageType == .setTransport, "Expected message type setTransport")
        let stParsed = MirooMessage(header: stHeader, payload: stSerialized.subdata(in: MirooHeader.headerSize..<stSerialized.count))
        let stPayload = stParsed.decodeSetTransport()
        assertCondition(stPayload?.transport == "UDP", "Transport mismatch")
        assertCondition(stPayload?.udpPort == 51042, "UDP port mismatch")
        assertCondition(stPayload?.sessionToken == 789123, "Session token mismatch")
        print("  ✓ Reliable TCP control messages KEYFRAME_REQUEST and SET_TRANSPORT verified.")
    }

    // 13. StreamConfig Transport Payload
    static func testStreamConfigTransportPayload() {
        print("\n[Test 13] STREAM_CONFIG Transport Negotiation...")
        let original = StreamConfigPayload(
            codec: "H264",
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 10_000_000,
            orientation: .landscape,
            transport: "UDP",
            udpPort: 51042,
            sessionToken: 555888
        )

        let encoded = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(StreamConfigPayload.self, from: encoded)

        assertCondition(decoded.codec == "H264", "Codec mismatch")
        assertCondition(decoded.width == 1920, "Width mismatch")
        assertCondition(decoded.height == 1080, "Height mismatch")
        assertCondition(decoded.orientation == .landscape, "Orientation mismatch")
        assertCondition(decoded.transport == "UDP", "Transport mismatch")
        assertCondition(decoded.udpPort == 51042, "UDP port mismatch")
        assertCondition(decoded.sessionToken == 555888, "Session token mismatch")
        print("  ✓ STREAM_CONFIG preserves transport selection and session token parameters.")
    }

    // 14. Phase 6A Touch Regression Test
    static func testRegressionPhase6A_TouchSerialization() {
        print("\n[Test 14] Phase 6A Regression: Single-Finger Touch...")
        let touch = TouchEventPayload(phase: .moved, touchID: 1, x: 0.75, y: 0.25, timestampNs: 99887766)
        let bytes = touch.serialize()
        assertCondition(bytes.count == 21, "Touch payload must be 21 bytes")

        guard let parsed = TouchEventPayload.deserialize(from: bytes) else {
            assertCondition(false, "Failed to deserialize touch payload")
            return
        }

        assertCondition(parsed.phase == .moved, "Phase mismatch")
        assertCondition(parsed.touchID == 1, "Touch ID mismatch")
        assertCondition(abs(parsed.x - 0.75) < 0.0001, "X coordinate mismatch")
        assertCondition(abs(parsed.y - 0.25) < 0.0001, "Y coordinate mismatch")
        assertCondition(parsed.timestampNs == 99887766, "Timestamp mismatch")
        print("  ✓ Phase 6A touch serialization fully intact and unaffected.")
    }

    // 15. Phase 6B Scroll & Right Click Regression Test
    static func testRegressionPhase6B_ScrollAndRightClickSerialization() {
        print("\n[Test 15] Phase 6B Regression: Scroll & Right Click Payloads...")
        let scroll = ScrollEventPayload(deltaX: -12.5, deltaY: 34.0, timestampNs: 11223344)
        let scrollBytes = scroll.serialize()
        assertCondition(scrollBytes.count == 16, "Scroll payload must be 16 bytes")

        guard let parsedScroll = ScrollEventPayload.deserialize(from: scrollBytes) else {
            assertCondition(false, "Failed to deserialize scroll payload")
            return
        }
        assertCondition(abs(parsedScroll.deltaX - (-12.5)) < 0.001, "Delta X mismatch")
        assertCondition(abs(parsedScroll.deltaY - 34.0) < 0.001, "Delta Y mismatch")
        assertCondition(parsedScroll.timestampNs == 11223344, "Scroll timestamp mismatch")

        let rc = RightClickPayload(timestampNs: 55667788)
        let rcBytes = rc.serialize()
        assertCondition(rcBytes.count == 8, "Right click payload must be 8 bytes")

        guard let parsedRC = RightClickPayload.deserialize(from: rcBytes) else {
            assertCondition(false, "Failed to deserialize right click payload")
            return
        }
        assertCondition(parsedRC.timestampNs == 55667788, "Right click timestamp mismatch")
        print("  ✓ Phase 6B trackpad scrolling and right click payloads fully intact.")
    }

    // 16. Sequence Discontinuity & IDR Keyframe Request
    static func testSequenceDiscontinuityKeyframeRecovery() {
        print("\n[Test 16] Sequence Discontinuity IDR Keyframe Trigger...")
        let token: UInt32 = 112233
        let jitterBuffer = UDPBoundedJitterBuffer(sessionToken: token, maxPendingFrames: 4, frameTimeoutMs: 100.0)

        var keyframeRequested = false
        jitterBuffer.onKeyframeNeeded = {
            keyframeRequested = true
        }

        // Deliver frame 1 (complete)
        let f1 = MirooUDPPacket(sessionToken: token, packetSequenceNumber: 1, frameSequenceNumber: 1, fragmentIndex: 0, fragmentCount: 1, ptsNanoseconds: 100, payload: Data([0x01]))
        jitterBuffer.ingestPacket(data: f1.serialize())

        // Frame 2 is completely dropped over the network (simulated UDP packet drop)
        // Now Frame 3 arrives (delta frame)
        let f3 = MirooUDPPacket(sessionToken: token, packetSequenceNumber: 2, frameSequenceNumber: 3, fragmentIndex: 0, fragmentCount: 1, ptsNanoseconds: 300, payload: Data([0x03]))

        var deliveredSeq: UInt64 = 0
        jitterBuffer.onFrameCompleted = { seq, _, _, _, _, _ in
            deliveredSeq = seq
        }

        jitterBuffer.ingestPacket(data: f3.serialize())

        assertCondition(keyframeRequested == true, "onKeyframeNeeded must be triggered upon sequence gap (seq 1 -> seq 3)")
        assertCondition(deliveredSeq == 3, "Frame 3 must still be reconstructed and delivered")
        print("  ✓ Sequence gap detected; IDR recovery requested and reassembled frame delivered.")
    }

    // 17. Multi-Frame Continuous Streaming
    static func testMultiFrameContinuousStreaming() {
        print("\n[Test 17] Multi-Frame Continuous Streaming Reassembly...")
        let token: UInt32 = 445566
        let jitterBuffer = UDPBoundedJitterBuffer(sessionToken: token, maxPendingFrames: 4, frameTimeoutMs: 100.0)

        var deliveredFrames: [UInt64] = []
        jitterBuffer.onFrameCompleted = { seq, _, _, _, _, _ in
            deliveredFrames.append(seq)
        }

        var packetSeq: UInt32 = 1
        for frameSeq: UInt64 in 1...10 {
            // Each frame has 3 fragments
            for fragIdx: UInt16 in 0..<3 {
                let packet = MirooUDPPacket(
                    sessionToken: token,
                    packetSequenceNumber: packetSeq,
                    frameSequenceNumber: frameSeq,
                    fragmentIndex: fragIdx,
                    fragmentCount: 3,
                    ptsNanoseconds: Int64(frameSeq * 16_666_666),
                    payload: Data([UInt8(frameSeq), UInt8(fragIdx)])
                )
                packetSeq += 1
                jitterBuffer.ingestPacket(data: packet.serialize())
            }
        }

        assertCondition(deliveredFrames.count == 10, "All 10 frames must be reassembled and delivered (got \(deliveredFrames.count))")
        assertCondition(deliveredFrames == Array(1...10), "Delivered frame order must match 1...10")
        assertCondition(jitterBuffer.incompleteFramesDropped == 0, "Zero incomplete frame drops")
        assertCondition(jitterBuffer.staleFramesDropped == 0, "Zero stale frame drops")
        print("  ✓ Continuous multi-frame UDP stream reassembled seamlessly with zero frame drops.")
    }

    // 18. Viewport Layout & Landscape Aspect Fit
    static func testRenderViewportLayoutLandscapeHardwareSafeAreas() {
        print("\n[Test 18] Viewport Layout Landscape Aspect Fit & Safe Area Alignment...")
        // iPhone 11 landscape usable screen: 848 x 393 points (usable area excluding notch and home bar)
        let usableBounds = CGRect(x: 0, y: 0, width: 848, height: 393)
        let drawableSize = CGSize(width: 1696, height: 786)
        let macLandscapeVideoSize = CGSize(width: 2532, height: 1170)

        let layout = RenderViewportLayout.compute(
            viewBounds: usableBounds,
            drawableSize: drawableSize,
            videoSize: macLandscapeVideoSize
        )

        // Verify video aspect ratio closely matches usable screen:
        // Mac: 2532 / 1170 = 2.1641
        // Screen: 1696 / 786 = 2.1578
        // Fill percentage: renderRectPixels.width / drawableSize.width should be > 99%
        let fillRatioX = layout.renderRectPixels.width / drawableSize.width
        let fillRatioY = layout.renderRectPixels.height / drawableSize.height
        assertCondition(fillRatioX > 0.99 || fillRatioY > 0.99, "Video must fill >99% of usable screen area")
        assertCondition(layout.renderRectPixels.minX >= 0, "No negative margins")
        print("  ✓ Landscape video fills usable area (>99% fill ratio) with zero distortion.")
    }
}
