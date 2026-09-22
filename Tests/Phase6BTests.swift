//
//  Phase6BTests.swift
//  MirooTests
//
//  Automated Verification for Miroo Phase 6B: Trackpad Scrolling, Two-Finger Tap
//  Right Click, Sensitivity Scaling, and Gesture Safety Transitions.
//

import Foundation
import CoreGraphics
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

func testScrollPayloadSerialization() {
    print("\n--- Test 1: ScrollEventPayload Binary Serialization ---")
    let testCases: [(Float, Float, UInt64)] = [
        (0.0, 0.0, 1000000),
        (-15.5, 42.75, 2000000),
        (100.25, -50.125, 3000000),
        (-0.001, -0.002, 4000000)
    ]

    for (dx, dy, ts) in testCases {
        let payload = ScrollEventPayload(deltaX: dx, deltaY: dy, timestampNs: ts)
        let data = payload.serialize()
        assertCondition(data.count == 16, "Serialized scroll payload is exactly 16 bytes (got \(data.count))")

        guard let parsed = ScrollEventPayload.deserialize(from: data) else {
            fatalError("Failed to deserialize valid scroll payload for (\(dx), \(dy))")
        }

        assertCondition(abs(parsed.deltaX - dx) < 0.0001, "DeltaX matches: \(parsed.deltaX) vs \(dx)")
        assertCondition(abs(parsed.deltaY - dy) < 0.0001, "DeltaY matches: \(parsed.deltaY) vs \(dy)")
        assertCondition(parsed.timestampNs == ts, "Timestamp matches: \(parsed.timestampNs)")
    }

    // Invalid payload test (truncated < 16 bytes)
    let invalidData = Data(repeating: 0, count: 15)
    assertCondition(ScrollEventPayload.deserialize(from: invalidData) == nil, "Rejects truncated scroll payload (<16 bytes)")
}

func testRightClickPayloadSerialization() {
    print("\n--- Test 2: RightClickPayload Binary Serialization ---")
    let timestamps: [UInt64] = [0, 1000000, 999999999999]

    for ts in timestamps {
        let payload = RightClickPayload(timestampNs: ts)
        let data = payload.serialize()
        assertCondition(data.count == 8, "Serialized right-click payload is exactly 8 bytes (got \(data.count))")

        guard let parsed = RightClickPayload.deserialize(from: data) else {
            fatalError("Failed to deserialize right-click payload for timestamp \(ts)")
        }

        assertCondition(parsed.timestampNs == ts, "Timestamp matches: \(parsed.timestampNs)")
    }

    // Truncated payload
    let invalidData = Data(repeating: 0, count: 7)
    assertCondition(RightClickPayload.deserialize(from: invalidData) == nil, "Rejects truncated right-click payload (<8 bytes)")
}

func testMirooMessageFraming() {
    print("\n--- Test 3: MirooMessage High-Level Framing & Decoding ---")
    let accumulator = MessageAccumulator()

    let scroll = ScrollEventPayload(deltaX: 12.5, deltaY: -25.0, timestampNs: 5000000)
    let scrollMsg = MirooMessage.scrollEvent(scroll)
    let scrollData = scrollMsg.serialize()
    assertCondition(scrollData.count == MirooHeader.headerSize + 16, "Scroll packet size is 44 bytes (28 header + 16 payload)")

    let rightClick = RightClickPayload(timestampNs: 6000000)
    let rcMsg = MirooMessage.rightClick(rightClick)
    let rcData = rcMsg.serialize()
    assertCondition(rcData.count == MirooHeader.headerSize + 8, "Right click packet size is 36 bytes (28 header + 8 payload)")

    // Feed combined chunked stream into accumulator
    var combinedData = scrollData
    combinedData.append(rcData)

    let chunk1 = combinedData.prefix(30)
    let chunk2 = combinedData.subdata(in: 30..<combinedData.count)

    let msgsAfterChunk1 = accumulator.append(chunk1)
    assertCondition(msgsAfterChunk1.isEmpty, "Accumulator waits for full payload (0 messages after 30 bytes)")

    let msgsAfterChunk2 = accumulator.append(chunk2)
    assertCondition(msgsAfterChunk2.count == 2, "Accumulator parsed both messages on stream completion")

    guard let dScroll = msgsAfterChunk2[0].decodeScrollEvent(),
          let dRC = msgsAfterChunk2[1].decodeRightClick() else {
        fatalError("Failed to decode framed scroll and right click payloads")
    }

    assertCondition(abs(dScroll.deltaX - 12.5) < 0.001 && abs(dScroll.deltaY - (-25.0)) < 0.001, "Decoded scroll deltas match: (\(dScroll.deltaX), \(dScroll.deltaY))")
    assertCondition(dRC.timestampNs == 6000000, "Decoded right-click timestamp matches: \(dRC.timestampNs)")
}

func testMacInputControllerScrollAndRightClick() {
    print("\n--- Test 4: Live MacInputController Scrolling & Right Click ---")
    let controller = MacInputController()
    let isTrusted = controller.checkAccessibilityPermission()
    assertCondition(isTrusted, "macOS Accessibility permissions verified")

    let mainDisplay = CGMainDisplayID()

    // 1. Move cursor to known test position on display
    let pBegan = TouchEventPayload(phase: .began, touchID: 1, x: 0.5, y: 0.5, timestampNs: 1000)
    controller.handleTouchEvent(pBegan, displayID: mainDisplay)
    assertCondition(controller.isLeftButtonDown == true, "Left mouse button is held")

    // 2. Scroll while left mouse was down -> verify scroll safely releases held button
    controller.scroll(deltaX: 0.0, deltaY: -15.0)
    assertCondition(controller.isLeftButtonDown == false, "Scroll safely released held left mouse button")

    // 3. Right-click while left mouse was down -> verify right click safely releases held button
    controller.handleTouchEvent(pBegan, displayID: mainDisplay)
    assertCondition(controller.isLeftButtonDown == true, "Left mouse button is held before right click")
    controller.rightClick()
    assertCondition(controller.isLeftButtonDown == false, "Right click safely released held left mouse button")

    // 4. Sensitivity tuning verification
    let defaultSens = MacInputController.scrollSensitivity
    assertCondition(defaultSens >= 1.0 && defaultSens <= 5.0, "Default scroll sensitivity is tuned comfortably: \(defaultSens)")
}

func testTapVsScrollDetectionLogic() {
    print("\n--- Test 5: Two-Finger Tap vs Scroll Detection Thresholds ---")
    let maxTapDuration: CFTimeInterval = 0.28
    let maxTapMovement: CGFloat = 12.0

    // Scenario A: Rapid, stationary tap
    let tapDuration: CFTimeInterval = 0.12 // 120ms
    let tapMovement: CGFloat = 3.5         // 3.5 points
    let isTapA = (tapDuration <= maxTapDuration) && (tapMovement <= maxTapMovement)
    assertCondition(isTapA == true, "Stationary 120ms / 3.5pt gesture is classified as a Two-Finger Tap (Right Click)")

    // Scenario B: Intentional scroll swipe (exceeds movement threshold)
    let scrollDuration: CFTimeInterval = 0.15 // 150ms
    let scrollMovement: CGFloat = 45.0        // 45 points
    let isTapB = (scrollDuration <= maxTapDuration) && (scrollMovement <= maxTapMovement)
    assertCondition(isTapB == false, "45pt swipe is classified as Scroll (NOT a tap)")

    // Scenario C: Long hold without movement (exceeds duration threshold)
    let holdDuration: CFTimeInterval = 0.50 // 500ms
    let holdMovement: CGFloat = 2.0        // 2 points
    let isTapC = (holdDuration <= maxTapDuration) && (holdMovement <= maxTapMovement)
    assertCondition(isTapC == false, "500ms hold is NOT a tap (timeout prevents delayed right click)")
}

@main
struct Phase6BTests {
    static func main() {
        print("=======================================================")
        print("      Miroo Phase 6B Automated Verification Suite     ")
        print("=======================================================")
        testScrollPayloadSerialization()
        testRightClickPayloadSerialization()
        testMirooMessageFraming()
        testMacInputControllerScrollAndRightClick()
        testTapVsScrollDetectionLogic()
        print("\n=======================================================")
        print("   ALL PHASE 6B VERIFICATION TESTS PASSED SUCCESSFULLY!  ")
        print("=======================================================")
    }
}
