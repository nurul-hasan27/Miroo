//
//  DisplayStreamCapturer.swift
//  MirooMac
//
//  Phase 2: ScreenCaptureKit Capturer for Miroo Virtual Display
//

import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import QuartzCore

public enum CapturerError: LocalizedError {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)
    case streamAlreadyRunning
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission was not granted. Please allow Terminal or Miroo in System Settings -> Privacy & Security -> Screen Recording."
        case .displayNotFound(let id):
            return "Target virtual display with ID \(id) was not found in ScreenCaptureKit shareable content."
        case .streamAlreadyRunning:
            return "ScreenCaptureKit stream is already running."
        case .captureFailed(let reason):
            return "ScreenCaptureKit capture failed: \(reason)"
        }
    }
}

/// Captures video frames exclusively from the Miroo virtual display using Apple's public ScreenCaptureKit API.
public final class DisplayStreamCapturer: NSObject, SCStreamOutput, SCStreamDelegate {

    // MARK: - Properties

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.miroo.capture.queue", qos: .userInteractive)

    private var targetDisplayID: CGDirectDisplayID = 0
    private var targetDisplayName: String = ""

    // Frame statistics
    private var frameCount: UInt64 = 0
    private var lastFpsTimestamp: CFTimeInterval = 0
    private var isCapturing = false

    /// Optional callback invoked on each captured frame (for Phase 3 encoding).
    public var onFrameCaptured: ((CVPixelBuffer, CMTime) -> Void)?

    // MARK: - Initialization

    public override init() {
        super.init()
    }

    deinit {
        stopCaptureSync()
    }

    // MARK: - Public Control

    /// Starts capturing the specified display using ScreenCaptureKit.
    public func startCapture(
        displayID: CGDirectDisplayID,
        displayName: String,
        targetWidth: Int = 1170,
        targetHeight: Int = 2532,
        targetFPS: Int = 60
    ) async throws {
        guard !isCapturing else {
            throw CapturerError.streamAlreadyRunning
        }

        self.targetDisplayID = displayID
        self.targetDisplayName = displayName

        // 1. Verify Screen Recording permission
        if !CGPreflightScreenCaptureAccess() {
            print("[Miroo] Requesting Screen Recording access from macOS...")
            let granted = CGRequestScreenCaptureAccess()
            if !granted && !CGPreflightScreenCaptureAccess() {
                throw CapturerError.permissionDenied
            }
        }

        print("[Miroo] Starting ScreenCaptureKit...")
        print("[Miroo] Target display: \(displayName)")
        print("[Miroo] Display ID: \(displayID)")
        print("[Miroo] Capture resolution: \(targetWidth)x\(targetHeight)")

        // 2. Discover displays via ScreenCaptureKit (with retry for asynchronous WindowServer registration)
        var targetSCDisplay: SCDisplay?
        var lastDiscoveredDisplays: [SCDisplay] = []

        for attempt in 1...15 {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                lastDiscoveredDisplays = content.displays
                if let found = content.displays.first(where: { $0.displayID == displayID }) {
                    targetSCDisplay = found
                    break
                }
            } catch {
                if attempt == 15 {
                    throw CapturerError.captureFailed("Failed to fetch shareable content: \(error.localizedDescription)")
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        guard let targetSCDisplay = targetSCDisplay else {
            print("[Miroo] ERROR: Target display ID \(displayID) not found in ScreenCaptureKit after 15 attempts.")
            print("[Miroo] Discovered SC displays count: \(lastDiscoveredDisplays.count)")
            for d in lastDiscoveredDisplays {
                print("  - Display ID: \(d.displayID), bounds: (\(d.width)x\(d.height))")
            }
            throw CapturerError.displayNotFound(displayID)
        }

        // 3. Create content filter targeting ONLY the Miroo virtual display
        let filter = SCContentFilter(display: targetSCDisplay, excludingWindows: [])

        // 4. Configure stream properties for low-latency 60 FPS BGRA capture
        let config = SCStreamConfiguration()
        config.width = targetWidth
        config.height = targetHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = false
        config.showsCursor = true
        config.queueDepth = 2 // Minimal buffering for real-time responsiveness

        // 5. Create and start the stream
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
        } catch {
            throw CapturerError.captureFailed("Failed to start SCStream: \(error.localizedDescription)")
        }

        self.stream = stream
        self.isCapturing = true
        self.frameCount = 0
        self.lastFpsTimestamp = CACurrentMediaTime()
        print("[Miroo] ScreenCaptureKit stream active and awaiting frames...")
    }

    /// Stops the ScreenCaptureKit stream asynchronously.
    public func stopCapture() async {
        guard isCapturing, let activeStream = stream else { return }
        print("[Miroo] Stopping ScreenCaptureKit stream...")
        do {
            try await activeStream.stopCapture()
        } catch {
            print("[Miroo] Warning: SCStream stop error: \(error.localizedDescription)")
        }
        self.stream = nil
        self.isCapturing = false
    }

    /// Synchronous stop for teardown.
    public func stopCaptureSync() {
        guard isCapturing, let activeStream = stream else { return }
        let semaphore = DispatchSemaphore(value: 0)
        activeStream.stopCapture { _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.0)
        self.stream = nil
        self.isCapturing = false
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Validate buffer properties
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let formatType = CVPixelBufferGetPixelFormatType(pixelBuffer)

        frameCount += 1

        // Calculate and print FPS every 60 frames
        if frameCount % 60 == 0 {
            let now = CACurrentMediaTime()
            let elapsed = now - lastFpsTimestamp
            let fps = (elapsed > 0) ? (60.0 / elapsed) : 60.0
            lastFpsTimestamp = now

            let formatName = pixelFormatName(for: formatType)

            print("")
            print("[Miroo] Frame #\(frameCount)")
            print("[Miroo] FPS: ~\(Int(round(fps)))")
            print("[Miroo] Pixel format: \(formatName)")
            print("[Miroo] Frame size: \(width)x\(height)")
        }

        // Pass to subscriber (e.g. Phase 3 encoder)
        onFrameCaptured?(pixelBuffer, presentationTime)
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[Miroo] SCStream encountered error: \(error.localizedDescription)")
        self.isCapturing = false
    }

    // MARK: - Format Name Helper

    private func pixelFormatName(for format: OSType) -> String {
        switch format {
        case kCVPixelFormatType_32BGRA:
            return "BGRA"
        case kCVPixelFormatType_32ARGB:
            return "ARGB"
        case kCVPixelFormatType_32RGBA:
            return "RGBA"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "NV12"
        default:
            let bytes = [
                UInt8((format >> 24) & 0xff),
                UInt8((format >> 16) & 0xff),
                UInt8((format >> 8) & 0xff),
                UInt8(format & 0xff)
            ]
            return String(bytes: bytes, encoding: .ascii) ?? "Unknown (0x\(String(format: "%08X", format)))"
        }
    }
}
