import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import MirooCore

public struct DecodedFrame {
    public var pixelBuffer: CVPixelBuffer
    public var envelope: FrameEnvelope
    public var decodeUs: UInt32
}

/// Hardware decoder fed with `FrameEnvelope`s. Recreates its session when parameter sets change.
public final class LinkDecoder: @unchecked Sendable {
    public var onDecoded: ((DecodedFrame) -> Void)?
    public var onError: ((OSStatus) -> Void)?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var currentSets: [[UInt8]] = []
    private let lock = NSLock()

    public init() {}
    deinit { invalidate() }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil; format = nil; currentSets = []
    }

    public var isReady: Bool { lock.lock(); defer { lock.unlock() }; return session != nil }

    public func decode(_ env: FrameEnvelope) {
        lock.lock()
        if !env.parameterSets.isEmpty, env.parameterSets != currentSets || session == nil {
            if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
            guard let fd = makeFormat(env) else { lock.unlock(); onError?(-1); return }
            format = fd
            currentSets = env.parameterSets
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var s: VTDecompressionSession?
            let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                                  imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &s)
            guard st == noErr, let s else { lock.unlock(); onError?(st); return }
            VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            session = s
        }
        guard let sess = session, let fd = format else { lock.unlock(); return }
        lock.unlock()

        var block: CMBlockBuffer?
        let len = env.bitstream.count
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len,
                                                    blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                    dataLength: len, flags: 0, blockBufferOut: &block)
        guard st == noErr, let block else { onError?(st); return }
        st = env.bitstream.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: len) }
        guard st == noErr else { onError?(st); return }
        var sample: CMSampleBuffer?
        var size = len
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        st = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: 1,
                                       sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                       sampleSizeArray: &size, sampleBufferOut: &sample)
        guard st == noErr, let sample else { onError?(st); return }
        let startUs = LinkClock.nowUs32()
        let cb = onDecoded
        st = VTDecompressionSessionDecodeFrame(sess, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
                                               infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            cb?(DecodedFrame(pixelBuffer: image, envelope: env, decodeUs: LinkClock.nowUs32() &- startUs))
        }
        if st != noErr { onError?(st) }
    }

    private func makeFormat(_ env: FrameEnvelope) -> CMVideoFormatDescription? {
        var fd: CMVideoFormatDescription?
        let sets = env.parameterSets
        let ptrs = sets.map { s -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count); p.initialize(from: s, count: s.count); return UnsafePointer(p)
        }
        defer { ptrs.forEach { $0.deallocate() } }
        let sizes = sets.map { $0.count }
        let st: OSStatus = env.codec == .hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                  parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                  parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        return st == noErr ? fd : nil
    }
}
