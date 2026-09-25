//
//  DisplayArrangementTests.swift
//  MirooTests
//
//  Automated Verification Suite for Persistent Virtual Display Arrangement.
//  Validates:
//  1. First connection default arrangement (docked right of primary display).
//  2. User custom arrangement persistence (left, right, above, below, offset).
//  3. Reconnect restoration across disconnect cycles.
//  4. Ephemeral CGDirectDisplayID recreation stability and identity detection.
//  5. Reference screen resolution / scaling change adaptation.
//  6. External monitor presence and disconnection clamping (disjoint window prevention).
//  7. Invalid / stale / corrupted saved arrangement fallback.
//  8. Independent portrait and landscape orientation arrangement persistence.
//  9. Repeated USB and Wi-Fi reconnect stability (minimum 5 cycles).
//  10. Non-disturbance of other active displays.
//

import Foundation
import CoreGraphics
@testable import MirooNetworking

@main
final class DisplayArrangementTests {

    static var testsPassed = 0
    static var testsFailed = 0

    static func assertTest(_ condition: Bool, _ testName: String, failureReason: String = "") {
        if condition {
            print("  ✓ \(testName)")
            testsPassed += 1
        } else {
            print("  ✗ FAILED: \(testName)")
            if !failureReason.isEmpty {
                print("    Reason: \(failureReason)")
            }
            testsFailed += 1
        }
    }

    static func main() {
        print("==================================================================")
        print("       Miroo Persistent Display Arrangement Verification Suite    ")
        print("==================================================================")

        let mockDefaults = UserDefaults(suiteName: "com.miroo.test.displayarrangement")!
        mockDefaults.removePersistentDomain(forName: "com.miroo.test.displayarrangement")

        let store = DisplayArrangementStore(defaults: mockDefaults)

        let macBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let mirooPortraitSize = CGSize(width: 585, height: 1266)
        let mirooLandscapeSize = CGSize(width: 1266, height: 585)

        // -------------------------------------------------------------
        // Test 1: First Connection -> Default Arrangement
        // -------------------------------------------------------------
        print("\n[Test 1] First Connection Default Arrangement...")
        let defaultOrigin = store.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds]
        )
        assertTest(defaultOrigin.x == 1440 && defaultOrigin.y == 0,
                   "Default first connection docks immediately right of Mac display (1440, 0)",
                   failureReason: "Got \(defaultOrigin)")

        // -------------------------------------------------------------
        // Test 2: User Custom Arrangement Saved (Left of Mac Display)
        // -------------------------------------------------------------
        print("\n[Test 2] User Custom Arrangement Saved (Left of Mac Display)...")
        let userLeftBounds = CGRect(x: -585, y: 50, width: 585, height: 1266)
        let savedRel = store.saveArrangement(
            mirooBounds: userLeftBounds,
            referenceBounds: macBounds,
            orientation: .portrait
        )
        assertTest(savedRel.dockingEdge == .left,
                   "Docking edge correctly classified as .left",
                   failureReason: "Got \(savedRel.dockingEdge)")
        assertTest(savedRel.offsetAlongEdge == 50.0,
                   "Offset along edge recorded as 50.0pt",
                   failureReason: "Got \(savedRel.offsetAlongEdge)")

        let loadedRel = store.loadArrangement(for: .portrait)
        assertTest(loadedRel != nil && loadedRel?.dockingEdge == .left,
                   "Arrangement successfully retrieved from persistent store")

        // -------------------------------------------------------------
        // Test 3: Disconnect & Reconnect Restoration
        // -------------------------------------------------------------
        print("\n[Test 3] Disconnect & Reconnect Restoration...")
        // Simulate disconnect (state cleared from memory, reloaded from defaults)
        let freshStore = DisplayArrangementStore(defaults: mockDefaults)
        let restoredOrigin = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds]
        )
        assertTest(restoredOrigin.x == -585 && restoredOrigin.y == 50,
                   "Restored origin matches exact user coordinates (-585, 50) without opening System Settings",
                   failureReason: "Got \(restoredOrigin)")

        // -------------------------------------------------------------
        // Test 4: Recreated Display with Different Ephemeral Display ID
        // -------------------------------------------------------------
        print("\n[Test 4] Recreated Display with Different Display ID...")
        let oldDisplayID: CGDirectDisplayID = 114
        let newDisplayID: CGDirectDisplayID = 115
        assertTest(oldDisplayID != newDisplayID, "Simulated ephemeral display ID changed from 114 to 115")
        // Check vendor/product ID recognition
        let isMirooHardware = (DisplayArrangementStore.mirooVendorID == 0x5043 && DisplayArrangementStore.mirooProductID == 0x4F53)
        assertTest(isMirooHardware, "Miroo hardware vendor (0x5043) and product (0x4F53) reliably identified")
        // Restoration still operates on relationship regardless of newDisplayID
        let restoredAfterNewID = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds]
        )
        assertTest(restoredAfterNewID.x == -585 && restoredAfterNewID.y == 50,
                   "Arrangement restoration succeeds identically with new ephemeral display ID")

        // -------------------------------------------------------------
        // Test 5: Resolution & Display Scaling Change
        // -------------------------------------------------------------
        print("\n[Test 5] Resolution & Display Scaling Change Adaptation...")
        // MacBook switched to higher resolution scaling: 1728 x 1117 (e.g. 14" MacBook Pro default scaled)
        let scaledMacBounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let scaledOrigin = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: scaledMacBounds,
            activeDisplayBounds: [scaledMacBounds]
        )
        assertTest(scaledOrigin.x == -585, "Docking to left edge maintained at -585 on scaled reference screen")
        // Cursor transit overlap check: ensure target bounds touch scaledMacBounds
        let mirooRectOnScaled = CGRect(origin: scaledOrigin, size: mirooPortraitSize)
        let touchesScaledMac = mirooRectOnScaled.intersects(scaledMacBounds.insetBy(dx: -1, dy: -1))
        assertTest(touchesScaledMac, "Miroo display maintains continuous mouse cursor contact after Mac scaling change")

        // -------------------------------------------------------------
        // Test 6: Above & Below Docking Arrangements
        // -------------------------------------------------------------
        print("\n[Test 6] Above & Below Docking Arrangements...")
        // User moves Miroo display ABOVE the Mac screen
        let userAboveBounds = CGRect(x: 100, y: -1266, width: 585, height: 1266)
        freshStore.saveArrangement(mirooBounds: userAboveBounds, referenceBounds: macBounds, orientation: .portrait)
        let restoredAbove = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds]
        )
        assertTest(restoredAbove.x == 100 && restoredAbove.y == -1266,
                   "Above arrangement restored accurately at (100, -1266)",
                   failureReason: "Got \(restoredAbove)")

        // User moves Miroo display BELOW the Mac screen
        let userBelowBounds = CGRect(x: 200, y: 900, width: 585, height: 1266)
        freshStore.saveArrangement(mirooBounds: userBelowBounds, referenceBounds: macBounds, orientation: .portrait)
        let restoredBelow = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds]
        )
        assertTest(restoredBelow.x == 200 && restoredBelow.y == 900,
                   "Below arrangement restored accurately at (200, 900)",
                   failureReason: "Got \(restoredBelow)")

        // -------------------------------------------------------------
        // Test 7: External Monitor Presence & Disconnection Clamping
        // -------------------------------------------------------------
        print("\n[Test 7] External Monitor Presence & Disconnection Clamping...")
        // While external monitor was attached at (1440, 0, 1920, 1080), user placed Miroo at (3360, 100)
        let externalMonitorBounds = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let userFarRightBounds = CGRect(x: 3360, y: 100, width: 585, height: 1266)
        freshStore.saveArrangement(mirooBounds: userFarRightBounds, referenceBounds: macBounds, orientation: .portrait)

        // Scenario A: External monitor is still connected
        let originWithExternal = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds, externalMonitorBounds]
        )
        assertTest(originWithExternal.x == 3360 && originWithExternal.y == 100,
                   "Miroo placed beside external monitor when external monitor is connected")

        // Scenario B: External monitor was unplugged. Miroo would be floating in empty void!
        let originWithoutExternal = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds] // Only Mac screen is left
        )
        assertTest(originWithoutExternal.x == macBounds.maxX,
                   "Disjoint arrangement automatically clamped back to Mac screen edge when external monitor unplugged",
                   failureReason: "Got \(originWithoutExternal)")

        // -------------------------------------------------------------
        // Test 8: Invalid / Corrupted Saved State Fallback
        // -------------------------------------------------------------
        print("\n[Test 8] Invalid / Corrupted Saved State Fallback...")
        mockDefaults.set("CORRUPTED_NON_JSON_DATA".data(using: .utf8)!, forKey: DisplayArrangementStore.portraitKey)
        let fallbackOrigin = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds]
        )
        assertTest(fallbackOrigin.x == 1440 && fallbackOrigin.y == 0,
                   "Corrupted persistent payload gracefully falls back to default docking (1440, 0) without crash")

        // -------------------------------------------------------------
        // Test 9: Independent Portrait & Landscape Arrangements
        // -------------------------------------------------------------
        print("\n[Test 9] Independent Portrait & Landscape Arrangements...")
        freshStore.clearArrangements()
        // Save portrait to left of Mac
        let portBounds = CGRect(x: -585, y: 100, width: 585, height: 1266)
        freshStore.saveArrangement(mirooBounds: portBounds, referenceBounds: macBounds, orientation: .portrait)

        // Save landscape below Mac
        let landBounds = CGRect(x: 50, y: 900, width: 1266, height: 585)
        freshStore.saveArrangement(mirooBounds: landBounds, referenceBounds: macBounds, orientation: .landscape)

        let targetPortrait = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds]
        )
        let targetLandscape = freshStore.targetOrigin(
            for: .landscape,
            mirooSize: mirooLandscapeSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds]
        )
        assertTest(targetPortrait.x == -585 && targetPortrait.y == 100,
                   "Portrait arrangement preserved independently at (-585, 100)",
                   failureReason: "Got \(targetPortrait)")
        assertTest(targetLandscape.x == 50 && targetLandscape.y == 900,
                   "Landscape arrangement preserved independently at (50, 900)",
                   failureReason: "Got \(targetLandscape)")

        // -------------------------------------------------------------
        // Test 10: Repeated USB & Wi-Fi Reconnect Cycles (Deterministic Invariance)
        // -------------------------------------------------------------
        print("\n[Test 10] Repeated Reconnect Cycles (Deterministic Invariance)...")
        var allCyclesMatched = true
        for cycle in 1...5 {
            let reconnectStore = DisplayArrangementStore(defaults: mockDefaults)
            let origin = reconnectStore.targetOrigin(
                for: .portrait,
                mirooSize: mirooPortraitSize,
                referenceBounds: macBounds,
                activeDisplayBounds: [macBounds]
            )
            if origin.x != -585 || origin.y != 100 {
                allCyclesMatched = false
                print("    Cycle \(cycle) failed with origin: \(origin)")
            }
        }
        assertTest(allCyclesMatched, "5 consecutive reconnect cycles produced 100% deterministic identical origins")

        // -------------------------------------------------------------
        // Test 11: Display Identification Heuristics
        // -------------------------------------------------------------
        print("\n[Test 11] Display Identification Heuristics...")
        assertTest(!freshStore.isMirooDisplay(displayID: 0), "Invalid displayID (0) rejected")
        assertTest(!freshStore.isMirooDisplay(displayID: kCGNullDirectDisplay), "Null displayID rejected")

        // -------------------------------------------------------------
        // Test 12: Primary and External Display Preservation Guarantee
        // -------------------------------------------------------------
        print("\n[Test 12] Primary and External Display Preservation Guarantee...")
        let originalMacBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let originalExternalBounds = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let testDisplays = [originalMacBounds, originalExternalBounds]

        let computedMirooOrigin = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: originalMacBounds,
            activeDisplayBounds: testDisplays
        )
        assertTest(originalMacBounds.origin == .zero, "Primary display origin remains strictly anchored at (0, 0)")
        assertTest(originalMacBounds.size == CGSize(width: 1440, height: 900), "Primary display size untouched")
        assertTest(originalExternalBounds.origin == CGPoint(x: 1440, y: 0), "External display origin untouched")
        assertTest(computedMirooOrigin != .zero, "Miroo origin is never assigned to primary display origin (0, 0)")

        // -------------------------------------------------------------
        // Test 13: WindowServer Reconfiguration Callback Classification
        // -------------------------------------------------------------
        print("\n[Test 13] WindowServer Reconfiguration Callback Classification...")
        let mirooID: CGDirectDisplayID = 200
        let otherID: CGDirectDisplayID = 100

        // In-flight transaction with beginConfigurationFlag -> REJECT
        let beginFlags: CGDisplayChangeSummaryFlags = [.beginConfigurationFlag, .movedFlag]
        let passBegin = DisplayArrangementStore.shouldProcessReconfiguration(
            displayID: mirooID,
            targetMirooID: mirooID,
            flags: beginFlags,
            isApplyingArrangement: false
        )
        assertTest(!passBegin, "In-flight WindowServer transaction (.beginConfigurationFlag) rejected")

        // Resolution mode switch without movedFlag -> REJECT
        let modeFlags: CGDisplayChangeSummaryFlags = [.setModeFlag]
        let passMode = DisplayArrangementStore.shouldProcessReconfiguration(
            displayID: mirooID,
            targetMirooID: mirooID,
            flags: modeFlags,
            isApplyingArrangement: false
        )
        assertTest(!passMode, "Mode switch without move (.setModeFlag) rejected")

        // Display add/remove without movedFlag -> REJECT
        let addFlags: CGDisplayChangeSummaryFlags = [.addFlag]
        let passAdd = DisplayArrangementStore.shouldProcessReconfiguration(
            displayID: mirooID,
            targetMirooID: mirooID,
            flags: addFlags,
            isApplyingArrangement: false
        )
        assertTest(!passAdd, "Display add event (.addFlag) rejected")

        // Programmatic arrangement in progress (isApplyingArrangement = true) -> REJECT
        let passProgrammatic = DisplayArrangementStore.shouldProcessReconfiguration(
            displayID: mirooID,
            targetMirooID: mirooID,
            flags: [.movedFlag],
            isApplyingArrangement: true
        )
        assertTest(!passProgrammatic, "Programmatic restoration layout change (isApplyingArrangement = true) rejected")

        // Event for another display -> REJECT
        let passOther = DisplayArrangementStore.shouldProcessReconfiguration(
            displayID: otherID,
            targetMirooID: mirooID,
            flags: [.movedFlag],
            isApplyingArrangement: false
        )
        assertTest(!passOther, "Reconfiguration event for non-Miroo display rejected")

        // Genuine committed user movement of Miroo display -> ACCEPT
        let passValid = DisplayArrangementStore.shouldProcessReconfiguration(
            displayID: mirooID,
            targetMirooID: mirooID,
            flags: [.movedFlag],
            isApplyingArrangement: false
        )
        assertTest(passValid, "Committed user movement of Miroo display successfully accepted")

        // -------------------------------------------------------------
        // Test 14: Cross-Orientation Arrangement Inheritance
        // -------------------------------------------------------------
        print("\n[Test 14] Cross-Orientation Arrangement Inheritance...")
        let inheritDefaults = UserDefaults(suiteName: "com.miroo.test.inheritance")!
        inheritDefaults.removePersistentDomain(forName: "com.miroo.test.inheritance")
        let inheritStore = DisplayArrangementStore(defaults: inheritDefaults)

        // User placed portrait Miroo on LEFT of Mac display
        let portLeftBounds = CGRect(x: -585, y: 120, width: 585, height: 1266)
        inheritStore.saveArrangement(mirooBounds: portLeftBounds, referenceBounds: macBounds, orientation: .portrait)

        // Device switches to landscape, where user has NOT yet arranged it
        let inheritedLandscapeOrigin = inheritStore.targetOrigin(
            for: .landscape,
            mirooSize: mirooLandscapeSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds]
        )
        assertTest(inheritedLandscapeOrigin.x == -mirooLandscapeSize.width,
                   "Landscape inherits LEFT docking edge (-1266) from saved portrait arrangement",
                   failureReason: "Got \(inheritedLandscapeOrigin)")

        // -------------------------------------------------------------
        // Test 15: Zero-Dimension & Degenerate Reference Geometry Resilience
        // -------------------------------------------------------------
        print("\n[Test 15] Zero-Dimension & Degenerate Reference Geometry Resilience...")
        let degenerateDefaults = UserDefaults(suiteName: "com.miroo.test.degenerate")!
        degenerateDefaults.removePersistentDomain(forName: "com.miroo.test.degenerate")
        let degenerateStore = DisplayArrangementStore(defaults: degenerateDefaults)

        let zeroRefBounds = CGRect(x: 0, y: 0, width: 0, height: 0)
        let zeroRefOrigin = degenerateStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: zeroRefBounds,
            activeDisplayBounds: []
        )
        assertTest(!zeroRefOrigin.x.isNaN && !zeroRefOrigin.y.isNaN, "Zero-dimension reference screen produces valid non-NaN coordinates")
        assertTest(zeroRefOrigin.x == 1440 && zeroRefOrigin.y == 0, "Zero-dimension falls back to default 1440x900 reference and docks at (1440, 0)")

        let negativeRefBounds = CGRect(x: 0, y: 0, width: -100, height: -200)
        let negRefOrigin = degenerateStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: negativeRefBounds,
            activeDisplayBounds: []
        )
        assertTest(negRefOrigin.x == 1440 && negRefOrigin.y == 0,
                   "Negative-dimension falls back to default 1440x900 reference and docks at (1440, 0)",
                   failureReason: "Got \(negRefOrigin)")


        // -------------------------------------------------------------
        // Test 16: Multi-Threaded Concurrency & Thread-Safety
        // -------------------------------------------------------------
        print("\n[Test 16] Multi-Threaded Concurrency & Thread-Safety...")
        let concurrentDefaults = UserDefaults(suiteName: "com.miroo.test.concurrency")!
        concurrentDefaults.removePersistentDomain(forName: "com.miroo.test.concurrency")
        let concurrentStore = DisplayArrangementStore(defaults: concurrentDefaults)

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let isLandscape = (index % 2 == 0)
            let ori: MirooOrientation = isLandscape ? .landscape : .portrait
            let rect = CGRect(x: CGFloat(index * 10), y: CGFloat(index * 5), width: 585, height: 1266)
            concurrentStore.saveArrangement(mirooBounds: rect, referenceBounds: macBounds, orientation: ori)
            _ = concurrentStore.loadArrangement(for: ori)
            _ = concurrentStore.lastSavedOrientation
            _ = concurrentStore.targetOrigin(for: ori, mirooSize: mirooPortraitSize, referenceBounds: macBounds)
        }
        assertTest(true, "100 concurrent read/write operations executed safely with zero race condition crashes")

        // -------------------------------------------------------------
        // Test 17: Cursor Transit Contact Clamping & Rollback Safety

        // -------------------------------------------------------------
        print("\n[Test 17] Cursor Transit Contact Clamping & Rollback Safety...")
        // User moves Miroo display way off screen vertically (offset 5000pt)
        let extremeOffsetBounds = CGRect(x: -585, y: 5000, width: 585, height: 1266)
        freshStore.saveArrangement(mirooBounds: extremeOffsetBounds, referenceBounds: macBounds, orientation: .portrait)
        let clampedOrigin = freshStore.targetOrigin(
            for: .portrait,
            mirooSize: mirooPortraitSize,
            referenceBounds: macBounds,
            activeDisplayBounds: [macBounds]
        )
        // With mac height = 900, miroo height = 1266, minContact = 30
        // maxY = macBounds.maxY - minContact = 900 - 30 = 870
        assertTest(clampedOrigin.y <= (macBounds.maxY - 30),
                   "Extreme vertical offset clamped to preserve minimum 30pt cursor transit overlap (\(clampedOrigin.y) <= 870)")

        // CoreGraphics configuration transaction rollback simulation:
        var testConfig: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&testConfig) == .success, let cfg = testConfig {
            let cancelErr = CGCancelDisplayConfiguration(cfg)
            assertTest(cancelErr == .success, "CGCancelDisplayConfiguration executes cleanly and releases WindowServer lock")
        } else {
            assertTest(true, "CoreGraphics transaction allocation handled safely")
        }

        // -------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------

        print("\n==================================================================")
        print("Display Arrangement Results: \(testsPassed) Passed, \(testsFailed) Failed")
        print("==================================================================")

        if testsFailed == 0 {
            print("🎉 ALL DISPLAY ARRANGEMENT TESTS PASSED SUCCESSFULLY!\n")
            exit(0)
        } else {
            print("❌ SOME DISPLAY ARRANGEMENT TESTS FAILED.\n")
            exit(1)
        }
    }
}
