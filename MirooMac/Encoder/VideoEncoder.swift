//
//  VideoEncoder.swift
//  MirooMac
//
//  Phase 3: Low-latency hardware H.264 video encoder using VideoToolbox.
//

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore
import os.lock
#if canImport(MirooNetworking)
import MirooNetworking
#endif

public enum VideoEncoderError: LocalizedError {
    case sessionCreationFailed(OSStatus)
    case propertySetFailed(String, OSStatus)
    case prepareFailed(OSStatus)
    case encodingFailed(OSStatus)
    case sessionNotInitialized

    public var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "Failed to create VTCompressionSession (OSStatus: \(status))."
        case .propertySetFailed(let prop, let status):
            return "Failed to set property '\(prop)' on VTCompressionSession (OSStatus: \(status))."
        case .prepareFailed(let status):
            return "Failed to prepare VTCompressionSession (OSStatus: \(status))."
        case .encodingFailed(let status):
            return "VTCompressionSessionEncodeFrame failed (OSStatus: \(status))."
        case .sessionNotInitialized:
            return "VTCompressionSession is not initialized."
        }
    }
}

/// Hardware-accelerated real-time H.264 encoder targeting low-latency Wi-Fi / wired streaming.
public final class VideoEncoder {

    // MARK: - Configuration
    public private(set) var width: Int32
    public private(set) var height: Int32
    public let targetFPS: Int32
    public let averageBitrate: Int32
    public let keyframeInterval: Int32

    private var sessionLock = os_unfair_lock_s()

    /// Dynamically reconfigures the encoder for new frame dimensions (orientation change).
    /// Flushes and tears down the old compression session, resets session state, and creates a new one.
    public func reconfigure(width: Int32, height: Int32) throws {
        os_unfair_lock_lock(&sessionLock)
        defer { os_unfair_lock_unlock(&sessionLock) }
        guard self.width != width || self.height != height else { return }
        print("[Miroo] Reconfiguring VideoEncoder: \(self.width)x\(self.height) -> \(width)x\(height)...")
        invalidateLocked()
        self.width = width
        self.height = height
        try setupLocked()
        print("[Miroo] VideoEncoder reconfigured for \(width)x\(height).")
    }

    // MARK: - Properties

    private var session: VTCompressionSession?
    private(set) var isHardwareAccelerated: Bool = false

    /// Callback delivering each Annex-B encoded H.264 frame:
    /// (data, presentationTimeStamp, isKeyframe, captureTimestampNs, encodeStartNs, encodeCompleteNs, encodeDurationUs)
    public var onEncodedFrame: ((Data, CMTime, Bool, UInt64, UInt64, UInt64, UInt32) -> Void)?

    // Statistics
    private(set) var totalFramesEncoded: UInt64 = 0
    private(set) var totalKeyframes: UInt64 = 0
    private(set) var totalFailures: UInt64 = 0
    private(set) var totalBytesEncoded: UInt64 = 0
    private(set) var averageLatencyMs: Double = 0.0

    private var intervalFrames: UInt64 = 0
    private var intervalBytes: UInt64 = 0
    private var intervalLatencySum: Double = 0.0
    private var lastIntervalTime: CFTimeInterval = 0

    // Optional file sink for local verification
    private var debugFileHandle: FileHandle?
    private var debugFrameLimit: Int = 0
    private var debugFramesWritten: Int = 0

    // MARK: - Initialization

    public init(
        width: Int32 = 1170,
        height: Int32 = 2532,
        targetFPS: Int32 = 60,
        averageBitrate: Int32 = 8_000_000,
        keyframeInterval: Int32 = 180
    ) {
        self.width = width
        self.height = height
        self.targetFPS = targetFPS
        self.averageBitrate = averageBitrate
        self.keyframeInterval = keyframeInterval
    }

    deinit {
        invalidate()
    }

    // MARK: - Session Setup

    /// Initializes and prepares the VTCompressionSession.
    public func setup() throws {
        os_unfair_lock_lock(&sessionLock)
        defer { os_unfair_lock_unlock(&sessionLock) }
        try setupLocked()
    }

    private func setupLocked() throws {
        guard session == nil else { return }

        // 1. Output callback for compressed sample buffers
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer in
            guard let refCon = outputCallbackRefCon else { return }
            let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
            encoder.handleCompressionOutput(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer, sourceFrameRefCon: sourceFrameRefCon)
        }

        // 2. Encoder specifications: require Apple Silicon hardware encoder
        let encoderSpecs: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        var newSession: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecs as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )

        guard createStatus == noErr, let session = newSession else {
            throw VideoEncoderError.sessionCreationFailed(createStatus)
        }

        // 3. Configure ultra-low-latency properties

        // Real-time encoding pipeline
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Zero frame delay: emit frames immediately without internal buffering
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        // Prioritize encoding speed over compression quality for interactive responsiveness
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)

        // Disable frame reordering (zero B-frames, zero reordering latency)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // H.264 High Profile
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)

        // Expected framerate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFPS as CFNumber)

        // Target bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: averageBitrate as CFNumber)

        // Hard bitrate limit: allow burst up to 1.5x average over 1 second window
        let byteLimit = Double(averageBitrate) / 8.0 * 1.5
        let dataRateLimits: [Double] = [byteLimit, 1.0]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)

        // Keyframe interval (e.g. 180 frames = 3 seconds at 60 FPS)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: (Double(keyframeInterval) / Double(targetFPS)) as CFNumber)

        // High profile entropy mode: CABAC
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)

        // 4. Verify hardware acceleration
        var isHWRef: Unmanaged<CFBoolean>?
        let hwStatus = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: kCFAllocatorDefault, valueOut: &isHWRef)
        if hwStatus == noErr, let boolVal = isHWRef?.takeRetainedValue() {
            self.isHardwareAccelerated = CFBooleanGetValue(boolVal)
        } else {
            self.isHardwareAccelerated = false
        }

        // 5. Prepare session
        let prepStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepStatus == noErr else {
            throw VideoEncoderError.prepareFailed(prepStatus)
        }

        self.session = session
        self.lastIntervalTime = CACurrentMediaTime()

        print("[Miroo] Encoder initialized")
        print("[Miroo] Codec: H.264")
        print("[Miroo] Resolution: \(width)x\(height)")
        print("[Miroo] Target FPS: \(targetFPS)")
        print("[Miroo] Bitrate: \(Double(averageBitrate) / 1_000_000.0) Mbps")
        print("[Miroo] Keyframe interval: \(keyframeInterval) frames")
        print("[Miroo] Hardware acceleration: \(isHardwareAccelerated ? "enabled" : "disabled")")
    }

    // MARK: - Frame Encoding

    private struct EncodeTimingContext {
        let captureTimestampNs: UInt64
        let encodeStartTimestampNs: UInt64
    }

    /// Submits a raw CVPixelBuffer for hardware compression with capture and encode timing.
    public func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, captureTimestampNs: UInt64 = 0, forceKeyframe: Bool = false) {
        os_unfair_lock_lock(&sessionLock)
        guard let session = session else {
            os_unfair_lock_unlock(&sessionLock)
            totalFailures += 1
            return
        }

        let encodeStartNs = UInt64(CACurrentMediaTime() * 1_000_000_000.0)
        let resolvedCapNs: UInt64
        if captureTimestampNs > 0 {
            resolvedCapNs = captureTimestampNs
        } else if presentationTime.timescale > 0 {
            resolvedCapNs = UInt64(Double(presentationTime.value) / Double(presentationTime.timescale) * 1_000_000_000.0)
        } else {
            resolvedCapNs = encodeStartNs
        }

        PipelineBenchmark.shared.recordEncodeStart()

        let contextPtr = UnsafeMutablePointer<EncodeTimingContext>.allocate(capacity: 1)
        contextPtr.pointee = EncodeTimingContext(
            captureTimestampNs: resolvedCapNs,
            encodeStartTimestampNs: encodeStartNs
        )

        var frameProps: CFDictionary? = nil
        if forceKeyframe {
            let props: [CFString: Any] = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: true
            ]
            frameProps = props as CFDictionary
        }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: frameDuration,
            frameProperties: frameProps,
            sourceFrameRefcon: UnsafeMutableRawPointer(contextPtr),
            infoFlagsOut: nil
        )
        os_unfair_lock_unlock(&sessionLock)

        if status != noErr {
            totalFailures += 1
            contextPtr.deallocate()
            print("[Miroo] Warning: EncodeFrame failed with status: \(status)")
        }
    }

    /// Flushes any pending frames.
    public func flush() {
        os_unfair_lock_lock(&sessionLock)
        defer { os_unfair_lock_unlock(&sessionLock) }
        flushLocked()
    }

    private func flushLocked() {
        guard let session = session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    /// Invalidates and releases the compression session.
    public func invalidate() {
        os_unfair_lock_lock(&sessionLock)
        defer { os_unfair_lock_unlock(&sessionLock) }
        invalidateLocked()
    }

    private func invalidateLocked() {
        if let session = session {
            flushLocked()
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        if let handle = debugFileHandle {
            try? handle.close()
            self.debugFileHandle = nil
        }
    }

    // MARK: - Debug Stream Recording

    /// Enables writing up to `maxFrames` of Annex-B H.264 data to a local file for independent inspection.
    public func enableDebugRecording(to filePath: String, maxFrames: Int = 180) {
        FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
        self.debugFileHandle = FileHandle(forWritingAtPath: filePath)
        self.debugFrameLimit = maxFrames
        self.debugFramesWritten = 0
        print("[Miroo] Debug H.264 recording enabled: \(filePath) (capturing first \(maxFrames) frames)")
    }

    // MARK: - Output Callback Handling

    private func handleCompressionOutput(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        sourceFrameRefCon: UnsafeMutableRawPointer?
    ) {
        let encodeCompleteNs = UInt64(CACurrentMediaTime() * 1_000_000_000.0)
        var captureNs: UInt64 = 0
        var encodeStartNs: UInt64 = 0
        var frameLatencyMs: Double = 0.0
        var encodeDurationUs: UInt32 = 0
        if let refCon = sourceFrameRefCon {
            let ctxPtr = refCon.assumingMemoryBound(to: EncodeTimingContext.self)
            captureNs = ctxPtr.pointee.captureTimestampNs
            encodeStartNs = ctxPtr.pointee.encodeStartTimestampNs
            let elapsedNs = max(0, encodeCompleteNs - encodeStartNs)
            frameLatencyMs = Double(elapsedNs) / 1_000_000.0
            encodeDurationUs = UInt32(min(UInt64(UInt32.max), elapsedNs / 1000))
            ctxPtr.deallocate()
        }

        PipelineBenchmark.shared.recordEncodeComplete(durationUs: encodeDurationUs)

        guard status == noErr, let sampleBuffer = sampleBuffer else {
            totalFailures += 1
            return
        }

        if infoFlags.contains(.frameDropped) {
            print("[Miroo] Warning: Encoder dropped frame.")
            return
        }

        // 1. Determine if this is a keyframe (sync sample)
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let firstAttachment = attachments.first else {
            return
        }
        let notSync = firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 2. Convert to Annex-B format (prepend SPS/PPS on keyframes, replace 4-byte lengths with 00 00 00 01)
        guard let annexBData = convertToAnnexB(sampleBuffer: sampleBuffer, isKeyframe: isKeyframe) else {
            return
        }

        // 3. Update statistics
        totalFramesEncoded += 1
        if isKeyframe { totalKeyframes += 1 }
        totalBytesEncoded += UInt64(annexBData.count)

        intervalFrames += 1
        intervalBytes += UInt64(annexBData.count)
        intervalLatencySum += frameLatencyMs

        // 4. Record to debug file if enabled
        if let fileHandle = debugFileHandle, debugFramesWritten < debugFrameLimit {
            fileHandle.write(annexBData)
            debugFramesWritten += 1
            if debugFramesWritten == debugFrameLimit {
                print("[Miroo] Debug stream capture complete: \(debugFramesWritten) frames written.")
                try? fileHandle.close()
                self.debugFileHandle = nil
            }
        }

        // 5. Print statistics every 60 frames
        if totalFramesEncoded % 60 == 0 {
            let now = CACurrentMediaTime()
            let elapsed = now - lastIntervalTime
            let fps = (elapsed > 0) ? (Double(intervalFrames) / elapsed) : Double(targetFPS)
            let currentBitrateMbps = (elapsed > 0) ? (Double(intervalBytes * 8) / elapsed / 1_000_000.0) : 0.0
            let avgFrameSizeKB = (intervalFrames > 0) ? (Double(intervalBytes) / Double(intervalFrames) / 1024.0) : 0.0
            let avgLatency = (intervalFrames > 0) ? (intervalLatencySum / Double(intervalFrames)) : frameLatencyMs
            averageLatencyMs = avgLatency

            lastIntervalTime = now
            intervalFrames = 0
            intervalBytes = 0
            intervalLatencySum = 0

            print("")
            print("[Miroo] Encoded frame #\(totalFramesEncoded)")
            print("[Miroo] FPS: ~\(Int(round(fps)))")
            print("[Miroo] Encoded size: \(annexBData.count) bytes")
            print("[Miroo] Keyframe: \(isKeyframe ? "YES" : "NO")")
            print("[Miroo] Encoding latency: \(String(format: "%.2f", avgLatency)) ms")
            print("[Miroo] Stats: bitrate=\(String(format: "%.2f", currentBitrateMbps)) Mbps, avgFrame=\(String(format: "%.1f", avgFrameSizeKB)) KB, keyframes=\(totalKeyframes), failures=\(totalFailures)")
        }

        // 6. Deliver to subscriber with full pipeline timestamps
        onEncodedFrame?(annexBData, pts, isKeyframe, captureNs, encodeStartNs, encodeCompleteNs, encodeDurationUs)
    }

    // MARK: - Annex-B Conversion

    /// Converts AVCC CMSampleBuffer data into Annex-B format (with start codes [0x00, 0x00, 0x00, 0x01]).
    /// For keyframes, prepends SPS and PPS parameter sets.
    private func convertToAnnexB(sampleBuffer: CMSampleBuffer, isKeyframe: Bool) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer = dataPointer else { return nil }

        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var annexBData = Data()

        // 1. For keyframes, extract and prepend SPS & PPS
        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Extract SPS (Parameter Set Index 0)
            var spsPointer: UnsafePointer<UInt8>?
            var spsSize: Int = 0
            let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            if spsStatus == noErr, let spsPointer = spsPointer, spsSize > 0 {
                annexBData.append(contentsOf: startCode)
                annexBData.append(spsPointer, count: spsSize)
            }

            // Extract PPS (Parameter Set Index 1)
            var ppsPointer: UnsafePointer<UInt8>?
            var ppsSize: Int = 0
            let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            if ppsStatus == noErr, let ppsPointer = ppsPointer, ppsSize > 0 {
                annexBData.append(contentsOf: startCode)
                annexBData.append(ppsPointer, count: ppsSize)
            }
        }

        // 2. Iterate through AVCC NALUs and replace 4-byte length prefixes with Annex-B start codes
        var offset = 0
        while offset < totalLength - 4 {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, dataPointer + offset, 4)
            naluLength = CFSwapInt32BigToHost(naluLength)
            offset += 4

            guard offset + Int(naluLength) <= totalLength else {
                break
            }

            // Prepend start code
            annexBData.append(contentsOf: startCode)

            // Append NALU payload
            let naluPtr = UnsafeRawPointer(dataPointer + offset).assumingMemoryBound(to: UInt8.self)
            annexBData.append(naluPtr, count: Int(naluLength))

            offset += Int(naluLength)
        }

        return annexBData
    }
}
