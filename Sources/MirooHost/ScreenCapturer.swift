import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import MirooCore

public enum CaptureError: Error { case permissionDenied, displayNotFound(CGDirectDisplayID), failed(String) }

/// Captures one display as NV12 at up to 60 fps. Frame callbacks carry the capture time (host clock, µs, 32-bit).
public final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public var onFrame: ((CVPixelBuffer, UInt32) -> Void)?
    public var onStop: ((Error?) -> Void)?
    public private(set) var framesDelivered = 0
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "miroo.capture", qos: .userInteractive)

    public func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int = 60) async throws {
        if !CGPreflightScreenCaptureAccess() {
            if !CGRequestScreenCaptureAccess() && !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
        }
        var display: SCDisplay?
        for _ in 0..<100 {
            if let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
               let d = c.displays.first(where: { $0.displayID == displayID }) { display = d; break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        guard let display else { throw CaptureError.displayNotFound(displayID) }
        let tCfg = LinkClock.nowUs()
        let cfg = SCStreamConfiguration()
        cfg.width = width; cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 3
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.capturesAudio = false
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        print("[capture] SCStream.startCapture took \(Int(Double(LinkClock.nowUs() &- tCfg) / 1000)) ms after the display was found")
        stream = s
    }

    /// Loads ScreenCaptureKit's machinery ahead of the first connection (no-op without permission).
    public static func warmUp() { Task.detached(priority: .utility) { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) } }

    public func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        // skip idle / blank notifications: only complete frames carry new pixels
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return }
        guard let pb = sb.imageBuffer else { return }
        // host-clock presentation time == vsync-ish capture time; same base as LinkClock (uptime raw)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let capUs = pts.isValid ? UInt64(max(0, pts.seconds) * 1_000_000) : LinkClock.nowUs()
        framesDelivered += 1
        onFrame?(pb, UInt32(truncatingIfNeeded: capUs))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}
