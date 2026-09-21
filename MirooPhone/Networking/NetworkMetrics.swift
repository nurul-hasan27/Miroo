//
//  NetworkMetrics.swift
//  Miroo
//
//  Phase 4: Lightweight performance and streaming telemetry instrumentation.
//

import Foundation
import QuartzCore

public final class NetworkMetrics: @unchecked Sendable {
    private let lock = NSLock()

    // Lifetime counters
    private(set) public var framesEncoded: UInt64 = 0
    private(set) public var framesSent: UInt64 = 0
    private(set) public var bytesSent: UInt64 = 0
    private(set) public var framesDropped: UInt64 = 0
    private(set) public var framesReceived: UInt64 = 0
    private(set) public var bytesReceived: UInt64 = 0

    // Interval tracking
    private var lastIntervalTime: CFTimeInterval = CACurrentMediaTime()
    private var intervalBytesSent: UInt64 = 0
    private var intervalFramesSent: UInt64 = 0
    private var intervalBytesReceived: UInt64 = 0
    private var intervalFramesReceived: UInt64 = 0
    private var lastSendThroughputMbps: Double = 0.0
    private var lastSendFps: Double = 0.0
    private var lastRecvThroughputMbps: Double = 0.0
    private var lastRecvFps: Double = 0.0

    public init() {}

    public func recordFrameEncoded() {
        lock.lock()
        defer { lock.unlock() }
        framesEncoded += 1
    }

    public func recordFrameSent(bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        framesSent += 1
        bytesSent += UInt64(bytes)
        intervalBytesSent += UInt64(bytes)
        intervalFramesSent += 1
    }

    public func recordFrameDropped() {
        lock.lock()
        defer { lock.unlock() }
        framesDropped += 1
    }

    public func recordFrameReceived(bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        framesReceived += 1
        bytesReceived += UInt64(bytes)
        intervalBytesReceived += UInt64(bytes)
        intervalFramesReceived += 1
    }

    /// Generates a performance snapshot and resets the interval counters.
    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        let elapsed = max(0.001, now - lastIntervalTime)

        if elapsed >= 0.5 {
            lastSendThroughputMbps = Double(intervalBytesSent * 8) / elapsed / 1_000_000.0
            lastSendFps = Double(intervalFramesSent) / elapsed

            lastRecvThroughputMbps = Double(intervalBytesReceived * 8) / elapsed / 1_000_000.0
            lastRecvFps = Double(intervalFramesReceived) / elapsed

            lastIntervalTime = now
            intervalBytesSent = 0
            intervalFramesSent = 0
            intervalBytesReceived = 0
            intervalFramesReceived = 0
        }

        return Snapshot(
            elapsed: elapsed,
            framesEncoded: framesEncoded,
            framesSent: framesSent,
            bytesSent: bytesSent,
            framesDropped: framesDropped,
            sendThroughputMbps: lastSendThroughputMbps,
            sendFps: lastSendFps,
            framesReceived: framesReceived,
            bytesReceived: bytesReceived,
            recvThroughputMbps: lastRecvThroughputMbps,
            recvFps: lastRecvFps
        )
    }

    public struct Snapshot {
        public let elapsed: CFTimeInterval
        public let framesEncoded: UInt64
        public let framesSent: UInt64
        public let bytesSent: UInt64
        public let framesDropped: UInt64
        public let sendThroughputMbps: Double
        public let sendFps: Double

        public let framesReceived: UInt64
        public let bytesReceived: UInt64
        public let recvThroughputMbps: Double
        public let recvFps: Double
    }
}
