//
//  ProtocolAndQueueTests.swift
//  MirooTests
//
//  Tests for Miroo protocol binary framing, TCP defragmentation, and bounded queue backpressure.
//

import Foundation
#if canImport(MirooNetworking)
import MirooNetworking
#endif

func assertCondition(_ condition: Bool, _ message: String) {
    if !condition {
        print("❌ ASSERTION FAILED: \(message)")
        exit(1)
    }
    print("✅ \(message)")
}

func testHeaderSerialization() {
    print("\n--- Test 1: Header Serialization & Deserialization ---")
    let header = MirooHeader(
        messageType: .videoFrame,
        flags: .keyframe,
        sequence: 12345678901234,
        pts: 98765432109876,
        payloadLength: 65536
    )

    let data = header.serialize()
    assertCondition(data.count == MirooHeader.headerSize, "Header size is exactly 28 bytes (got \(data.count))")

    guard let parsed = MirooHeader.deserialize(from: data) else {
        fatalError("Failed to deserialize valid header")
    }

    assertCondition(parsed.magic == MirooHeader.magicValue, "Magic is 'MIRO' (0x4D49524F)")
    assertCondition(parsed.version == 1, "Version is 1")
    assertCondition(parsed.messageType == .videoFrame, "Message type is VIDEO_FRAME")
    assertCondition(parsed.isKeyframe == true, "Keyframe flag is set")
    assertCondition(parsed.sequence == 12345678901234, "Sequence number matches: \(parsed.sequence)")
    assertCondition(parsed.pts == 98765432109876, "PTS matches: \(parsed.pts)")
    assertCondition(parsed.payloadLength == 65536, "Payload length matches: \(parsed.payloadLength)")
}

func testTCPDefragmentation() {
    print("\n--- Test 2: TCP Stream Defragmentation & Coalescing ---")
    let accumulator = MessageAccumulator()

    let payload1 = Data(repeating: 0xAA, count: 50)
    let msg1 = MirooMessage(type: .videoFrame, sequence: 1, payload: payload1)
    let rawMsg1 = msg1.serialize()

    let payload2 = Data(repeating: 0xBB, count: 120)
    let msg2 = MirooMessage(type: .videoFrame, flags: .keyframe, sequence: 2, payload: payload2)
    let rawMsg2 = msg2.serialize()

    // Scenario A: Split header (10 bytes first, then rest of message 1)
    let chunk1 = rawMsg1.prefix(10)
    let chunk2 = rawMsg1.dropFirst(10)

    let res1 = accumulator.append(chunk1)
    assertCondition(res1.isEmpty, "Partial header yielded 0 messages")

    let res2 = accumulator.append(chunk2)
    assertCondition(res2.count == 1, "Completing message yielded 1 message")
    assertCondition(res2[0].header.sequence == 1, "Message sequence is 1")
    assertCondition(res2[0].payload == payload1, "Payload 1 data matches")

    // Scenario B: Coalesced stream + partial second message
    var stream = Data()
    stream.append(rawMsg1)
    stream.append(rawMsg2)

    // Send in irregular arbitrary TCP chunk sizes (e.g. 23 bytes at a time)
    var extracted: [MirooMessage] = []
    var offset = 0
    let chunkSize = 23

    while offset < stream.count {
        let end = min(offset + chunkSize, stream.count)
        let sub = stream.subdata(in: offset..<end)
        extracted.append(contentsOf: accumulator.append(sub))
        offset = end
    }

    assertCondition(extracted.count == 2, "Extracted exactly 2 coalesced/fragmented messages")
    assertCondition(extracted[0].header.sequence == 1 && extracted[0].payload.count == 50, "First message matches")
    assertCondition(extracted[1].header.sequence == 2 && extracted[1].header.isKeyframe && extracted[1].payload.count == 120, "Second message matches with keyframe")
}

func testDesynchronizationRecovery() {
    print("\n--- Test 3: Desynchronization Recovery ---")
    let accumulator = MessageAccumulator()

    let validMsg = MirooMessage(type: .ping, sequence: 99, payload: Data([0x01, 0x02, 0x03]))
    let validData = validMsg.serialize()

    // Prepend 17 bytes of random garbage before valid message
    var corruptedStream = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x00, 0xFF, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x11, 0x22])
    corruptedStream.append(validData)

    let results = accumulator.append(corruptedStream)
    assertCondition(results.count == 1, "Successfully recovered from corrupt stream and parsed valid message")
    assertCondition(results[0].header.messageType == .ping, "Parsed message is PING")
    assertCondition(results[0].header.sequence == 99, "Sequence number is 99")
}

func testBoundedQueueBackpressure() {
    print("\n--- Test 4: Bounded Queue Backpressure Policy ---")
    let queue = FrameQueue(maxDepth: 3)

    // Enqueue 3 delta frames
    let f1 = QueuedFrame(sequence: 1, pts: 100, isKeyframe: false, data: Data(count: 1000))
    let f2 = QueuedFrame(sequence: 2, pts: 200, isKeyframe: false, data: Data(count: 1000))
    let f3 = QueuedFrame(sequence: 3, pts: 300, isKeyframe: false, data: Data(count: 1000))

    queue.enqueue(f1)
    queue.enqueue(f2)
    queue.enqueue(f3)

    assertCondition(queue.count == 3, "Queue holds exactly 3 frames (at capacity)")
    assertCondition(queue.totalDropped == 0, "No frames dropped yet")

    // Enqueue frame 4 (delta). Queue must drop oldest delta (f1) to favor freshest frame (f4)
    let f4 = QueuedFrame(sequence: 4, pts: 400, isKeyframe: false, data: Data(count: 1000))
    queue.enqueue(f4)

    assertCondition(queue.count == 3, "Queue remains bounded at maxDepth=3")
    assertCondition(queue.totalDropped == 1, "1 frame dropped due to backpressure")

    // Verify remaining frames are 2, 3, 4
    let popped1 = queue.dequeue()
    assertCondition(popped1?.sequence == 2, "Popped frame is #2 (freshest preserved, #1 was dropped)")

    // Enqueue a keyframe into queue having 3 and 4
    let f5 = QueuedFrame(sequence: 5, pts: 500, isKeyframe: false, data: Data(count: 1000))
    queue.enqueue(f5) // Queue now has 3, 4, 5

    let keyframe = QueuedFrame(sequence: 6, pts: 600, isKeyframe: true, data: Data(count: 5000))
    queue.enqueue(keyframe) // Should purge older deltas to make room for keyframe!

    assertCondition(queue.totalDropped >= 2, "Old deltas dropped to prioritize keyframe")

    let poppedNext = queue.dequeue()
    assertCondition(poppedNext?.isKeyframe == true, "Keyframe was preserved and delivered")
}

print("Running Miroo Protocol & Queue Unit Tests...")
testHeaderSerialization()
testTCPDefragmentation()
testDesynchronizationRecovery()
testBoundedQueueBackpressure()

print("\n🎉 ALL UNIT TESTS PASSED SUCCESSFULLY!\n")
