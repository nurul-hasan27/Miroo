#if os(macOS)
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import MirooCore

public struct EncodedFrame: Sendable {
    public var codec: Codec
    /// Decodable without previous frames' pictures (IDR, or P frame predicted from an acknowledged LTR).
    public var isRecovery: Bool
    public var ltrToken: Int32
    public var captureUs: UInt32
    public var encodeStartUs: UInt32
    public var encodeDoneUs: UInt32
    public var parameterSets: [[UInt8]]
    public var bitstream: [UInt8]       // AVCC (4-byte length prefixed NALUs)

    public func envelope() -> FrameEnvelope {
        FrameEnvelope(codec: codec, isRecovery: isRecovery, ltrToken: ltrToken, captureUs: captureUs,
                      encodeDoneUs: encodeDoneUs, parameterSets: isRecovery ? parameterSets : [], bitstream: bitstream)
    }
}

public enum LinkMediaError: Error { case sessionCreate(OSStatus), prepare(OSStatus), decode(OSStatus), format(OSStatus) }

/// Hardware encoder tuned for interactive latency: low-latency rate control, no B-frames, infinite GOP,
/// long-term-reference (LTR) based loss recovery instead of periodic keyframes.
public final class LinkEncoder: @unchecked Sendable {
    static var dbg: Bool { ProcessInfo.processInfo.environment["MIROO_DEBUG_ENC"] != nil }
    private let t0 = LinkClock.nowUs()
    private func ts() -> String { String(format: "%7.3f", Double(LinkClock.nowUs() &- t0) / 1e6) }
    private var dropRun = 0
    private var dbgCount = 0
    public struct Config {
        public var width: Int, height: Int, fps: Int, bitrate: Int, codec: Codec
        /// Long-term-reference recovery. Off by default: with realistic ack latency (60-90 ms over Wi-Fi) VideoToolbox's
        /// low-latency encoder starts dropping every other frame while it waits for acknowledgements. Loss is handled by
        /// repair parity first and a plain keyframe as the rare fallback.
        public var useLTR: Bool
        public init(width: Int, height: Int, fps: Int = 60, bitrate: Int = 12_000_000, codec: Codec = .hevc, useLTR: Bool = false) {
            self.width = width; self.height = height; self.fps = fps; self.bitrate = bitrate; self.codec = codec; self.useLTR = useLTR
        }
    }

    public let config: Config
    public private(set) var usesHardware = false
    public var onFrame: ((EncodedFrame) -> Void)?
    /// Called when an input frame produced no output (encoder dropped it or failed), so callers can release in-flight accounting.
    public var onDrop: (() -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var pendingAcks: [Int32] = []
    private var pendingRecovery = true            // first frame must be an IDR
    private(set) public var framesEncoded = 0
    private(set) public var framesFailed = 0

    /// The first hardware low-latency encoder session in a process takes ~0.5-1 s (driver load) – and much longer while the
    /// system is busy creating a display. A long-lived app calls this at launch so connecting later is instant.
    public static func warmUp() { _ = warmed }
    private static let warmed: Void = {
        for codec in [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264] {
            var s: VTCompressionSession?
            let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                                         kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
            guard VTCompressionSessionCreate(allocator: nil, width: 320, height: 180, codecType: codec, encoderSpecification: spec as CFDictionary,
                                             imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                             compressionSessionOut: &s) == noErr, let sess = s else { continue }
            VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTCompressionSessionPrepareToEncodeFrames(sess)
            VTCompressionSessionInvalidate(sess)
        }
    }()

    public init(config: Config) throws {
        self.config = config
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(config.width), height: Int32(config.height),
                                            codecType: config.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                            compressionSessionOut: &s)
        guard st == noErr, let sess = s else { throw LinkMediaError.sessionCreate(st) }
        func set(_ k: CFString, _ v: CFTypeRef) { _ = VTSessionSetProperty(sess, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, config.bitrate as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 1_000_000 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 0 as CFNumber)
        if config.useLTR { set(kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue) }
        let prep = VTCompressionSessionPrepareToEncodeFrames(sess)
        guard prep == noErr else { throw LinkMediaError.prepare(prep) }
        var hw: Unmanaged<CFTypeRef>?
        if VTSessionCopyProperty(sess, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                 allocator: nil, valueOut: &hw) == noErr, let v = hw?.takeRetainedValue() {
            usesHardware = (v as? Bool) ?? false
        }
        session = sess
    }

    deinit { invalidate() }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let s = session { VTCompressionSessionInvalidate(s); session = nil }
    }

    public func setBitrate(_ bps: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let s = session else { return }
        let st = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        if ProcessInfo.processInfo.environment["MIROO_DEBUG_ENC"] != nil {
            var v: Unmanaged<CFTypeRef>?
            VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, allocator: nil, valueOut: &v)
            print("[enc \(ts())] setBitrate \(bps) status=\(st) readback=\(String(describing: v?.takeRetainedValue()))")
        }
    }

    /// Receiver decoded these LTR frames; the encoder may reference them.
    public func acknowledge(tokens: [Int32]) {
        lock.lock(); pendingAcks.append(contentsOf: tokens); lock.unlock()
    }

    public var hasPendingRecovery: Bool { lock.lock(); defer { lock.unlock() }; return pendingRecovery }

    /// Next frame will be an LTR-refresh (or IDR if nothing acknowledged yet).
    public func requestRecovery() {
        lock.lock(); pendingRecovery = true; lock.unlock()
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, captureUs: UInt32) {
        lock.lock()
        guard let sess = session else { lock.unlock(); return }
        var props: [CFString: Any] = [:]
        let recovery = pendingRecovery
        pendingRecovery = false
        if config.useLTR, !pendingAcks.isEmpty {
            props[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = pendingAcks.map { NSNumber(value: $0) }
            pendingAcks.removeAll()
        }
        if recovery { props[config.useLTR ? kVTEncodeFrameOptionKey_ForceLTRRefresh : kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        if Self.dbg, recovery || props[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] != nil { print("[enc \(ts())] frame#\(framesEncoded) refresh=\(recovery) acks=\((props[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] as? [NSNumber])?.map { $0.int32Value } ?? [])") }
        let startUs = LinkClock.nowUs32()
        let pts = CMTime(value: Int64(framesEncoded), timescale: CMTimeScale(config.fps))
        framesEncoded += 1
        let codec = config.codec
        let st = VTCompressionSessionEncodeFrame(
            sess, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: CMTimeScale(config.fps)),
            frameProperties: props.isEmpty ? nil : props as CFDictionary, infoFlagsOut: nil
        ) { [weak self] status, flags, sb in
            guard let self else { return }
            guard status == noErr, let sb, !flags.contains(.frameDropped) else {
                if Self.dbg { self.dropRun += 1; if self.dropRun == 1 { print("[enc \(self.ts())] DROP begins (status=\(status) flags=\(flags.rawValue))") } }
                self.framesFailed += 1; self.onDrop?(); return }
            if Self.dbg, self.dropRun > 0 { print("[enc \(self.ts())] DROP run ended after \(self.dropRun) frames"); self.dropRun = 0 }
            self.handle(sb, codec: codec, forcedRecovery: recovery, captureUs: captureUs, startUs: startUs)
        }
        lock.unlock()
        if st != noErr { if ProcessInfo.processInfo.environment["MIROO_DEBUG_ENC"] != nil { print("[enc] encode call status=\(st)") }; framesFailed += 1; onDrop?() }
    }

    private func handle(_ sb: CMSampleBuffer, codec: Codec, forcedRecovery: Bool, captureUs: UInt32, startUs: UInt32) {
        let doneUs = LinkClock.nowUs32()
        var isSync = true
        var token: Int32 = 0
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let a = arr.first {
            isSync = !(a[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
            if let t = a[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber { token = t.int32Value }
        }
        if Self.dbg, dbgCount < 60 { dbgCount += 1; print("[enc \(ts())] out sync=\(isSync) token=\(token) size=\(CMSampleBufferGetTotalSampleSize(sb)) pts=\(Int(CMSampleBufferGetPresentationTimeStamp(sb).value))") }
        guard let block = CMSampleBufferGetDataBuffer(sb) else { onDrop?(); return }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &ptr) == kCMBlockBufferNoErr, let ptr else { onDrop?(); return }
        let bytes = [UInt8](UnsafeRawBufferPointer(start: ptr, count: length))
        var sets = [[UInt8]]()
        let recovery = isSync || forcedRecovery
        if recovery, let fd = CMSampleBufferGetFormatDescription(sb) { sets = Self.parameterSets(fd, codec: codec) }
        onFrame?(EncodedFrame(codec: codec, isRecovery: recovery, ltrToken: token, captureUs: captureUs,
                              encodeStartUs: startUs, encodeDoneUs: doneUs, parameterSets: sets, bitstream: bytes))
    }

    static func parameterSets(_ fd: CMFormatDescription, codec: Codec) -> [[UInt8]] {
        var out = [[UInt8]]()
        var count = 0
        func fetch(_ i: Int) -> [UInt8]? {
            var p: UnsafePointer<UInt8>?; var size = 0
            let st = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            guard st == noErr, let p else { return nil }
            return [UInt8](UnsafeBufferPointer(start: p, count: size))
        }
        guard let first = fetch(0) else { return [] }
        out.append(first)
        for i in 1..<max(1, count) { if let s = fetch(i) { out.append(s) } }
        return out
    }
}
#endif
