import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Hands decoded frames to an `AVSampleBufferDisplayLayer` for immediate presentation (no timebase, no buffering).
public final class DisplayLayerRenderer: @unchecked Sendable {
    public let layer = AVSampleBufferDisplayLayer()
    private var failures = 0

    public init() {
        layer.videoGravity = .resize
        layer.preventsCapture = false
    }

    public func show(_ pixelBuffer: CVPixelBuffer) {
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &fd) == noErr,
              let fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: fd,
                                                       sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush(); failures += 1 }
        layer.enqueue(sb)
    }
}
