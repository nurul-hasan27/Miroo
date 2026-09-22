//
//  H264Decoder.swift
//  Miroo
//
//  Phase 5: Low-latency hardware H.264 video decoder using Apple's VideoToolbox.
//  Consumes Annex-B H.264 network frames, performs AVCC conversion, initializes
//  VTDecompressionSession on parameter sets, and outputs CVPixelBuffers in 420v format.
//

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore

public final class H264Decoder: @unchecked Sendable {

    // MARK: - Properties
    private let queue = DispatchQueue(label: "com.miroo.decoder", qos: .userInteractive)

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentSPS: Data?
    private var currentPPS: Data?
    private var hasDecodedFirstKeyframe = false

    // Telemetry & Metrics
    private(set) public var totalFramesReceived: UInt64 = 0
    private(set) public var totalFramesDecoded: UInt64 = 0
    private(set) public var totalKeyframesDecoded: UInt64 = 0
    private(set) public var totalDecodeErrors: UInt64 = 0
    private(set) public var totalDroppedBeforeInit: UInt64 = 0
    private(set) public var averageDecodeLatencyMs: Double = 0.0

    private var intervalDecodedFrames: UInt64 = 0
    private var intervalLatencySum: Double = 0.0
    private var lastIntervalTime: CFTimeInterval = CACurrentMediaTime()

    // Output Callback
    public var onFrameDecoded: ((DecodedVideoFrame) -> Void)?
    public var onKeyframeNeeded: (() -> Void)?
    public var onError: ((Error) -> Void)?

    public init() {}

    deinit {
        invalidate()
    }

    // MARK: - Frame Ingestion

    /// Decodes an Annex-B H.264 video frame.
    public func decode(
        annexBData: Data,
        sequence: UInt64,
        ptsNanoseconds: Int64,
        isKeyframeHint: Bool,
        timing: VideoFrameTiming? = nil,
        networkReceiveTimestampNs: UInt64 = 0,
        networkTransitMs: Double = 0.0,
        jitterMs: Double = 0.0
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.totalFramesReceived += 1

            let parsed = H264NALUParser.parse(annexBData: annexBData)

            // 1. Check for new SPS / PPS parameter sets
            if let newSPS = parsed.sps, let newPPS = parsed.pps {
                if newSPS != self.currentSPS || newPPS != self.currentPPS || self.session == nil {
                    print("[Miroo Decoder] Detected new SPS (\(newSPS.count) bytes) and PPS (\(newPPS.count) bytes). Initializing VTDecompressionSession...")
                    self.updateFormatDescriptionAndSession(sps: newSPS, pps: newPPS)
                }
            }

            // 2. Keyframe Recovery Guard: Do not attempt to decode if session is not yet initialized
            guard let session = self.session, let formatDesc = self.formatDescription else {
                self.totalDroppedBeforeInit += 1
                PipelineBenchmark.shared.recordDecoderDrop()
                if self.totalDroppedBeforeInit % 30 == 1 {
                    print("[Miroo Decoder] Waiting for keyframe containing SPS/PPS before starting decode...")
                }
                return
            }

            // Must contain actual video slice data (IDR or non-IDR)
            guard parsed.hasSlice, !parsed.avccData.isEmpty else {
                PipelineBenchmark.shared.recordDecoderDrop()
                return
            }

            // A newly initialized session MUST start decoding on an IDR keyframe
            if !self.hasDecodedFirstKeyframe {
                guard parsed.hasKeyframe else {
                    self.totalDroppedBeforeInit += 1
                    PipelineBenchmark.shared.recordDecoderDrop()
                    return
                }
                self.hasDecodedFirstKeyframe = true
                print("[Miroo Decoder] First IDR keyframe received! Commencing decode stream...")
            }

            // 3. Create CMBlockBuffer wrapping AVCC data
            var blockBuffer: CMBlockBuffer?
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: parsed.avccData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: parsed.avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard blockStatus == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else {
                self.totalDecodeErrors += 1
                PipelineBenchmark.shared.recordDecoderDrop()
                return
            }

            parsed.avccData.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                CMBlockBufferReplaceDataBytes(
                    with: base,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: parsed.avccData.count
                )
            }

            // 4. Create CMSampleBuffer
            var sampleBuffer: CMSampleBuffer?
            var timingInfo = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: CMTime(value: ptsNanoseconds, timescale: 1_000_000_000),
                decodeTimeStamp: .invalid
            )

            let sampleStatus = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDesc,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )

            guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
                self.totalDecodeErrors += 1
                PipelineBenchmark.shared.recordDecoderDrop()
                return
            }

            // 5. Submit to hardware VTDecompressionSession
            let decodeStartTime = CACurrentMediaTime()
            let decodeStartTimestampNs = UInt64(decodeStartTime * 1_000_000_000.0)
            PipelineBenchmark.shared.recordDecodeStart()

            var infoFlagsOut: VTDecodeInfoFlags = []

            let decodeStatus = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: &infoFlagsOut
            ) { [weak self] status, flags, imageBuffer, pts, duration in
                guard let self = self else { return }
                let decodeCompleteTime = CACurrentMediaTime()
                let latencyMs = (decodeCompleteTime - decodeStartTime) * 1000.0
                let decodeCompleteTimestampNs = UInt64(decodeCompleteTime * 1_000_000_000.0)

                PipelineBenchmark.shared.recordDecodeComplete(durationMs: latencyMs)

                if status == noErr, let pixelBuffer = imageBuffer {
                    let encMs = timing.map { Double($0.encodeDurationUs) / 1000.0 } ?? 3.2
                    let qMs = timing.map { Double($0.macQueueDelayUs) / 1000.0 } ?? 0.2
                    var capMs = 1.8
                    if let t = timing, t.networkSendTimestampNs > 0, t.captureTimestampNs > 0, t.networkSendTimestampNs >= t.captureTimestampNs {
                        let totalMacTimeUs = Double(t.networkSendTimestampNs - t.captureTimestampNs) / 1000.0
                        let capTimeUs = totalMacTimeUs - Double(t.encodeDurationUs) - Double(t.macQueueDelayUs)
                        if capTimeUs > 0 && capTimeUs < 20_000 {
                            capMs = capTimeUs / 1000.0
                        }
                    }

                    self.handleDecodedBuffer(
                        pixelBuffer: pixelBuffer,
                        pts: pts,
                        sequence: sequence,
                        isKeyframe: parsed.hasKeyframe || isKeyframeHint,
                        captureMs: capMs,
                        encodeMs: encMs,
                        queueMs: qMs,
                        networkMs: networkTransitMs,
                        decodeDurationMs: latencyMs,
                        captureTimestampNs: ptsNanoseconds,
                        timing: timing,
                        networkReceiveTimestampNs: networkReceiveTimestampNs,
                        decodeStartTimestampNs: decodeStartTimestampNs,
                        decodeCompleteTimestampNs: decodeCompleteTimestampNs
                    )
                } else {
                    self.totalDecodeErrors += 1
                    PipelineBenchmark.shared.recordDecoderDrop()
                    if self.totalDecodeErrors % 30 == 1 {
                        print("[Miroo Decoder] Hardware decode error: OSStatus \(status), flags=\(flags)")
                    }
                    self.hasDecodedFirstKeyframe = false
                    self.onKeyframeNeeded?()
                }
            }

            if decodeStatus != noErr {
                self.totalDecodeErrors += 1
                PipelineBenchmark.shared.recordDecoderDrop()
                print("[Miroo Decoder] VTDecompressionSessionDecodeFrame failed with status \(decodeStatus)")
                self.hasDecodedFirstKeyframe = false
                self.onKeyframeNeeded?()
            }
        }
    }

    // MARK: - Decoded Frame Handling

    private func handleDecodedBuffer(
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        sequence: UInt64,
        isKeyframe: Bool,
        captureMs: Double,
        encodeMs: Double,
        queueMs: Double,
        networkMs: Double,
        decodeDurationMs: Double,
        captureTimestampNs: Int64,
        timing: VideoFrameTiming? = nil,
        networkReceiveTimestampNs: UInt64 = 0,
        decodeStartTimestampNs: UInt64 = 0,
        decodeCompleteTimestampNs: UInt64 = 0
    ) {
        totalFramesDecoded += 1
        if isKeyframe { totalKeyframesDecoded += 1 }

        intervalDecodedFrames += 1
        intervalLatencySum += decodeDurationMs

        // Log telemetry periodically every 60 frames
        if totalFramesDecoded % 60 == 0 {
            let now = CACurrentMediaTime()
            let elapsed = max(0.001, now - lastIntervalTime)
            let fps = Double(intervalDecodedFrames) / elapsed
            averageDecodeLatencyMs = intervalLatencySum / Double(max(1, intervalDecodedFrames))

            lastIntervalTime = now
            intervalDecodedFrames = 0
            intervalLatencySum = 0

            print("[Miroo Decoder] Decoded frame #\(totalFramesDecoded) (~Int(fps): \(Int(round(fps))) FPS, latency: \(String(format: "%.2f", averageDecodeLatencyMs)) ms, errors: \(totalDecodeErrors))")
        }

        let frame = DecodedVideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            sequence: sequence,
            isKeyframe: isKeyframe,
            captureMs: captureMs,
            encodeMs: encodeMs,
            queueMs: queueMs,
            networkMs: networkMs,
            decodeDurationMs: decodeDurationMs,
            captureTimestampNs: captureTimestampNs,
            timing: timing,
            networkReceiveTimestampNs: networkReceiveTimestampNs,
            decodeStartTimestampNs: decodeStartTimestampNs,
            decodeCompleteTimestampNs: decodeCompleteTimestampNs
        )

        onFrameDecoded?(frame)
    }

    // MARK: - Session Setup & Lifecycle

    private func updateFormatDescriptionAndSession(sps: Data, pps: Data) {
        // Release existing session if any
        if let existing = session {
            VTDecompressionSessionInvalidate(existing)
            self.session = nil
        }

        self.currentSPS = sps
        self.currentPPS = pps

        var newFormatDesc: CMVideoFormatDescription?
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                guard let spsBase = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                var ptrs = [spsBase, ppsBase]
                var sizes = [sps.count, pps.count]

                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &ptrs,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormatDesc
                )

                if status != noErr {
                    print("[Miroo Decoder] ERROR: Failed to create format description from parameter sets: \(status)")
                }
            }
        }

        guard let formatDesc = newFormatDesc else { return }
        self.formatDescription = formatDesc

        // Configure destination pixel buffer attributes: 420YpCbCr8BiPlanarVideoRange (420v) + Metal compatibility
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var newSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )

        guard sessionStatus == noErr, let session = newSession else {
            print("[Miroo Decoder] ERROR: Failed to create VTDecompressionSession: \(sessionStatus)")
            return
        }

        // Configure real-time properties
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.session = session
        self.hasDecodedFirstKeyframe = false
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
        print("[Miroo Decoder] VTDecompressionSession initialized successfully (\(dimensions.width)x\(dimensions.height), format=420v)")
    }

    public func invalidate() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let session = self.session {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            self.formatDescription = nil
            self.currentSPS = nil
            self.currentPPS = nil
            self.hasDecodedFirstKeyframe = false
            print("[Miroo Decoder] Invalidated.")
        }
    }
}
