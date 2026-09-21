//
//  VideoFrame.swift
//  Miroo
//
//  Phase 5 & 6: Decoded video frame encapsulation with presentation timestamps,
//  per-stage latency breakdown, jitter analysis, and pipeline diagnostics.
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
        bitrateMbps: Double = 0.0
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
