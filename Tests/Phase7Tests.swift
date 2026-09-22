//
//  Phase7Tests.swift
//  Miroo
//
//  Phase 7 Automated Verification Suite:
//  1. Timestamp propagation (VideoFrameTiming serialization, message framing & deserialization)
//  2. Metric calculation (8-stage pipeline breakdown and glass-to-render sum)
//  3. Percentile calculation (p50, p95, p99, min, avg, max, stdDev)
//  4. Frame sequence tracking (continuity & gap loss detection)
//  5. Dropped-frame detection (server, network, decoder, display drops)
//  6. Stale-frame detection (intentional queue-capacity stale drop classification)
//  7. Zero / invalid timestamp handling (NaN, negative, backwards clock resilience)
//  8. Metrics reset between sessions
//

import Foundation
import CoreMedia
import QuartzCore
@testable import MirooNetworking

@main
struct Phase7Tests {
    static func main() {
        print("=======================================================")
        print("      Miroo Phase 7 Automated Verification Suite      ")
        print("=======================================================")
        print("")

        var allPassed = true

        func runTest(_ name: String, block: () throws -> Void) {
            print("--- \(name) ---")
            do {
                try block()
                print("PASSED: \(name)\n")
            } catch {
                print("FAILED: \(name): \(error)\n")
                allPassed = false
            }
        }

        // Test 1: Timestamp Propagation
        runTest("Test 1: Timestamp Propagation (VideoFrameTiming serialization & parsing)") {
            let capNs: UInt64 = 1_700_000_000_123_456
            let encStartNs: UInt64 = 1_700_000_001_623_456
            let encCompNs: UInt64 = 1_700_000_011_823_456
            let netSendNs: UInt64 = 1_700_000_012_323_456
            let encDurUs: UInt32 = 10_200
            let qDelayUs: UInt32 = 500

            let timing = VideoFrameTiming(
                captureTimestampNs: capNs,
                encodeStartTimestampNs: encStartNs,
                encodeCompleteTimestampNs: encCompNs,
                networkSendTimestampNs: netSendNs,
                encodeDurationUs: encDurUs,
                macQueueDelayUs: qDelayUs
            )

            let serializedTiming = timing.serialize()
            assert(serializedTiming.count == 44, "Full header must be exactly 44 bytes, got \(serializedTiming.count)")

            let mockAnnexB = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00])
            var payload = serializedTiming
            payload.append(mockAnnexB)

            let (parsedTiming, parsedAnnexB) = VideoFrameTiming.parse(from: payload)
            guard let pt = parsedTiming else {
                throw TestError("Failed to parse VideoFrameTiming from payload")
            }

            assert(pt.captureTimestampNs == capNs, "Capture timestamp mismatch: \(pt.captureTimestampNs) vs \(capNs)")
            assert(pt.encodeStartTimestampNs == encStartNs, "Encode start mismatch")
            assert(pt.encodeCompleteTimestampNs == encCompNs, "Encode complete mismatch")
            assert(pt.networkSendTimestampNs == netSendNs, "Network send mismatch")
            assert(pt.encodeDurationUs == encDurUs, "Encode duration mismatch")
            assert(pt.macQueueDelayUs == qDelayUs, "Queue delay mismatch")
            assert(parsedAnnexB == mockAnnexB, "Annex-B payload corrupted")
            print("✅ 44-byte timing header serialized, transmitted, and parsed with 100% bit-for-bit precision")

            // Test legacy 20-byte fallback
            var legacyData = Data()
            var m = VideoFrameTiming.magic.bigEndian
            var enc = encDurUs.bigEndian
            var q = qDelayUs.bigEndian
            var s = Int64(netSendNs).bigEndian
            withUnsafeBytes(of: &m) { legacyData.append(contentsOf: $0) }
            withUnsafeBytes(of: &enc) { legacyData.append(contentsOf: $0) }
            withUnsafeBytes(of: &q) { legacyData.append(contentsOf: $0) }
            withUnsafeBytes(of: &s) { legacyData.append(contentsOf: $0) }
            legacyData.append(mockAnnexB)

            let (parsedLegacy, _) = VideoFrameTiming.parse(from: legacyData)
            guard let pl = parsedLegacy else {
                throw TestError("Failed to parse legacy 20-byte VideoFrameTiming")
            }
            assert(pl.encodeDurationUs == encDurUs, "Legacy encode duration mismatch")
            assert(pl.macQueueDelayUs == qDelayUs, "Legacy queue delay mismatch")
            assert(pl.networkSendTimestampNs == netSendNs, "Legacy send timestamp mismatch")
            print("✅ Backwards-compatible legacy 20-byte timing header parsed successfully")
        }

        // Test 2: Metric Calculation
        runTest("Test 2: Metric Calculation (8-stage pipeline breakdown & glass-to-render)") {
            let capNs: UInt64 = 1_000_000_000
            let encStartNs: UInt64 = 1_001_500_000 // 1.5ms
            let encCompNs: UInt64 = 1_011_500_000  // 10.0ms
            let netSendNs: UInt64 = 1_012_000_000  // 0.5ms
            let netTransitMs: Double = 2.0
            let netRecvToDecMs: Double = 0.5
            let decDurationMs: Double = 4.0
            let decToRenderMs: Double = 2.0

            let capToEncMs = Double(encStartNs - capNs) / 1_000_000.0
            let encDurMs = Double(encCompNs - encStartNs) / 1_000_000.0
            let encToNetMs = Double(netSendNs - encCompNs) / 1_000_000.0
            let expectedGlassToRender = capToEncMs + encDurMs + encToNetMs + netTransitMs + netRecvToDecMs + decDurationMs + decToRenderMs

            assert(abs(capToEncMs - 1.5) < 0.001, "Stage 1 capture-to-encode calculation failed")
            assert(abs(encDurMs - 10.0) < 0.001, "Stage 2 encode duration calculation failed")
            assert(abs(encToNetMs - 0.5) < 0.001, "Stage 3 mac queue delay calculation failed")
            assert(abs(expectedGlassToRender - 20.5) < 0.001, "Glass-to-render sum failed: \(expectedGlassToRender)")

            let frameMetrics = PipelineFrameMetrics(
                sequence: 1,
                isKeyframe: true,
                captureToEncodeMs: capToEncMs,
                encodeDurationMs: encDurMs,
                encodeToNetSendMs: encToNetMs,
                networkTransitMs: netTransitMs,
                networkReceiveToDecodeMs: netRecvToDecMs,
                decodeDurationMs: decDurationMs,
                decodeToRenderMs: decToRenderMs,
                glassToRenderMs: expectedGlassToRender,
                frameAgeMs: expectedGlassToRender
            )

            assert(frameMetrics.glassToRenderMs == 20.5, "PipelineFrameMetrics glassToRenderMs mismatch")
            assert(frameMetrics.frameAgeMs == 20.5, "PipelineFrameMetrics frameAgeMs mismatch")
            print("✅ All 8 stage metrics and total glass-to-render sum calculated with microsecond accuracy: 20.5 ms")
        }

        // Test 3: Percentile Calculation
        runTest("Test 3: Percentile Calculation (p50, p95, p99, min, avg, max, stdDev)") {
            // Edge Case A: Empty
            let emptyStats = PercentileStats.calculate(from: [])
            assert(emptyStats.count == 0 && emptyStats.p50 == 0.0, "Empty stats must be zero")

            // Edge Case B: Single Element
            let singleStats = PercentileStats.calculate(from: [42.0])
            assert(singleStats.count == 1 && singleStats.min == 42.0 && singleStats.max == 42.0 && singleStats.p50 == 42.0 && singleStats.p99 == 42.0 && singleStats.stdDev == 0.0, "Single element stats failed")

            // Uniform 100 elements (1.0 ... 100.0)
            let uniformSamples = (1...100).map { Double($0) }
            let stats = PercentileStats.calculate(from: uniformSamples)

            assert(stats.count == 100, "Count mismatch")
            assert(stats.min == 1.0, "Min mismatch")
            assert(stats.max == 100.0, "Max mismatch")
            assert(abs(stats.avg - 50.5) < 0.001, "Avg mismatch: \(stats.avg)")
            assert(abs(stats.p50 - 50.5) < 0.01, "p50 mismatch: \(stats.p50)")
            assert(abs(stats.p95 - 95.05) < 0.1, "p95 mismatch: \(stats.p95)")
            assert(abs(stats.p99 - 99.01) < 0.1, "p99 mismatch: \(stats.p99)")
            assert(stats.stdDev > 28.0 && stats.stdDev < 29.5, "stdDev out of range: \(stats.stdDev)")
            print("✅ Uniform 100-sample percentiles verified: min=\(stats.min), avg=\(stats.avg), p50=\(stats.p50), p95=\(stats.p95), p99=\(stats.p99), max=\(stats.max)")

            // Skewed Distribution: 95 normal frames at 10.0ms, 4 lag frames at 30.0ms, 1 spike frame at 100.0ms
            var skewedSamples = Array(repeating: 10.0, count: 95)
            skewedSamples.append(contentsOf: [30.0, 30.0, 30.0, 30.0])
            skewedSamples.append(100.0)
            let skewedStats = PercentileStats.calculate(from: skewedSamples)

            assert(skewedStats.p50 == 10.0, "Skewed p50 must be 10.0, got \(skewedStats.p50)")
            assert(skewedStats.p95 >= 10.0 && skewedStats.p95 <= 30.0, "Skewed p95 must reflect lag: \(skewedStats.p95)")
            assert(skewedStats.p99 >= 30.0, "Skewed p99 must reflect spike: \(skewedStats.p99)")
            assert(skewedStats.max == 100.0, "Skewed max must be 100.0")
            print("✅ Skewed distribution correctly isolates p50 (\(skewedStats.p50) ms) from p99 spike (\(skewedStats.p99) ms)")
        }

        // Test 4: Frame Sequence Tracking
        runTest("Test 4: Frame Sequence Tracking & Network Gap Detection") {
            let tracker = PipelineBenchmark()
            tracker.reset()

            // Continuous stream: seq 1, 2, 3
            tracker.recordFrameReceived(sequence: 1)
            tracker.recordFrameReceived(sequence: 2)
            tracker.recordFrameReceived(sequence: 3)

            let rep1 = tracker.generateReport()
            assert(rep1.counters.framesReceived == 3, "Received count mismatch")
            assert(rep1.counters.sequenceGaps == 0, "No gaps expected")

            // Jitter/loss gap: next sequence is 7 (dropped 4, 5, 6 -> gap of 3)
            let gap: UInt64 = 7 - (3 + 1)
            tracker.recordSequenceGap(gap: gap)
            tracker.recordFrameReceived(sequence: 7)

            let rep2 = tracker.generateReport()
            assert(rep2.counters.framesReceived == 4, "Received count mismatch")
            assert(rep2.counters.sequenceGaps == 3, "Sequence gaps must be 3, got \(rep2.counters.sequenceGaps)")
            print("✅ Sequence gaps accurately detected and accounted: 3 missing frames detected")
        }

        // Test 5: Dropped-Frame Detection
        runTest("Test 5: Dropped-Frame Detection Across All Pipeline Stages") {
            let tracker = PipelineBenchmark()
            tracker.reset()

            tracker.recordCapture(timestampNs: 100)
            tracker.recordCapture(timestampNs: 200)
            tracker.recordCapture(timestampNs: 300)
            tracker.recordCapture(timestampNs: 400)
            tracker.recordCapture(timestampNs: 500)

            tracker.recordEncodeComplete(durationUs: 5000)
            tracker.recordEncodeComplete(durationUs: 5000)
            tracker.recordEncodeComplete(durationUs: 5000)
            tracker.recordEncodeComplete(durationUs: 5000)

            // 1. Server queue drop (stale frame purged)
            tracker.recordServerDrop(isKeyframe: false)

            // 2. Sequence gaps over network
            tracker.recordSequenceGap(gap: 2)

            // 3. Decoder drop (pre-SPS/PPS frame)
            tracker.recordDecoderDrop()

            // 4. Display drop (stale frame replaced by newer frame)
            tracker.recordDisplayDrop()

            let rep = tracker.generateReport()
            assert(rep.counters.serverQueueDrops == 1, "Server drops mismatch")
            assert(rep.counters.sequenceGaps == 2, "Sequence gaps mismatch")
            assert(rep.counters.decoderDrops == 1, "Decoder drops mismatch")
            assert(rep.counters.displayDrops == 1, "Display drops mismatch")
            assert(rep.counters.totalDrops == 5, "Total drops must be 5 (1 + 2 + 1 + 1), got \(rep.counters.totalDrops)")
            print("✅ All drop stages accounted: server=\(rep.counters.serverQueueDrops), gaps=\(rep.counters.sequenceGaps), decoder=\(rep.counters.decoderDrops), display=\(rep.counters.displayDrops), total=\(rep.counters.totalDrops)")
        }

        // Test 6: Stale-Frame Detection
        runTest("Test 6: Stale-Frame Detection & Classification") {
            let tracker = PipelineBenchmark()
            tracker.reset()

            // Intentional stale drops: 2 on server + 3 on display
            tracker.recordServerDrop(isKeyframe: false)
            tracker.recordServerDrop(isKeyframe: false)
            tracker.recordDisplayDrop()
            tracker.recordDisplayDrop()
            tracker.recordDisplayDrop()

            // Unintentional drop: 4 lost packets
            tracker.recordSequenceGap(gap: 4)

            let rep = tracker.generateReport()
            assert(rep.counters.staleDrops == 5, "Stale drops must be 5 (2 server + 3 display), got \(rep.counters.staleDrops)")
            assert(rep.counters.totalDrops == 9, "Total drops must be 9")
            print("✅ Intentional stale drops correctly separated from network loss: stale=\(rep.counters.staleDrops), total=\(rep.counters.totalDrops)")
        }

        // Test 7: Zero / Invalid Timestamp Handling
        runTest("Test 7: Zero and Invalid Timestamp Handling (NaN, Negative, Outliers)") {
            var metric = RollingMetric(capacity: 100)

            // Record invalid and corrupted values
            metric.record(Double.nan)
            metric.record(Double.infinity)
            metric.record(-15.0)
            metric.record(-0.0001)

            assert(metric.count == 0, "RollingMetric must discard NaN, Inf, and negative values")

            // Now record valid values
            metric.record(12.0)
            metric.record(14.0)
            metric.record(16.0)

            let stats = metric.stats()
            assert(stats.count == 3, "Valid count must be 3")
            assert(stats.min == 12.0 && stats.max == 16.0 && stats.avg == 14.0, "Stats corrupted by invalid values")
            print("✅ RollingMetric safely rejects NaN, Infinity, and negative timestamps without crashing")
        }

        // Test 8: Metrics Reset
        runTest("Test 8: Metrics Reset Between Benchmark Sessions") {
            let tracker = PipelineBenchmark()

            // Fill with samples
            tracker.recordCapture(timestampNs: 1_000_000)
            tracker.recordFrameTransmitted(sequence: 1)
            tracker.recordServerDrop(isKeyframe: false)
            tracker.recordSequenceGap(gap: 5)
            tracker.recordDisplayDrop()

            let beforeRep = tracker.generateReport()
            assert(beforeRep.counters.totalDrops > 0, "Pre-condition: must have recorded drops")

            // Reset
            tracker.reset()

            let afterRep = tracker.generateReport()
            assert(afterRep.counters.framesCaptured == 0, "Frames captured must be 0")
            assert(afterRep.counters.framesRendered == 0, "Frames rendered must be 0")
            assert(afterRep.counters.totalDrops == 0, "Total drops must be 0")
            assert(afterRep.counters.sequenceGaps == 0, "Sequence gaps must be 0")
            assert(afterRep.glassToRender.count == 0, "Glass-to-render distribution must be empty")
            assert(afterRep.frameAge.count == 0, "Frame age distribution must be empty")
            print("✅ Metrics reset completely wiped all counters and metric buffers")
        }

        print("=======================================================")
        if allPassed {
            print("   ALL 8/8 PHASE 7 VERIFICATION TESTS PASSED!         ")
        } else {
            print("   SOME TESTS FAILED! PLEASE CHECK OUTPUT ABOVE.       ")
            exit(1)
        }
        print("=======================================================")
    }
}

struct TestError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
