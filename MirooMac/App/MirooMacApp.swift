//
//  MirooMacApp.swift
//  MirooMac
//
//  Phase 1 + Phase 2 + Phase 3 Entry Point:
//  Virtual Display -> ScreenCaptureKit -> Hardware H.264 VideoEncoder
//

import Cocoa
import CoreGraphics
import CoreMedia
import VideoToolbox
#if canImport(MirooNetworking)
import MirooNetworking
#endif

@main
final class MirooMacApp: NSObject, NSApplicationDelegate {

    private static var sharedManager: VirtualDisplayManager?
    private static var sharedCapturer: DisplayStreamCapturer?
    private static var sharedEncoder: VideoEncoder?
    private static var sharedServer: MirooServer?
    private static var sharedInputController: MacInputController?

    static func main() {
        let app = NSApplication.shared
        let delegate = MirooMacApp()
        app.delegate = delegate

        // Set up signal handlers for graceful cleanup on Ctrl+C (SIGINT) or SIGTERM
        signal(SIGINT) { _ in
            print("\n[Miroo] Caught SIGINT (Ctrl+C). Cleaning up pipeline...")
            MirooMacApp.sharedInputController?.releaseAllButtons()
            MirooMacApp.sharedServer?.stop()
            MirooMacApp.sharedCapturer?.stopCaptureSync()
            MirooMacApp.sharedEncoder?.invalidate()
            MirooMacApp.sharedManager?.destroy()
            exit(0)
        }

        signal(SIGTERM) { _ in
            print("\n[Miroo] Caught SIGTERM. Cleaning up pipeline...")
            MirooMacApp.sharedInputController?.releaseAllButtons()
            MirooMacApp.sharedServer?.stop()
            MirooMacApp.sharedCapturer?.stopCaptureSync()
            MirooMacApp.sharedEncoder?.invalidate()
            MirooMacApp.sharedManager?.destroy()
            exit(0)
        }

        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=======================================================")
        print("          Miroo macOS Proof-of-Concept (Phase 4)       ")
        print("=======================================================")

        let manager = VirtualDisplayManager()
        MirooMacApp.sharedManager = manager

        // 1. Create and configure virtual display (Phase 1)
        let success = manager.create()
        guard success else {
            print("[Miroo] ERROR: Failed to create virtual display. Exiting.")
            NSApplication.shared.terminate(nil)
            return
        }

        // 2. Print verification report
        manager.printVerificationReport()

        let displayID = manager.displayID
        let displayName = VirtualDisplayManager.defaultDisplayName
        let targetWidth = Int(VirtualDisplayManager.physicalWidth)
        let targetHeight = Int(VirtualDisplayManager.physicalHeight)

        // 3. Initialize low-latency network server (Phase 4, 6 & 8A)
        let useUDP = CommandLine.arguments.contains("--udp") || ProcessInfo.processInfo.environment["MIROO_TRANSPORT"]?.lowercased() == "udp"
        let initialTransport: VideoTransportType = useUDP ? .udp : .tcp
        if useUDP {
            print("[Miroo] Starting with UDP Video Transport by default (--udp).")
        }

        let server = MirooServer(
            serviceName: Host.current().localizedName ?? "Miroo Mac",
            width: targetWidth,
            height: targetHeight,
            targetFPS: 60,
            bitrate: 8_000_000,
            maxQueueDepth: 1,
            initialTransport: initialTransport
        )
        MirooMacApp.sharedServer = server

        // 4. Initialize Mac input controller (Phase 6A: Touch -> Mac Cursor)
        let inputController = MacInputController()
        MirooMacApp.sharedInputController = inputController

        server.onTouchEvent = { [weak inputController, weak manager] payload in
            guard let inputController = inputController, let manager = manager else { return }
            inputController.handleTouchEvent(payload, displayID: manager.displayID)
        }

        server.onScrollEvent = { [weak inputController] payload in
            inputController?.scroll(deltaX: payload.deltaX, deltaY: payload.deltaY)
        }

        server.onRightClick = { [weak inputController] _ in
            inputController?.rightClick()
        }

        server.onClientDisconnected = { [weak inputController] in
            inputController?.releaseAllButtons()
        }

        // 5. Initialize hardware VideoToolbox encoder (Phase 3 & 6)
        let encoder = VideoEncoder(
            width: Int32(targetWidth),
            height: Int32(targetHeight),
            targetFPS: 60,
            averageBitrate: 8_000_000,
            keyframeInterval: 180
        )
        MirooMacApp.sharedEncoder = encoder

        do {
            try encoder.setup()
        } catch {
            print("[Miroo] ERROR: Failed to setup VideoEncoder: \(error.localizedDescription)")
            NSApplication.shared.terminate(nil)
            return
        }

        // Connect encoder output directly to network server bounded frame queue with Stage timestamps
        encoder.onEncodedFrame = { [weak server] data, pts, isKeyframe, captureNs, encStartNs, encCompNs, encodeDurationUs in
            server?.enqueueFrame(
                data: data,
                pts: pts,
                isKeyframe: isKeyframe,
                captureTimestampNs: captureNs,
                encodeStartNs: encStartNs,
                encodeCompleteNs: encCompNs,
                encodeDurationUs: encodeDurationUs
            )
        }

        // 5. Initialize ScreenCaptureKit capturer (Phase 2 & Phase 7)
        let capturer = DisplayStreamCapturer()
        MirooMacApp.sharedCapturer = capturer

        // Connect raw CVPixelBuffers from capturer directly into VideoToolbox encoder with capture timestamp
        // If the frame queue dropped a frame, request an instantaneous keyframe to prevent visual glitches
        capturer.onFrameCaptured = { [weak server, weak encoder] pixelBuffer, presentationTime, captureTimestampNs in
            let forceKey = server?.frameQueue.needsImmediateKeyframe ?? false
            encoder?.encode(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                captureTimestampNs: captureTimestampNs,
                forceKeyframe: forceKey
            )
        }

        // Handle dynamic orientation change requested by client iPhone
        server.onOrientationChangeRequested = { [weak server, weak manager, weak capturer, weak encoder] newOrientation in
            Task { @MainActor in
                guard let manager = manager, let capturer = capturer, let encoder = encoder, let server = server else { return }
                await MirooMacApp.performOrientationSwitch(to: newOrientation, manager: manager, capturer: capturer, encoder: encoder, server: server)
            }
        }

        // Handle keyframe requests from client or jitter buffer
        server.onRequestKeyframe = { [weak encoder] in
            encoder?.requestKeyframe()
        }

        // 6. Start ScreenCaptureKit Capture, then start MirooServer
        Task {
            do {
                try await capturer.startCapture(
                    displayID: displayID,
                    displayName: displayName,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    targetFPS: 60
                )
                
                // Start server after capture stream is confirmed active
                try server.start()
            } catch {
                print("[Miroo] Initialization error: \(error.localizedDescription)")
                if let capturerErr = error as? CapturerError, case .permissionDenied = capturerErr {
                    print("----------------------------------------------------------------------")
                    print(" ACTION REQUIRED: Screen Recording Permission Needed")
                    print(" 1. Open System Settings -> Privacy & Security -> Screen Recording")
                    print(" 2. Enable permission for 'Terminal' (or 'MirooMac')")
                    print(" 3. Re-run MirooMac")
                    print("----------------------------------------------------------------------")
                }
            }
        }

        // Background stdin listener for interactive terminal control
        // 'p' = portrait, 'l' = landscape, 'r' = toggle, 'u' = UDP, 't' = TCP, 'k' = keyframe, 'b' = benchmark report
        DispatchQueue.global(qos: .userInitiated).async { [weak server, weak manager, weak capturer, weak encoder] in
            let stdinHandle = FileHandle.standardInput
            while true {
                let data = stdinHandle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                    break
                }
                Task { @MainActor in
                    guard let manager = manager, let capturer = capturer, let encoder = encoder, let server = server else { return }
                    if line == "p" || line == "portrait" {
                        await MirooMacApp.performOrientationSwitch(to: .portrait, manager: manager, capturer: capturer, encoder: encoder, server: server)
                    } else if line == "l" || line == "landscape" {
                        await MirooMacApp.performOrientationSwitch(to: .landscape, manager: manager, capturer: capturer, encoder: encoder, server: server)
                    } else if line == "r" || line == "rotate" {
                        let next: MirooOrientation = (manager.currentOrientation == .portrait) ? .landscape : .portrait
                        await MirooMacApp.performOrientationSwitch(to: next, manager: manager, capturer: capturer, encoder: encoder, server: server)
                    } else if line == "u" || line == "udp" {
                        server.setVideoTransportType(.udp)
                        print("[Miroo] Switched active video transport to UDP.")
                    } else if line == "t" || line == "tcp" {
                        server.setVideoTransportType(.tcp)
                        print("[Miroo] Switched active video transport to TCP.")
                    } else if line == "k" || line == "key" {
                        encoder.requestKeyframe()
                        print("[Miroo] Forced IDR Keyframe on next capture.")
                    } else if line == "stat" || line == "stats" {
                        let m = server.activeVideoTransport?.getMetrics() ?? VideoTransportMetrics()
                        print("=== Transport Metrics (\(server.currentTransportType)) ===")
                        print("Frames Sent: \(m.framesSent), Packets Sent: \(m.packetsSent), Bytes: \(m.bytesSent)")
                        print("===============================================")
                    } else if line == "b" || line == "benchmark" {
                        let report = PipelineBenchmark.shared.generateReport()
                        print("\n" + report.formattedSummary() + "\n")
                        try? PipelineBenchmark.shared.exportJSON(toPath: "pipeline_benchmark_report.json")
                        print("[Miroo] Benchmark JSON saved to pipeline_benchmark_report.json")
                    } else if line == "reset" {
                        PipelineBenchmark.shared.reset()
                        print("[Miroo] Pipeline benchmark statistics reset to zero.")
                    }
                }
            }
        }

        print("-------------------------------------------------------")
        print(" Miroo Full Pipeline Active (Phase 8A Transport Abstraction):")
        print(" Virtual Display -> SCK -> H.264 -> TCP Baseline / UDP Video Transport")
        print(" iPhone can now discover and stream from this Mac.")
        print(" Controls: 'p'/'l'/'r' (orientation), 'u' (UDP), 't' (TCP), 'k' (keyframe), 'stat' (stats), 'b' (benchmark)")
        print(" Press Ctrl+C in this terminal to quit.")
        print("-------------------------------------------------------")
    }

    private static var isSwitchingOrientation = false

    @MainActor
    static func performOrientationSwitch(
        to newOrientation: MirooOrientation,
        manager: VirtualDisplayManager,
        capturer: DisplayStreamCapturer,
        encoder: VideoEncoder,
        server: MirooServer
    ) async {
        guard !isSwitchingOrientation else {
            print("[Miroo] Orientation switch already in progress, skipping duplicate request.")
            return
        }
        guard manager.currentOrientation != newOrientation else {
            return
        }
        isSwitchingOrientation = true
        defer { isSwitchingOrientation = false }

        print("\n[Miroo] >>> Orientation switch requested: \(newOrientation.rawValue) <<<")

        // Safety: Release all held mouse buttons during orientation reconfiguration
        MirooMacApp.sharedInputController?.releaseAllButtons()

        // 1. Reconfigure virtual display mode
        let success = manager.setOrientation(newOrientation)
        guard success else {
            print("[Miroo] ERROR: Failed to switch virtual display to \(newOrientation)")
            return
        }

        let newPhysicalWidth = (newOrientation == .landscape) ? Int(VirtualDisplayManager.physicalHeight) : Int(VirtualDisplayManager.physicalWidth)
        let newPhysicalHeight = (newOrientation == .landscape) ? Int(VirtualDisplayManager.physicalWidth) : Int(VirtualDisplayManager.physicalHeight)

        // 2. Update ScreenCaptureKit stream resolution
        do {
            try await capturer.updateResolution(targetWidth: newPhysicalWidth, targetHeight: newPhysicalHeight)
        } catch {
            print("[Miroo] WARNING: SCK updateResolution error: \(error.localizedDescription). Re-attaching stream...")
            await capturer.stopCapture()
            try? await capturer.startCapture(
                displayID: manager.displayID,
                displayName: VirtualDisplayManager.defaultDisplayName,
                targetWidth: newPhysicalWidth,
                targetHeight: newPhysicalHeight,
                targetFPS: 60
            )
        }

        // 3. Reconfigure VideoToolbox encoder (flushes old frames, resets session for new resolution)
        do {
            try encoder.reconfigure(width: Int32(newPhysicalWidth), height: Int32(newPhysicalHeight))
        } catch {
            print("[Miroo] ERROR: Failed to reconfigure encoder: \(error.localizedDescription)")
        }

        // 4. Send updated STREAM_CONFIG before resuming video frames
        server.sendStreamConfig(width: newPhysicalWidth, height: newPhysicalHeight, orientation: newOrientation)

        // 5. Force immediate IDR keyframe with the new SPS/PPS
        server.frameQueue.requestImmediateKeyframe()
        print("[Miroo] Orientation switch to \(newOrientation.rawValue) (\(newPhysicalWidth)x\(newPhysicalHeight)) successfully completed.\n")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[Miroo] Application terminating. Ensuring cleanup...")
        MirooMacApp.sharedInputController?.releaseAllButtons()
        MirooMacApp.sharedServer?.stop()
        MirooMacApp.sharedCapturer?.stopCaptureSync()
        MirooMacApp.sharedEncoder?.invalidate()
        MirooMacApp.sharedManager?.destroy()
    }
}
