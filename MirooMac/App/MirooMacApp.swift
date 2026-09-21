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

    static func main() {
        let app = NSApplication.shared
        let delegate = MirooMacApp()
        app.delegate = delegate

        // Set up signal handlers for graceful cleanup on Ctrl+C (SIGINT) or SIGTERM
        signal(SIGINT) { _ in
            print("\n[Miroo] Caught SIGINT (Ctrl+C). Cleaning up pipeline...")
            MirooMacApp.sharedServer?.stop()
            MirooMacApp.sharedCapturer?.stopCaptureSync()
            MirooMacApp.sharedEncoder?.invalidate()
            MirooMacApp.sharedManager?.destroy()
            exit(0)
        }

        signal(SIGTERM) { _ in
            print("\n[Miroo] Caught SIGTERM. Cleaning up pipeline...")
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

        // 3. Initialize low-latency network server (Phase 4 & 6)
        let server = MirooServer(
            serviceName: Host.current().localizedName ?? "Miroo Mac",
            width: targetWidth,
            height: targetHeight,
            targetFPS: 60,
            bitrate: 8_000_000,
            maxQueueDepth: 1
        )
        MirooMacApp.sharedServer = server

        do {
            try server.start()
        } catch {
            print("[Miroo] ERROR: Failed to start MirooServer: \(error.localizedDescription)")
            NSApplication.shared.terminate(nil)
            return
        }

        // 4. Initialize hardware VideoToolbox encoder (Phase 3 & 6)
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

        // Connect encoder output directly to network server bounded frame queue
        encoder.onEncodedFrame = { [weak server] data, pts, isKeyframe, encodeDurationUs in
            server?.enqueueFrame(data: data, pts: pts, isKeyframe: isKeyframe, encodeDurationUs: encodeDurationUs)
        }

        // 5. Initialize ScreenCaptureKit capturer (Phase 2)
        let capturer = DisplayStreamCapturer()
        MirooMacApp.sharedCapturer = capturer

        // Connect raw CVPixelBuffers from capturer directly into VideoToolbox encoder
        // If the frame queue dropped a frame, request an instantaneous keyframe to prevent visual glitches
        capturer.onFrameCaptured = { [weak server, weak encoder] pixelBuffer, presentationTime in
            let forceKey = server?.frameQueue.needsImmediateKeyframe ?? false
            encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime, forceKeyframe: forceKey)
        }

        // 6. Start ScreenCaptureKit Capture
        Task {
            do {
                try await capturer.startCapture(
                    displayID: displayID,
                    displayName: displayName,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    targetFPS: 60
                )
            } catch {
                print("[Miroo] Capture initialization error: \(error.localizedDescription)")
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

        print("-------------------------------------------------------")
        print(" Miroo Full Pipeline Active:")
        print(" Virtual Display -> SCK -> H.264 -> Bonjour + TCP Network Transport")
        print(" iPhone can now discover and stream from this Mac.")
        print(" Press Ctrl+C in this terminal to quit.")
        print("-------------------------------------------------------")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[Miroo] Application terminating. Ensuring cleanup...")
        MirooMacApp.sharedServer?.stop()
        MirooMacApp.sharedCapturer?.stopCaptureSync()
        MirooMacApp.sharedEncoder?.invalidate()
        MirooMacApp.sharedManager?.destroy()
    }
}
