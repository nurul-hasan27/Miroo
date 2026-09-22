//
//  VideoFrame.swift
//  Miroo
//
//  Phase 5, 6 & 6.5: Decoded video frame encapsulation with presentation timestamps,
//  per-stage latency breakdown, jitter analysis, frame interval statistics, and Metal timing.
//

import Foundation
import CoreVideo
import CoreMedia
import QuartzCore

public struct FrameDiagnostics: Sendable {
    public var captureMs: Double
    public var encodeMs: Double
    public var networkMs: Double
    public var decodeMs: Double
    public var metalMs: Double
    public var queueMs: Double
    public var pipelineMs: Double
    public var fps: Double
    public var jitterMs: Double
    public var dropPercentage: Double
    public var queueDepth: Int
    public var bitrateMbps: Double

    // Phase 6.5 Frame Pacing & Interval Metrics
    public var avgIntervalMs: Double
    public var minIntervalMs: Double
    public var maxIntervalMs: Double
    public var p50IntervalMs: Double
    public var p95IntervalMs: Double
    public var p99IntervalMs: Double
    public var jitterStdDevMs: Double
    public var framesOver20ms: Int
    public var framesOver25ms: Int
    public var framesOver33ms: Int

    // Phase 6.5 Metal Sub-Stage Breakdown
    public var metalPrepMs: Double
    public var metalDrawableWaitMs: Double
    public var metalEncodeMs: Double
    public var metalGpuMs: Double
    public var presentationMode: String

    // Usable Display / Viewport Diagnostics
    public var screenPixelsStr: String
    public var safeAreaInsetsStr: String
    public var usableViewportStr: String
    public var videoSizeStr: String
    public var renderRectStr: String

    public init(
        captureMs: Double = 0.0,
        encodeMs: Double = 0.0,
        networkMs: Double = 0.0,
        decodeMs: Double = 0.0,
        metalMs: Double = 0.0,
        queueMs: Double = 0.0,
        pipelineMs: Double = 0.0,
        fps: Double = 0.0,
        jitterMs: Double = 0.0,
        dropPercentage: Double = 0.0,
        queueDepth: Int = 0,
        bitrateMbps: Double = 0.0,
        avgIntervalMs: Double = 16.67,
        minIntervalMs: Double = 16.67,
        maxIntervalMs: Double = 16.67,
        p50IntervalMs: Double = 16.67,
        p95IntervalMs: Double = 16.67,
        p99IntervalMs: Double = 16.67,
        jitterStdDevMs: Double = 0.5,
        framesOver20ms: Int = 0,
        framesOver25ms: Int = 0,
        framesOver33ms: Int = 0,
        metalPrepMs: Double = 0.2,
        metalDrawableWaitMs: Double = 0.1,
        metalEncodeMs: Double = 0.2,
        metalGpuMs: Double = 0.5,
        presentationMode: String = "Push",
        screenPixelsStr: String = "",
        safeAreaInsetsStr: String = "",
        usableViewportStr: String = "",
        videoSizeStr: String = "",
        renderRectStr: String = ""
    ) {
        self.captureMs = captureMs
        self.encodeMs = encodeMs
        self.networkMs = networkMs
        self.decodeMs = decodeMs
        self.metalMs = metalMs
        self.queueMs = queueMs
        self.pipelineMs = pipelineMs
        self.fps = fps
        self.jitterMs = jitterMs
        self.dropPercentage = dropPercentage
        self.queueDepth = queueDepth
        self.bitrateMbps = bitrateMbps
        self.avgIntervalMs = avgIntervalMs
        self.minIntervalMs = minIntervalMs
        self.maxIntervalMs = maxIntervalMs
        self.p50IntervalMs = p50IntervalMs
        self.p95IntervalMs = p95IntervalMs
        self.p99IntervalMs = p99IntervalMs
        self.jitterStdDevMs = jitterStdDevMs
        self.framesOver20ms = framesOver20ms
        self.framesOver25ms = framesOver25ms
        self.framesOver33ms = framesOver33ms
        self.metalPrepMs = metalPrepMs
        self.metalDrawableWaitMs = metalDrawableWaitMs
        self.metalEncodeMs = metalEncodeMs
        self.metalGpuMs = metalGpuMs
        self.presentationMode = presentationMode
        self.screenPixelsStr = screenPixelsStr
        self.safeAreaInsetsStr = safeAreaInsetsStr
        self.usableViewportStr = usableViewportStr
        self.videoSizeStr = videoSizeStr
        self.renderRectStr = renderRectStr
    }
}

public struct DecodedVideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTimeStamp: CMTime
    public let sequence: UInt64
    public let isKeyframe: Bool
    public let captureMs: Double
    public let encodeMs: Double
    public let queueMs: Double
    public let networkMs: Double
    public let decodeDurationMs: Double
    public let captureTimestampNs: Int64
    public let decodedTimestamp: CFTimeInterval

    public var width: Int {
        CVPixelBufferGetWidth(pixelBuffer)
    }

    public var height: Int {
        CVPixelBufferGetHeight(pixelBuffer)
    }

    public init(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        sequence: UInt64,
        isKeyframe: Bool,
        captureMs: Double = 0.0,
        encodeMs: Double = 0.0,
        queueMs: Double = 0.0,
        networkMs: Double = 0.0,
        decodeDurationMs: Double = 0.0,
        captureTimestampNs: Int64 = 0,
        decodedTimestamp: CFTimeInterval = CACurrentMediaTime()
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTimeStamp = presentationTimeStamp
        self.sequence = sequence
        self.isKeyframe = isKeyframe
        self.captureMs = captureMs
        self.encodeMs = encodeMs
        self.queueMs = queueMs
        self.networkMs = networkMs
        self.decodeDurationMs = decodeDurationMs
        self.captureTimestampNs = captureTimestampNs
        self.decodedTimestamp = decodedTimestamp
    }
}
