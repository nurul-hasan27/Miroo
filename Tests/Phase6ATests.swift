//
//  Phase6ATests.swift
//  MirooTests
//
//  Automated Verification for Miroo Phase 6A: Touch Protocol, Coordinate Normalization,
//  Boundary Clamping, and Connection-Loss Safety.
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

func testTouchPayloadSerialization() {
    print("\n--- Test 1: TouchEventPayload Binary Serialization ---")
    let testCases: [(TouchEventPayload.Phase, UInt32, Float, Float, UInt64)] = [
        (.began, 1, 0.0, 0.0, 1000000),
        (.moved, 1, 0.52345, 0.98765, 2000000),
        (.ended, 1, 1.0, 1.0, 3000000),
        (.cancelled, 2, 0.123, 0.456, 4000000)
    ]

    for (phase, tid, x, y, ts) in testCases {
        let payload = TouchEventPayload(phase: phase, touchID: tid, x: x, y: y, timestampNs: ts)
        let data = payload.serialize()
        assertCondition(data.count == 21, "Serialized touch payload is exactly 21 bytes (got \(data.count))")

        guard let parsed = TouchEventPayload.deserialize(from: data) else {
            fatalError("Failed to deserialize valid touch payload for phase \(phase)")
        }

        assertCondition(parsed.phase == phase, "Phase matches: \(parsed.phase)")
        assertCondition(parsed.touchID == tid, "Touch ID matches: \(parsed.touchID)")
        assertCondition(abs(parsed.x - x) < 0.00001, "X coordinate matches: \(parsed.x) vs \(x)")
        assertCondition(abs(parsed.y - y) < 0.00001, "Y coordinate matches: \(parsed.y) vs \(y)")
        assertCondition(parsed.timestampNs == ts, "Timestamp matches: \(parsed.timestampNs)")
    }

    // Invalid payload test (truncated)
    let invalidData = Data(repeating: 0, count: 20)
    assertCondition(TouchEventPayload.deserialize(from: invalidData) == nil, "Rejects truncated payload (<21 bytes)")
}

func testMirooMessageTouchFraming() {
    print("\n--- Test 2: MirooMessage High-Level Framing with MessageAccumulator ---")
    let accumulator = MessageAccumulator()

    let p1 = TouchEventPayload(phase: .began, touchID: 1, x: 0.25, y: 0.75, timestampNs: 5000000)
    let msg1 = MirooMessage.touchEvent(p1)
    let rawData1 = msg1.serialize()

    let p2 = TouchEventPayload(phase: .moved, touchID: 1, x: 0.30, y: 0.70, timestampNs: 6000000)
    let msg2 = MirooMessage.touchEvent(p2)
    let rawData2 = msg2.serialize()

    assertCondition(rawData1.count == MirooHeader.headerSize + 21, "Total packet size is 49 bytes (28 header + 21 payload)")

    // Split packet stream simulation (TCP fragmentation)
    var combinedData = rawData1
    combinedData.append(rawData2)

    let chunk1 = combinedData.prefix(35)
    let chunk2 = combinedData.subdata(in: 35..<combinedData.count)

    let msgsAfterChunk1 = accumulator.append(chunk1)
    assertCondition(msgsAfterChunk1.isEmpty, "Accumulator waits for full payload (0 messages after 35 bytes)")

    let msgsAfterChunk2 = accumulator.append(chunk2)
    assertCondition(msgsAfterChunk2.count == 2, "Accumulator correctly parsed both messages upon completion")

    guard let d1 = msgsAfterChunk2[0].decodeTouchEvent(),
          let d2 = msgsAfterChunk2[1].decodeTouchEvent() else {
        fatalError("Failed to decode framed touch payloads")
    }

    assertCondition(d1.phase == .began && abs(d1.x - 0.25) < 0.0001, "Message 1 decoded correctly: phase began, x 0.25")
    assertCondition(d2.phase == .moved && abs(d2.x - 0.30) < 0.0001, "Message 2 decoded correctly: phase moved, x 0.30")
}

func testCoordinateClamping() {
    print("\n--- Test 3: Viewport Layout Touch Clamping & Exclusion ---")
    // Aspect fit a tall video (1170x2532) in a square view (500x500)
    // Usable video width = 500 * (1170/2532) = 231.04 points centered.
    // Margins on left and right = (500 - 231.04) / 2 = ~134.48 points each.
    let viewBounds = CGRect(x: 0, y: 0, width: 500, height: 500)
    let drawableSize = CGSize(width: 1000, height: 1000)
    let videoSize = CGSize(width: 1170, height: 2532)

    let layout = RenderViewportLayout.compute(
        viewBounds: viewBounds,
        drawableSize: drawableSize,
        videoSize: videoSize
    )

    // A. Center point inside active video area
    let centerPoint = CGPoint(x: 250, y: 250)
    let normCenter = layout.touchToNormalizedVideoCoordinate(centerPoint, clamp: false)
    assertCondition(normCenter != nil, "Center point is recognized inside contentRect")
    if let c = normCenter {
        assertCondition(abs(c.x - 0.5) < 0.05 && abs(c.y - 0.5) < 0.05, "Center point normalizes near (0.5, 0.5): got (\(c.x), \(c.y))")
    }

    // B. Touch in margin area (x = 50 points, outside video width) with clamp = false
    let marginPoint = CGPoint(x: 50, y: 250)
    let normMargin = layout.touchToNormalizedVideoCoordinate(marginPoint, clamp: false)
    assertCondition(normMargin == nil, "Touch inside margin/notch area is rejected when clamp=false")

    // C. Touch in margin area with clamp = true (e.g. during dragging out to left edge)
    let normMarginClamped = layout.touchToNormalizedVideoCoordinate(marginPoint, clamp: true)
    assertCondition(normMarginClamped != nil, "Touch inside margin area produces clamped coordinate when clamp=true")
    if let mc = normMarginClamped {
        assertCondition(mc.x == 0.0, "Clamped X is exactly 0.0 at left: \(mc.x)")
    }

    // D. Touch past right margin with clamp = true
    let rightMarginPoint = CGPoint(x: 480, y: 250)
    let normRightClamped = layout.touchToNormalizedVideoCoordinate(rightMarginPoint, clamp: true)
    assertCondition(normRightClamped != nil && normRightClamped!.x == 1.0, "Clamped X is exactly 1.0 at right: \(normRightClamped?.x ?? -1)")
}

func testMacDisplayCoordinateMapping() {
    print("\n--- Test 4: Mac Virtual Display Coordinate Mapping ---")
    // 1. Portrait mode virtual display: origin at (1512, 0), size 585x1266
    let portraitBounds = CGRect(x: 1512, y: 0, width: 585, height: 1266)

    func mapToMac(x: Float, y: Float, bounds: CGRect) -> CGPoint {
        let clampedX = CGFloat(min(max(x, 0.0), 1.0))
        let clampedY = CGFloat(min(max(y, 0.0), 1.0))
        return CGPoint(
            x: bounds.origin.x + clampedX * bounds.size.width,
            y: bounds.origin.y + clampedY * bounds.size.height
        )
    }

    // Top-Left (0.0, 0.0) -> (1512, 0)
    let ptTopLeft = mapToMac(x: 0.0, y: 0.0, bounds: portraitBounds)
    assertCondition(ptTopLeft.x == 1512.0 && ptTopLeft.y == 0.0, "Portrait (0,0) maps to virtual display top-left (1512, 0)")

    // Center (0.5, 0.5) -> (1512 + 292.5 = 1804.5, 633.0)
    let ptCenter = mapToMac(x: 0.5, y: 0.5, bounds: portraitBounds)
    assertCondition(abs(ptCenter.x - 1804.5) < 0.001 && abs(ptCenter.y - 633.0) < 0.001, "Portrait (0.5, 0.5) maps to center (1804.5, 633)")

    // Bottom-Right (1.0, 1.0) -> (1512 + 585 = 2097, 1266)
    let ptBottomRight = mapToMac(x: 1.0, y: 1.0, bounds: portraitBounds)
    assertCondition(ptBottomRight.x == 2097.0 && ptBottomRight.y == 1266.0, "Portrait (1,1) maps to virtual display bottom-right (2097, 1266)")

    // Out-of-bounds negative clamping (-0.2, -0.5) -> (1512, 0)
    let ptNeg = mapToMac(x: -0.2, y: -0.5, bounds: portraitBounds)
    assertCondition(ptNeg.x == 1512.0 && ptNeg.y == 0.0, "Out-of-bounds negative touch clamps safely to (1512, 0)")

    // Out-of-bounds overflow clamping (1.5, 2.0) -> (2097, 1266)
    let ptOverflow = mapToMac(x: 1.5, y: 2.0, bounds: portraitBounds)
    assertCondition(ptOverflow.x == 2097.0 && ptOverflow.y == 1266.0, "Out-of-bounds overflow touch clamps safely to (2097, 1266)")

    // 2. Landscape mode virtual display: origin at (1512, 0), size 1266x585
    let landscapeBounds = CGRect(x: 1512, y: 0, width: 1266, height: 585)

    let lsTopLeft = mapToMac(x: 0.0, y: 0.0, bounds: landscapeBounds)
    assertCondition(lsTopLeft.x == 1512.0 && lsTopLeft.y == 0.0, "Landscape (0,0) maps to virtual display top-left (1512, 0)")

    let lsCenter = mapToMac(x: 0.5, y: 0.5, bounds: landscapeBounds)
    assertCondition(abs(lsCenter.x - (1512.0 + 633.0)) < 0.001 && abs(lsCenter.y - 292.5) < 0.001, "Landscape (0.5, 0.5) maps to center (2145, 292.5)")

    let lsBottomRight = mapToMac(x: 1.0, y: 1.0, bounds: landscapeBounds)
    assertCondition(lsBottomRight.x == (1512.0 + 1266.0) && lsBottomRight.y == 585.0, "Landscape (1,1) maps to virtual display bottom-right (2778, 585)")
}

func testMacInputControllerLive() {
    print("\n--- Test 5: Live MacInputController State & Safety Verification ---")
    let controller = MacInputController()
    let isTrusted = controller.checkAccessibilityPermission()
    assertCondition(isTrusted, "macOS Accessibility permissions are active and verified")

    let mainDisplay = CGMainDisplayID()
    let initialPos = controller.lastCursorPosition

    // 1. Touch Began at (0.2, 0.3)
    let pBegan = TouchEventPayload(phase: .began, touchID: 1, x: 0.2, y: 0.3, timestampNs: 1000)
    controller.handleTouchEvent(pBegan, displayID: mainDisplay)
    assertCondition(controller.isLeftButtonDown == true, "Left mouse button is depressed on .began")
    let beganPos = controller.lastCursorPosition
    assertCondition(beganPos != initialPos, "Cursor moved to initial touch location: \(beganPos)")

    // 2. Touch Moved to (0.25, 0.35) (Dragging)
    let pMoved = TouchEventPayload(phase: .moved, touchID: 1, x: 0.25, y: 0.35, timestampNs: 2000)
    controller.handleTouchEvent(pMoved, displayID: mainDisplay)
    assertCondition(controller.isLeftButtonDown == true, "Left mouse button remains depressed during drag (.moved)")
    assertCondition(controller.lastCursorPosition != beganPos, "Cursor moved during drag: \(controller.lastCursorPosition)")

    // 3. Touch Ended at (0.25, 0.35)
    let pEnded = TouchEventPayload(phase: .ended, touchID: 1, x: 0.25, y: 0.35, timestampNs: 3000)
    controller.handleTouchEvent(pEnded, displayID: mainDisplay)
    assertCondition(controller.isLeftButtonDown == false, "Left mouse button is released on .ended")

    // 4. Touch Cancelled safety check
    controller.handleTouchEvent(pBegan, displayID: mainDisplay)
    assertCondition(controller.isLeftButtonDown == true, "Left mouse button is depressed before cancel")
    let pCancel = TouchEventPayload(phase: .cancelled, touchID: 1, x: 0.2, y: 0.3, timestampNs: 4000)
    controller.handleTouchEvent(pCancel, displayID: mainDisplay)
    assertCondition(controller.isLeftButtonDown == false, "Left mouse button is released on .cancelled")

    // 5. Disconnect safety check
    controller.handleTouchEvent(pBegan, displayID: mainDisplay)
    assertCondition(controller.isLeftButtonDown == true, "Left mouse button is depressed before disconnect")
    controller.releaseAllButtons()
    assertCondition(controller.isLeftButtonDown == false, "Left mouse button is guaranteed released on releaseAllButtons() (disconnect)")
}

@main
struct Phase6ATests {
    static func main() {
        print("=======================================================")
        print("      Miroo Phase 6A Automated Verification Suite     ")
        print("=======================================================")
        testTouchPayloadSerialization()
        testMirooMessageTouchFraming()
        testCoordinateClamping()
        testMacDisplayCoordinateMapping()
        testMacInputControllerLive()
        print("\n=======================================================")
        print("   ALL PHASE 6A VERIFICATION TESTS PASSED SUCCESSFULLY!  ")
        print("=======================================================")
    }
}
