//
//  PipelineBenchmark.swift
//  Miroo
//
//  Phase 7: End-to-End Display Pipeline Latency & Jitter Benchmark.
//  Provides microsecond-accurate instrumentation across all 8 pipeline stages:
//  CAPTURE -> ENCODE_START -> ENCODE_COMPLETE -> NETWORK_SEND ->
//  NETWORK_RECEIVE -> DECODE_START -> DECODE_COMPLETE -> METAL_RENDER.
//  Computes real p50, p95, p99, min, avg, max percentiles, frame age, and FPS.
//

import Foundation
import QuartzCore
import os.lock

// MARK: - Percentile Statistics

public struct PercentileStats: Codable, Sendable, Equatable {
    public let count: Int
    public let min: Double
    public let avg: Double
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let max: Double
    public let stdDev: Double

    public init(
        count: Int = 0,
        min: Double = 0.0,
        avg: Double = 0.0,
        p50: Double = 0.0,
        p95: Double = 0.0,
        p99: Double = 0.0,
        max: Double = 0.0,
        stdDev: Double = 0.0
    ) {
        self.count = count
        self.min = min
        self.avg = avg
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.max = max
        self.stdDev = stdDev
    }

    /// Computes accurate percentiles and distribution parameters from raw samples.
    public static func calculate(from rawSamples: [Double]) -> PercentileStats {
        let valid = rawSamples.filter { !$0.isNaN && !$0.isInfinite && $0 >= 0.0 }
        guard !valid.isEmpty else {
            return PercentileStats()
        }

        let sorted = valid.sorted()
        let n = sorted.count

        if n == 1 {
            let val = sorted[0]
            return PercentileStats(
                count: 1,
                min: val,
                avg: val,
                p50: val,
                p95: val,
                p99: val,
                max: val,
                stdDev: 0.0
            )
        }

        let sum = sorted.reduce(0.0, +)
        let avg = sum / Double(n)

        let variance = sorted.reduce(0.0) { $0 + ($1 - avg) * ($1 - avg) } / Double(n)
        let stdDev = sqrt(variance)

        func percentile(_ p: Double) -> Double {
            let rank = (p / 100.0) * Double(n - 1)
            let lower = Int(floor(rank))
            let upper = Int(ceil(rank))
            if lower == upper {
                return sorted[lower]
            }
            let weight = rank - Double(lower)
            return sorted[lower] * (1.0 - weight) + sorted[upper] * weight
        }

        return PercentileStats(
            count: n,
            min: sorted.first ?? 0.0,
            avg: avg,
            p50: percentile(50.0),
            p95: percentile(95.0),
            p99: percentile(99.0),
            max: sorted.last ?? 0.0,
            stdDev: stdDev
        )
    }
}

// MARK: - Rolling Metric Buffer

public struct RollingMetric: Sendable {
    public let capacity: Int
    private var buffer: [Double] = []

    public init(capacity: Int = 1000) {
        self.capacity = max(10, capacity)
    }

    public mutating func record(_ value: Double) {
        guard !value.isNaN && !value.isInfinite && value >= 0.0 else { return }
        if buffer.count >= capacity {
            buffer.removeFirst()
        }
        buffer.append(value)
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    public func stats() -> PercentileStats {
        PercentileStats.calculate(from: buffer)
    }

    public var count: Int {
        buffer.count
    }
}

// MARK: - Per-Frame Metric Sample

public struct PipelineFrameMetrics: Sendable {
    public let sequence: UInt64
    public let isKeyframe: Bool
    public let captureToEncodeMs: Double
    public let encodeDurationMs: Double
    public let encodeToNetSendMs: Double
    public let networkTransitMs: Double
    public let networkReceiveToDecodeMs: Double
    public let decodeDurationMs: Double
    public let decodeToRenderMs: Double
    public let glassToRenderMs: Double
    public let frameAgeMs: Double
    public let queueDepth: Int

    public init(
        sequence: UInt64,
        isKeyframe: Bool,
        captureToEncodeMs: Double,
        encodeDurationMs: Double,
        encodeToNetSendMs: Double,
        networkTransitMs: Double,
        networkReceiveToDecodeMs: Double,
        decodeDurationMs: Double,
        decodeToRenderMs: Double,
        glassToRenderMs: Double,
        frameAgeMs: Double,
        queueDepth: Int = 1
    ) {
        self.sequence = sequence
        self.isKeyframe = isKeyframe
        self.captureToEncodeMs = max(0.0, captureToEncodeMs)
        self.encodeDurationMs = max(0.0, encodeDurationMs)
        self.encodeToNetSendMs = max(0.0, encodeToNetSendMs)
        self.networkTransitMs = max(0.0, networkTransitMs)
        self.networkReceiveToDecodeMs = max(0.0, networkReceiveToDecodeMs)
        self.decodeDurationMs = max(0.0, decodeDurationMs)
        self.decodeToRenderMs = max(0.0, decodeToRenderMs)
        self.glassToRenderMs = max(0.0, glassToRenderMs)
        self.frameAgeMs = max(0.0, frameAgeMs)
        self.queueDepth = queueDepth
    }
}

// MARK: - Pipeline Stage & Drop Counters

public struct PipelineCounters: Codable, Sendable, Equatable {
    public var framesCaptured: UInt64 = 0
    public var framesEncoded: UInt64 = 0
    public var framesTransmitted: UInt64 = 0
    public var framesReceived: UInt64 = 0
    public var framesDecoded: UInt64 = 0
    public var framesRendered: UInt64 = 0

    // Drop tracking
    public var serverQueueDrops: UInt64 = 0
    public var sequenceGaps: UInt64 = 0
    public var decoderDrops: UInt64 = 0
    public var displayDrops: UInt64 = 0

    public var totalDrops: UInt64 {
        serverQueueDrops + sequenceGaps + decoderDrops + displayDrops
    }

    /// Dropped intentionally because newer frame arrived (bounded queues)
    public var staleDrops: UInt64 {
        serverQueueDrops + displayDrops
    }

    public init() {}
}

// MARK: - Real FPS Tracking

public struct PipelineFPSReport: Codable, Sendable, Equatable {
    public let captureFPS: Double
    public let encodeFPS: Double
    public let receiveFPS: Double
    public let decodeFPS: Double
    public let renderFPS: Double

    public init(
        captureFPS: Double = 0.0,
        encodeFPS: Double = 0.0,
        receiveFPS: Double = 0.0,
        decodeFPS: Double = 0.0,
        renderFPS: Double = 0.0
    ) {
        self.captureFPS = captureFPS
        self.encodeFPS = encodeFPS
        self.receiveFPS = receiveFPS
        self.decodeFPS = decodeFPS
        self.renderFPS = renderFPS
    }
}

// MARK: - Benchmark Report Data Structure

public struct PipelineBenchmarkReport: Codable, Sendable {
    public let timestamp: Date
    public let sessionDurationSeconds: Double
    public let counters: PipelineCounters
    public let fps: PipelineFPSReport

    // 8-stage breakdown & glass-to-render
    public let captureToEncode: PercentileStats
    public let encodeDuration: PercentileStats
    public let encodeToNetSend: PercentileStats
    public let networkTransit: PercentileStats
    public let networkReceiveToDecode: PercentileStats
    public let decodeDuration: PercentileStats
    public let decodeToRender: PercentileStats
    public let glassToRender: PercentileStats
    public let frameAge: PercentileStats
    public let transport: String?

    public init(
        timestamp: Date = Date(),
        sessionDurationSeconds: Double,
        counters: PipelineCounters,
        fps: PipelineFPSReport,
        captureToEncode: PercentileStats,
        encodeDuration: PercentileStats,
        encodeToNetSend: PercentileStats,
        networkTransit: PercentileStats,
        networkReceiveToDecode: PercentileStats,
        decodeDuration: PercentileStats,
        decodeToRender: PercentileStats,
        glassToRender: PercentileStats,
        frameAge: PercentileStats,
        transport: String? = nil
    ) {
        self.timestamp = timestamp
        self.sessionDurationSeconds = sessionDurationSeconds
        self.counters = counters
        self.fps = fps
        self.captureToEncode = captureToEncode
        self.encodeDuration = encodeDuration
        self.encodeToNetSend = encodeToNetSend
        self.networkTransit = networkTransit
        self.networkReceiveToDecode = networkReceiveToDecode
        self.decodeDuration = decodeDuration
        self.decodeToRender = decodeToRender
        self.glassToRender = glassToRender
        self.frameAge = frameAge
        self.transport = transport
    }

    public func toJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func fromJSON(_ jsonString: String) -> PipelineBenchmarkReport? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PipelineBenchmarkReport.self, from: data)
    }

    /// Generates human-readable engineering diagnostics report matching Miroo Phase 7 spec.
    public func formattedSummary() -> String {
        func row(_ name: String, _ s: PercentileStats) -> String {
            return String(
                format: "  %-24@ min: %5.1f ms | avg: %5.1f ms | p50: %5.1f ms | p95: %5.1f ms | p99: %5.1f ms | max: %5.1f ms",
                name, s.min, s.avg, s.p50, s.p95, s.p99, s.max
            )
        }

        let tStr = transport != nil ? " [Transport: \(transport!)]" : ""
        return """
        ========================================================================================
                                 MIROO PIPELINE LATENCY BENCHMARK\(tStr)
        ========================================================================================
        Duration: \(String(format: "%.1f", sessionDurationSeconds))s | Samples Rendered: \(counters.framesRendered)

        STAGE LATENCY BREAKDOWN (glass-to-render):
        \(row("Capture (cap → enc)", captureToEncode))
        \(row("Encode Duration", encodeDuration))
        \(row("Mac Queue (enc → send)", encodeToNetSend))
        \(row("Network Transfer", networkTransit))
        \(row("Recv Queue (net → dec)", networkReceiveToDecode))
        \(row("Decode Duration", decodeDuration))
        \(row("Metal Render (dec → draw)", decodeToRender))
        ----------------------------------------------------------------------------------------
        \(row("Glass-to-Render (Total)", glassToRender))
        \(row("Frame Age at Glass", frameAge))
        ----------------------------------------------------------------------------------------

        ACTUAL MEASURED FRAMERATES:
          Capture FPS: \(String(format: "%5.1f", fps.captureFPS))
          Encode FPS:  \(String(format: "%5.1f", fps.encodeFPS))
          Receive FPS: \(String(format: "%5.1f", fps.receiveFPS))
          Decode FPS:  \(String(format: "%5.1f", fps.decodeFPS))
          Render FPS:  \(String(format: "%5.1f", fps.renderFPS))

        FRAME ACCOUNTING & DROPS:
          Frames Captured:    \(counters.framesCaptured)
          Frames Encoded:     \(counters.framesEncoded)
          Frames Transmitted: \(counters.framesTransmitted)
          Frames Received:    \(counters.framesReceived)
          Frames Decoded:     \(counters.framesDecoded)
          Frames Rendered:    \(counters.framesRendered)
          Server Drops (Stale Queue): \(counters.serverQueueDrops)
          Sequence Gaps (Net Loss):   \(counters.sequenceGaps)
          Decoder Drops (Pre-Init):   \(counters.decoderDrops)
          Display Drops (Stale Frame):\(counters.displayDrops)
          Total Dropped Frames:       \(counters.totalDrops) (Stale intentional: \(counters.staleDrops))
        ========================================================================================
        """
    }
}

// MARK: - Pipeline Benchmark Tracker Engine

public final class PipelineBenchmark: @unchecked Sendable {
    public static let shared = PipelineBenchmark()

    private var lock = os_unfair_lock_s()
    private var sessionStartTime: CFTimeInterval = CACurrentMediaTime()
    public var activeTransport: String = "TCP"

    // Stage metrics
    private var captureToEncodeMetric = RollingMetric(capacity: 1000)
    private var encodeDurationMetric = RollingMetric(capacity: 1000)
    private var encodeToNetSendMetric = RollingMetric(capacity: 1000)
    private var networkTransitMetric = RollingMetric(capacity: 1000)
    private var networkReceiveToDecodeMetric = RollingMetric(capacity: 1000)
    private var decodeDurationMetric = RollingMetric(capacity: 1000)
    private var decodeToRenderMetric = RollingMetric(capacity: 1000)
    private var glassToRenderMetric = RollingMetric(capacity: 1000)
    private var frameAgeMetric = RollingMetric(capacity: 1000)

    // Counters
    private var counters = PipelineCounters()

    // Rolling FPS tracking
    private var lastCapTime: CFTimeInterval = 0
    private var capIntervalFrames: Int = 0
    private var capFPS: Double = 0.0

    private var lastEncTime: CFTimeInterval = 0
    private var encIntervalFrames: Int = 0
    private var encFPS: Double = 0.0

    private var lastRecvTime: CFTimeInterval = 0
    private var recvIntervalFrames: Int = 0
    private var recvFPS: Double = 0.0

    private var lastDecTime: CFTimeInterval = 0
    private var decIntervalFrames: Int = 0
    private var decFPS: Double = 0.0

    private var lastRenderTime: CFTimeInterval = 0
    private var renderIntervalFrames: Int = 0
    private var renderFPS: Double = 0.0

    // Clock offset synchronization (Cristian's algorithm over Ping/Pong)
    private(set) public var clockOffsetNs: Int64 = 0
    private var minRTTNs: Int64 = 0

    public init() {
        self.sessionStartTime = CACurrentMediaTime()
    }

    // MARK: - Mac Stage Recording

    public func recordCapture(timestampNs: UInt64) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        counters.framesCaptured += 1
        capIntervalFrames += 1

        let now = CACurrentMediaTime()
        let elapsed = now - lastCapTime
        if elapsed >= 0.5 {
            capFPS = Double(capIntervalFrames) / elapsed
            lastCapTime = now
            capIntervalFrames = 0
        }
    }

    public func recordEncodeStart() {
        // High-frequency hook
    }

    public func recordEncodeComplete(durationUs: UInt32) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        counters.framesEncoded += 1
        encIntervalFrames += 1

        let now = CACurrentMediaTime()
        let elapsed = now - lastEncTime
        if elapsed >= 0.5 {
            encFPS = Double(encIntervalFrames) / elapsed
            lastEncTime = now
            encIntervalFrames = 0
        }
    }

    public func recordFrameTransmitted(sequence: UInt64) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        counters.framesTransmitted += 1
    }

    public func recordServerDrop(isKeyframe: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        counters.serverQueueDrops += 1
    }

    // MARK: - Phone Stage Recording

    public func recordFrameReceived(sequence: UInt64) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        counters.framesReceived += 1
        recvIntervalFrames += 1

        let now = CACurrentMediaTime()
        let elapsed = now - lastRecvTime
        if elapsed >= 0.5 {
            recvFPS = Double(recvIntervalFrames) / elapsed
            lastRecvTime = now
            recvIntervalFrames = 0
        }
    }

    public func recordSequenceGap(gap: UInt64) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        counters.sequenceGaps += gap
    }

    public func recordDecodeStart() {
        // High-frequency hook
    }

    public func recordDecodeComplete(durationMs: Double) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        counters.framesDecoded += 1
        decIntervalFrames += 1

        let now = CACurrentMediaTime()
        let elapsed = now - lastDecTime
        if elapsed >= 0.5 {
            decFPS = Double(decIntervalFrames) / elapsed
            lastDecTime = now
            decIntervalFrames = 0
        }
    }

    public func recordDecoderDrop() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        counters.decoderDrops += 1
    }

    public func recordDisplayDrop() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        counters.displayDrops += 1
    }

    public func recordFrameRendered(metrics: PipelineFrameMetrics) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        counters.framesRendered += 1
        renderIntervalFrames += 1

        let now = CACurrentMediaTime()
        let elapsed = now - lastRenderTime
        if elapsed >= 0.5 {
            renderFPS = Double(renderIntervalFrames) / elapsed
            lastRenderTime = now
            renderIntervalFrames = 0
        }

        captureToEncodeMetric.record(metrics.captureToEncodeMs)
        encodeDurationMetric.record(metrics.encodeDurationMs)
        encodeToNetSendMetric.record(metrics.encodeToNetSendMs)
        networkTransitMetric.record(metrics.networkTransitMs)
        networkReceiveToDecodeMetric.record(metrics.networkReceiveToDecodeMs)
        decodeDurationMetric.record(metrics.decodeDurationMs)
        decodeToRenderMetric.record(metrics.decodeToRenderMs)
        glassToRenderMetric.record(metrics.glassToRenderMs)
        frameAgeMetric.record(metrics.frameAgeMs)
    }

    // MARK: - Clock Synchronization

    public func updateClockOffset(clientTimestamp: Int64, serverTimestamp: Int64, receiveTimestamp: Int64) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let rttNs = max(100_000, receiveTimestamp - clientTimestamp) // Min 0.1ms clamp
        let measuredOffsetNs = serverTimestamp - (clientTimestamp + rttNs / 2)

        if minRTTNs == 0 || rttNs < minRTTNs {
            minRTTNs = rttNs
            clockOffsetNs = measuredOffsetNs
        } else {
            // Smoothly adapt clock offset using low-jitter sample bias
            clockOffsetNs = Int64(0.95 * Double(clockOffsetNs) + 0.05 * Double(measuredOffsetNs))
        }
    }

    // MARK: - Report Generation & Reset

    public func generateReport() -> PipelineBenchmarkReport {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let duration = max(0.001, CACurrentMediaTime() - sessionStartTime)
        let fpsReport = PipelineFPSReport(
            captureFPS: capFPS,
            encodeFPS: encFPS,
            receiveFPS: recvFPS,
            decodeFPS: decFPS,
            renderFPS: renderFPS
        )

        return PipelineBenchmarkReport(
            timestamp: Date(),
            sessionDurationSeconds: duration,
            counters: counters,
            fps: fpsReport,
            captureToEncode: captureToEncodeMetric.stats(),
            encodeDuration: encodeDurationMetric.stats(),
            encodeToNetSend: encodeToNetSendMetric.stats(),
            networkTransit: networkTransitMetric.stats(),
            networkReceiveToDecode: networkReceiveToDecodeMetric.stats(),
            decodeDuration: decodeDurationMetric.stats(),
            decodeToRender: decodeToRenderMetric.stats(),
            glassToRender: glassToRenderMetric.stats(),
            frameAge: frameAgeMetric.stats(),
            transport: activeTransport
        )
    }

    public func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        sessionStartTime = CACurrentMediaTime()
        counters = PipelineCounters()

        captureToEncodeMetric.reset()
        encodeDurationMetric.reset()
        encodeToNetSendMetric.reset()
        networkTransitMetric.reset()
        networkReceiveToDecodeMetric.reset()
        decodeDurationMetric.reset()
        decodeToRenderMetric.reset()
        glassToRenderMetric.reset()
        frameAgeMetric.reset()

        lastCapTime = CACurrentMediaTime()
        capIntervalFrames = 0
        capFPS = 0.0

        lastEncTime = CACurrentMediaTime()
        encIntervalFrames = 0
        encFPS = 0.0

        lastRecvTime = CACurrentMediaTime()
        recvIntervalFrames = 0
        recvFPS = 0.0

        lastDecTime = CACurrentMediaTime()
        decIntervalFrames = 0
        decFPS = 0.0

        lastRenderTime = CACurrentMediaTime()
        renderIntervalFrames = 0
        renderFPS = 0.0

        clockOffsetNs = 0
        minRTTNs = 0
    }

    /// Exports benchmark report to persistent structured JSON file on disk.
    public func exportJSON(toPath path: String, report: PipelineBenchmarkReport? = nil) throws {
        let rep = report ?? generateReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(rep)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
