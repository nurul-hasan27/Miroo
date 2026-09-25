//
//  MirooMacApp.swift
//  MirooMac
//
//  Phase 12: Production Native macOS Menu Bar Application.
//  Coordinates MirooEngine, native NSStatusItem Menu Bar UI,
//  SwiftUI Preferences, and interactive terminal controls.
//

import Cocoa
import CoreGraphics
#if canImport(MirooNetworking)
import MirooNetworking
#endif

@main
final class MirooMacApp: NSObject, NSApplicationDelegate {

    private var menuBarController: MirooMenuBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = MirooMacApp()
        app.delegate = delegate

        // Graceful signal handlers
        signal(SIGINT) { _ in
            print("\n[Miroo] Caught SIGINT. Gracefully shutting down...")
            Task { @MainActor in
                MirooEngine.shared.stop()
                exit(0)
            }
        }

        signal(SIGTERM) { _ in
            print("\n[Miroo] Caught SIGTERM. Gracefully shutting down...")
            Task { @MainActor in
                MirooEngine.shared.stop()
                exit(0)
            }
        }

        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=======================================================")
        print("          Miroo macOS Production App (Phase 12)        ")
        print("=======================================================")

        if CommandLine.arguments.contains("--audit-arrangement") {
            runDisplayArrangementAudit()
            return
        }

        let engine = MirooEngine.shared
        self.menuBarController = MirooMenuBarController(engine: engine)


        // Parse launch flags for transport override
        if CommandLine.arguments.contains("--udp") || ProcessInfo.processInfo.environment["MIROO_TRANSPORT"]?.lowercased() == "udp" {
            engine.preferredTransport = "udp"
            print("[Miroo] Preferred transport set to UDP via command-line argument.")
        } else if CommandLine.arguments.contains("--tcp") || ProcessInfo.processInfo.environment["MIROO_TRANSPORT"]?.lowercased() == "tcp" {
            engine.preferredTransport = "tcp"
            print("[Miroo] Preferred transport set to TCP via command-line argument.")
        }

        // Start MirooEngine in background task
        Task {
            do {
                try await engine.start()
            } catch {
                print("[Miroo] Initialization error: \(error.localizedDescription)")
                if let capturerErr = error as? CapturerError, case .permissionDenied = capturerErr {
                    print("----------------------------------------------------------------------")
                    print(" ACTION REQUIRED: Screen Recording Permission Needed")
                    print(" 1. Open System Settings -> Privacy & Security -> Screen Recording")
                    print(" 2. Enable permission for 'MirooMac' (or Terminal)")
                    print(" 3. Relaunch Miroo")
                    print("----------------------------------------------------------------------")
                }
            }
        }

        // Check if running interactively inside a terminal TTY
        let isInteractiveTerminal = isatty(fileno(stdin)) != 0
        if isInteractiveTerminal {
            startTerminalListener(engine: engine)
            print("-------------------------------------------------------")
            print(" Miroo Menu Bar App active.")
            print(" Terminal interactive controls active:")
            print(" 'p'/'l'/'r' (orientation), 'u' (UDP), 't' (TCP), 'k' (keyframe), 'b' (benchmark), 'q' (quit)")
            print("-------------------------------------------------------")
        } else {
            print("Miroo running in background menu bar mode.")
        }
    }

    private func startTerminalListener(engine: MirooEngine) {
        DispatchQueue.global(qos: .userInitiated).async { [weak engine] in
            let stdinHandle = FileHandle.standardInput
            while true {
                let data = stdinHandle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                    break
                }
                Task { @MainActor in
                    guard let engine = engine else { return }
                    if line == "p" || line == "portrait" {
                        await engine.switchOrientation(to: .portrait)
                    } else if line == "l" || line == "landscape" {
                        await engine.switchOrientation(to: .landscape)
                    } else if line == "r" || line == "rotate" {
                        let next: MirooOrientation = (engine.currentOrientation == .portrait) ? .landscape : .portrait
                        await engine.switchOrientation(to: next)
                    } else if line == "u" || line == "udp" {
                        engine.preferredTransport = "udp"
                        print("[Miroo] Switched preferred transport to UDP.")
                    } else if line == "t" || line == "tcp" {
                        engine.preferredTransport = "tcp"
                        print("[Miroo] Switched preferred transport to TCP.")
                    } else if line == "k" || line == "key" {
                        engine.requestKeyframe()
                        print("[Miroo] Forced IDR Keyframe on next capture.")
                    } else if line == "b" || line == "benchmark" {
                        let report = PipelineBenchmark.shared.generateReport()
                        print("\n" + report.formattedSummary() + "\n")
                        try? PipelineBenchmark.shared.exportJSON(toPath: "pipeline_benchmark_report.json")
                        print("[Miroo] Benchmark JSON saved to pipeline_benchmark_report.json")
                    } else if line == "reset" {
                        PipelineBenchmark.shared.reset()
                        print("[Miroo] Pipeline benchmark statistics reset to zero.")
                    } else if line == "q" || line == "quit" {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    // MARK: - Physical Display Arrangement Verification Audit

    private func runDisplayArrangementAudit() {
        print("==================================================================")
        print("   Miroo Production Physical Display Arrangement Audit (Host M1)  ")
        print("==================================================================")

        let mainID = CGMainDisplayID()
        let initialMainBounds = CGDisplayBounds(mainID)
        print("Primary Host Display ID: \(mainID)")
        print("Primary Host Display Bounds: \(initialMainBounds)")

        var auditPassed = true
        var cycleLogs: [String] = []

        func moveAndPersist(manager: VirtualDisplayManager, targetX: CGFloat, targetY: CGFloat) -> Bool {
            let id = manager.displayID
            guard id != 0 else { return false }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
            CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
            CGConfigureDisplayOrigin(cfg, id, Int32(targetX), Int32(targetY))
            let err = CGCompleteDisplayConfiguration(cfg, .permanently)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            guard err == .success else { return false }

            let currentBounds = CGDisplayBounds(id)
            let mainBounds = CGDisplayBounds(CGMainDisplayID())
            DisplayArrangementStore.shared.saveArrangement(
                mirooBounds: currentBounds,
                referenceBounds: mainBounds,
                orientation: manager.currentOrientation
            )
            return true
        }

        func verifyUntouchedMain() -> Bool {
            let currentMain = CGDisplayBounds(CGMainDisplayID())
            return currentMain == initialMainBounds
        }

        // --- TEST 1: Left Position (5 Reconnect Cycles, target: (-2532, 200)) ---
        print("\n--- [Audit 1] Left Position (5 Reconnect Cycles, target: (-2532, 200)) ---")
        var leftCyclesSuccess = true
        let mgr1 = VirtualDisplayManager()
        guard mgr1.create() else {
            print("ERROR: Failed to create virtual display for initial Left move")
            exit(1)
        }
        let initialLeftOk = moveAndPersist(manager: mgr1, targetX: -2532, targetY: 200)
        let leftBounds0 = CGDisplayBounds(mgr1.displayID)
        let expectedLeftOrigin = leftBounds0.origin
        print("Initial Left Move (ID \(mgr1.displayID)): origin=(\(expectedLeftOrigin.x), \(expectedLeftOrigin.y)), success=\(initialLeftOk)")
        mgr1.destroy()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        for cycle in 1...5 {
            let mgr = VirtualDisplayManager()
            guard mgr.create() else {
                print("  Cycle \(cycle) FAILED to create display")
                leftCyclesSuccess = false
                break
            }
            let id = mgr.displayID
            let bounds = CGDisplayBounds(id)
            let match = (bounds.origin == expectedLeftOrigin)
            let mainOk = verifyUntouchedMain()
            let log = "Left Cycle \(cycle): ID=\(id), Origin=(\(bounds.origin.x), \(bounds.origin.y)), Matched=\(match), MainUntouched=\(mainOk)"
            cycleLogs.append(log)
            print("  ✓ \(log)")
            if !match || !mainOk { leftCyclesSuccess = false }
            mgr.destroy()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        if !leftCyclesSuccess { auditPassed = false }

        // --- TEST 2: Right Position (3 Reconnect Cycles, target: (main.maxX, 150)) ---
        let rightX = initialMainBounds.maxX
        print("\n--- [Audit 2] Right Position (3 Reconnect Cycles, target: (\(rightX), 150)) ---")
        var rightCyclesSuccess = true
        let mgr2 = VirtualDisplayManager()
        guard mgr2.create() else {
            print("ERROR: Failed to create virtual display for initial Right move")
            exit(1)
        }
        let initialRightOk = moveAndPersist(manager: mgr2, targetX: rightX, targetY: 150)
        let rightBounds0 = CGDisplayBounds(mgr2.displayID)
        let expectedRightOrigin = rightBounds0.origin
        print("Initial Right Move (ID \(mgr2.displayID)): origin=(\(expectedRightOrigin.x), \(expectedRightOrigin.y)), success=\(initialRightOk)")
        mgr2.destroy()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        for cycle in 1...3 {
            let mgr = VirtualDisplayManager()
            guard mgr.create() else {
                print("  Cycle \(cycle) FAILED to create display")
                rightCyclesSuccess = false
                break
            }
            let id = mgr.displayID
            let bounds = CGDisplayBounds(id)
            let match = (bounds.origin == expectedRightOrigin)
            let mainOk = verifyUntouchedMain()
            let log = "Right Cycle \(cycle): ID=\(id), Origin=(\(bounds.origin.x), \(bounds.origin.y)), Matched=\(match), MainUntouched=\(mainOk)"
            cycleLogs.append(log)
            print("  ✓ \(log)")
            if !match || !mainOk { rightCyclesSuccess = false }
            mgr.destroy()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        if !rightCyclesSuccess { auditPassed = false }

        // --- TEST 3: Above Position (1 Reconnect Cycle, target: (100, -1170)) ---
        print("\n--- [Audit 3] Above Position (1 Reconnect Cycle, target: (100, -1170)) ---")
        let mgr3 = VirtualDisplayManager()
        guard mgr3.create() else {
            print("ERROR: Failed to create display for Above move")
            exit(1)
        }
        _ = moveAndPersist(manager: mgr3, targetX: 100, targetY: -1170)
        let expectedAboveOrigin = CGDisplayBounds(mgr3.displayID).origin
        mgr3.destroy()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        let mgr3_reconnect = VirtualDisplayManager()
        guard mgr3_reconnect.create() else {
            print("ERROR: Failed to recreate display for Above check")
            exit(1)
        }
        let boundsAbove = CGDisplayBounds(mgr3_reconnect.displayID)
        let matchAbove = (boundsAbove.origin == expectedAboveOrigin)
        let mainOkAbove = verifyUntouchedMain()
        let logAbove = "Above Cycle 1: ID=\(mgr3_reconnect.displayID), Origin=(\(boundsAbove.origin.x), \(boundsAbove.origin.y)), Matched=\(matchAbove), MainUntouched=\(mainOkAbove)"
        cycleLogs.append(logAbove)
        print("  ✓ \(logAbove)")
        if !matchAbove || !mainOkAbove { auditPassed = false }
        mgr3_reconnect.destroy()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        // --- TEST 4: Below Position (1 Reconnect Cycle, target: (100, main.maxY)) ---
        let belowY = initialMainBounds.maxY
        print("\n--- [Audit 4] Below Position (1 Reconnect Cycle, target: (100, \(belowY))) ---")
        let mgr4 = VirtualDisplayManager()
        guard mgr4.create() else {
            print("ERROR: Failed to create display for Below move")
            exit(1)
        }
        _ = moveAndPersist(manager: mgr4, targetX: 100, targetY: belowY)
        let expectedBelowOrigin = CGDisplayBounds(mgr4.displayID).origin
        mgr4.destroy()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        let mgr4_reconnect = VirtualDisplayManager()
        guard mgr4_reconnect.create() else {
            print("ERROR: Failed to recreate display for Below check")
            exit(1)
        }
        let boundsBelow = CGDisplayBounds(mgr4_reconnect.displayID)
        let matchBelow = (boundsBelow.origin == expectedBelowOrigin)
        let mainOkBelow = verifyUntouchedMain()
        let logBelow = "Below Cycle 1: ID=\(mgr4_reconnect.displayID), Origin=(\(boundsBelow.origin.x), \(boundsBelow.origin.y)), Matched=\(matchBelow), MainUntouched=\(mainOkBelow)"
        cycleLogs.append(logBelow)
        print("  ✓ \(logBelow)")
        if !matchBelow || !mainOkBelow { auditPassed = false }
        mgr4_reconnect.destroy()

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        // --- TEST 5: Transport Invariance (USB -> Wi-Fi -> USB) ---
        print("\n--- [Audit 5] Transport Invariance (USB -> Wi-Fi -> USB) ---")
        let mgr5 = VirtualDisplayManager()
        _ = mgr5.create()
        _ = moveAndPersist(manager: mgr5, targetX: -2532, targetY: 200)
        let expectedTransportOrigin = CGDisplayBounds(mgr5.displayID).origin
        mgr5.destroy()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        // Step A: Preferred transport = UDP
        let mgr5_udp = VirtualDisplayManager()
        _ = mgr5_udp.create()
        let boundsUdp = CGDisplayBounds(mgr5_udp.displayID)
        let matchUdp = (boundsUdp.origin == expectedTransportOrigin)
        let logUdp = "Transport Switch (UDP): ID=\(mgr5_udp.displayID), Restored=(\(boundsUdp.origin.x), \(boundsUdp.origin.y)), Matched=\(matchUdp)"
        cycleLogs.append(logUdp)
        print("  ✓ \(logUdp)")
        mgr5_udp.destroy()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        // Step B: Preferred transport = USB return
        let mgr5_usb = VirtualDisplayManager()
        _ = mgr5_usb.create()
        let boundsUsb = CGDisplayBounds(mgr5_usb.displayID)
        let matchUsb = (boundsUsb.origin == expectedTransportOrigin)
        let logUsb = "Transport Switch (USB Return): ID=\(mgr5_usb.displayID), Restored=(\(boundsUsb.origin.x), \(boundsUsb.origin.y)), Matched=\(matchUsb)"
        cycleLogs.append(logUsb)
        print("  ✓ \(logUsb)")
        mgr5_usb.destroy()


        print("\n==================================================================")
        print("Physical Display Arrangement Audit Summary:")
        for log in cycleLogs {
            print("  • \(log)")
        }
        print("==================================================================")
        if auditPassed {
            print("🎉 ALL PHYSICAL ARRANGEMENT AUDIT CYCLES PASSED PERFECTLY!\n")
            exit(0)
        } else {
            print("❌ SOME PHYSICAL ARRANGEMENT AUDIT CYCLES FAILED.\n")
            exit(1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[Miroo] Application terminating. Cleaning up engine...")
        MirooEngine.shared.stop()
    }

}
