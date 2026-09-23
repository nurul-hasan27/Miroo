//
//  Phase9Tests.swift
//  MirooTests
//
//  Phase 9: Automated Verification Suite for Centralized Adaptive Streaming & Latency Control.
//

import Foundation
import QuartzCore
@testable import MirooNetworking

@main
struct Phase9Tests {
    static func main() {
        print("==================================================================")
        print("     Miroo Phase 9: Adaptive Streaming Verification Suite        ")
        print("==================================================================")
        print("")

        test1_StaleFrameDroppingPolicy()
        test2_QueueDepthLimits()
        test3_BitrateIncreaseLogic()
        test4_BitrateReductionLogic()
        test5_HysteresisAndAntiOscillation()
        test6_FPSAdaptation()
        test7_RecoveryBehavior()
        test8_KeyframeRequestCooldown()
        test9_USBPolicy()
        test10_UDPPolicy()
        test11_TCPPolicy()
        test12_AdaptiveFeedbackSerialization()

        print("")
        print("==================================================================")
        print("🎉 ALL 12 PHASE 9 AUTOMATED VERIFICATION TESTS PASSED SUCCESSFULLY!")
        print("==================================================================")
    }

    // MARK: - Test 1: Stale Frame Dropping Policy
    static func test1_StaleFrameDroppingPolicy() {
        print("[Test 1] Stale Frame Dropping Policy (Low-Latency Guard)...")
        let policy = FrameDropPolicy(maxAcceptableAgeMs: 50.0, maxQueueDepth: 1)

        // 1. Fresh delta frame (< 50ms) should NOT be dropped
        assert(!policy.shouldDrop(frameAgeMs: 16.0, queueDepth: 0, isKeyframe: false),
               "Fresh delta frame must be kept")

        // 2. Stale delta frame (> 50ms) MUST be dropped to prevent bufferbloat
        assert(policy.shouldDrop(frameAgeMs: 75.0, queueDepth: 0, isKeyframe: false),
               "Stale delta frame (>50ms) must be dropped")

        // 3. Keyframes MUST NEVER be dropped regardless of age to protect reference frames
        assert(!policy.shouldDrop(frameAgeMs: 250.0, queueDepth: 3, isKeyframe: true),
               "Keyframes must never be dropped by frame drop policy")

        // 4. Delta frame in bloated queue (> maxQueueDepth) must be dropped
        assert(policy.shouldDrop(frameAgeMs: 20.0, queueDepth: 2, isKeyframe: false),
               "Delta frame in bloated queue must be dropped")

        print("  ✓ Stale delta frames dropped, fresh frames kept, keyframes strictly protected.")
    }

    // MARK: - Test 2: Queue Depth Limits (No Bufferbloat)
    static func test2_QueueDepthLimits() {
        print("[Test 2] Queue Depth Limits (Target 0-1 Frame Depth)...")
        let queue = FrameQueue(maxDepth: 1)

        assert(queue.currentDepth == 0, "Initial depth must be 0")

        let frame1 = QueuedFrame(sequence: 1, pts: 1000, isKeyframe: false, data: Data([0x01]))
        let accepted1 = queue.enqueue(frame1)
        assert(accepted1 && queue.currentDepth == 1, "Frame 1 must be accepted into queue (depth 1)")

        // Enqueueing frame 2 when maxDepth is 1 should drop older delta frame (Newest Frame Wins)
        let frame2 = QueuedFrame(sequence: 2, pts: 2000, isKeyframe: false, data: Data([0x02]))
        let accepted2 = queue.enqueue(frame2)
        assert(accepted2, "Frame 2 must be accepted via newest-frame replacement")
        assert(queue.currentDepth == 1, "Queue depth must remain capped at 1")
        assert(queue.totalDropped == 1, "Old frame 1 must be recorded as dropped")

        // Enqueueing a keyframe must purge any pending delta frame
        let keyframe = QueuedFrame(sequence: 3, pts: 3000, isKeyframe: true, data: Data([0x03]))
        let acceptedKey = queue.enqueue(keyframe)
        assert(acceptedKey && queue.currentDepth == 1, "Keyframe must replace pending delta")
        assert(queue.totalDropped == 2, "Second delta frame must be recorded as dropped")

        let popped = queue.dequeue()
        assert(popped?.sequence == 3 && popped?.isKeyframe == true, "Popped frame must be the keyframe")
        assert(queue.currentDepth == 0, "Queue must be empty after dequeue")

        print("  ✓ Strict 0-1 queue depth enforced with newest-frame-wins drop policy.")
    }

    // MARK: - Test 3: Bitrate Increase Logic
    static func test3_BitrateIncreaseLogic() {
        print("[Test 3] Bitrate Increase Logic (Good Conditions)...")
        let config = AdaptiveConfiguration(
            minBitrate: 2_000_000,
            initialBitrate: 4_000_000,
            maxBitrate: 8_000_000,
            bitrateIncreaseStep: 500_000,
            recoveryDurationSeconds: 1.0,
            evaluationIntervalSeconds: 0.1
        )
        let controller = AdaptiveStreamingController(config: config)
        assert(controller.currentBitrate == 4_000_000, "Initial bitrate should match config")

        // Simulate sustained healthy UDP link (low RTT, zero loss)
        var time = 100.0
        let snapshot1 = StreamingMetricsSnapshot(
            transportType: .udp,
            rttMs: 12.0,
            oneWayTransitMs: 6.0,
            packetLossRate: 0.0,
            sequenceGaps: 0,
            queueDepth: 0,
            currentFPS: 60.0,
            timestamp: time
        )
        controller.evaluate(metrics: snapshot1)

        // Advance time past recovery duration (1.0s)
        time += 1.2
        let snapshot2 = StreamingMetricsSnapshot(
            transportType: .udp,
            rttMs: 11.0,
            oneWayTransitMs: 5.5,
            packetLossRate: 0.0,
            sequenceGaps: 0,
            queueDepth: 0,
            currentFPS: 60.0,
            timestamp: time
        )
        let decision = controller.evaluate(metrics: snapshot2)

        assert(decision.targetBitrate == 4_500_000, "Bitrate should increase by step (+500k) to 4.5M, got \(decision.targetBitrate)")
        print("  ✓ Bitrate increased gracefully under sustained healthy network conditions.")
    }

    // MARK: - Test 4: Bitrate Reduction Logic
    static func test4_BitrateReductionLogic() {
        print("[Test 4] Bitrate Reduction Logic (Congestion Response)...")
        let config = AdaptiveConfiguration(
            minBitrate: 2_000_000,
            initialBitrate: 8_000_000,
            bitrateDecreaseFactor: 0.75, // 25% cut
            evaluationIntervalSeconds: 0.1
        )
        let controller = AdaptiveStreamingController(config: config)

        // Introduce RTT spike (50ms > 35ms threshold)
        let congestedSnapshot = StreamingMetricsSnapshot(
            transportType: .udp,
            rttMs: 50.0,
            packetLossRate: 0.03, // 3% loss
            sequenceGaps: 2,
            queueDepth: 0,
            currentFPS: 60.0,
            timestamp: 200.0
        )
        let decision = controller.evaluate(metrics: congestedSnapshot)

        assert(decision.state == .congested, "State must transition to .congested")
        assert(decision.targetBitrate == 6_000_000, "Bitrate must immediately cut by 25% (8M -> 6M), got \(decision.targetBitrate)")
        assert(decision.shouldDropStaleFrames == true, "Stale frame dropping must be active")

        print("  ✓ Bitrate cut rapidly without delay upon congestion detection.")
    }

    // MARK: - Test 5: Hysteresis and Anti-Oscillation
    static func test5_HysteresisAndAntiOscillation() {
        print("[Test 5] Hysteresis & Anti-Oscillation (Asymmetric Fast-Down / Slow-Up)...")
        let config = AdaptiveConfiguration(
            minBitrate: 2_000_000,
            initialBitrate: 6_000_000,
            bitrateIncreaseStep: 500_000,
            bitrateDecreaseFactor: 0.75,
            recoveryDurationSeconds: 1.5,
            evaluationIntervalSeconds: 0.2
        )
        let controller = AdaptiveStreamingController(config: config)

        var t = 300.0

        // 1. Congestion strikes
        let cong = StreamingMetricsSnapshot(transportType: .udp, rttMs: 45.0, timestamp: t)
        controller.evaluate(metrics: cong)
        let reducedBitrate = controller.currentBitrate
        assert(reducedBitrate == 4_500_000, "Bitrate immediately reduced to 4.5M")

        // 2. Next moment: 1 healthy sample arrives 200ms later (shorter than recovery window of 1.5s)
        t += 0.3
        let briefHealthy = StreamingMetricsSnapshot(transportType: .udp, rttMs: 15.0, timestamp: t)
        let dec2 = controller.evaluate(metrics: briefHealthy)

        // Anti-oscillation rule: Must NOT immediately increase bitrate on a single isolated healthy sample!
        assert(dec2.targetBitrate == reducedBitrate,
               "Bitrate must NOT immediately increase; must observe stability during recovery period")
        assert(dec2.state == .recovering, "State must be .recovering")

        print("  ✓ Anti-oscillation hysteresis verified: prevents erratic bitrate jumping.")
    }

    // MARK: - Test 6: FPS Adaptation
    static func test6_FPSAdaptation() {
        print("[Test 6] Dynamic FPS Adaptation (60 -> 45 -> 30)...")
        let config = AdaptiveConfiguration(
            minFPS: 30,
            targetFPS: 60,
            maxFPS: 60,
            rttCongestionThresholdMs: 35.0,
            rttSevereCongestionThresholdMs: 60.0,
            evaluationIntervalSeconds: 0.1
        )
        let controller = AdaptiveStreamingController(config: config)
        assert(controller.currentTargetFPS == 60, "Initial target FPS must be 60")

        // 1. Moderate congestion (RTT = 42ms > 35ms)
        let modCong = StreamingMetricsSnapshot(transportType: .udp, rttMs: 42.0, timestamp: 400.0)
        let decMod = controller.evaluate(metrics: modCong)
        assert(decMod.targetFPS == 45, "Moderate congestion should reduce target FPS to 45, got \(decMod.targetFPS)")

        // 2. Severe congestion (RTT = 75ms > 60ms)
        let severeCong = StreamingMetricsSnapshot(transportType: .udp, rttMs: 75.0, timestamp: 400.3)
        let decSev = controller.evaluate(metrics: severeCong)
        assert(decSev.targetFPS == 30, "Severe congestion should reduce target FPS to 30, got \(decSev.targetFPS)")

        print("  ✓ FPS throttled dynamically across 60 -> 45 -> 30 tiers under rising congestion.")
    }

    // MARK: - Test 7: Recovery Behavior
    static func test7_RecoveryBehavior() {
        print("[Test 7] Recovery Behavior (Restoring Framerate and Bitrate)...")
        let config = AdaptiveConfiguration(
            minBitrate: 2_000_000,
            initialBitrate: 6_000_000,
            bitrateIncreaseStep: 500_000,
            recoveryDurationSeconds: 1.0,
            evaluationIntervalSeconds: 0.2
        )
        let controller = AdaptiveStreamingController(config: config)

        // Drive into severe congestion
        var t = 500.0
        let severe = StreamingMetricsSnapshot(transportType: .udp, rttMs: 80.0, packetLossRate: 0.10, timestamp: t)
        controller.evaluate(metrics: severe)
        assert(controller.state == .congested && controller.currentTargetFPS == 30, "Must be congested at 30 FPS")

        // Supply sustained healthy samples past recovery window
        t += 0.3
        controller.evaluate(metrics: StreamingMetricsSnapshot(transportType: .udp, rttMs: 12.0, timestamp: t))
        assert(controller.state == .recovering, "Must transition to .recovering")

        // Advance 1.2s past recovery duration
        t += 1.2
        let recDecision = controller.evaluate(metrics: StreamingMetricsSnapshot(transportType: .udp, rttMs: 12.0, timestamp: t))

        assert(recDecision.targetFPS >= 45, "FPS must step up toward 60 during recovery")
        assert(recDecision.targetBitrate > config.minBitrate, "Bitrate must climb upward")

        print("  ✓ System successfully recovered from degraded state to healthy streaming.")
    }

    // MARK: - Test 8: Keyframe Request Cooldown
    static func test8_KeyframeRequestCooldown() {
        print("[Test 8] Keyframe Request Debouncer (Storm Prevention)...")
        let debouncer = KeyframeDebouncer(cooldownSeconds: 0.500) // 500ms cooldown

        // First request at t=10.0: Granted
        assert(debouncer.shouldRequest(currentTime: 10.0), "Initial keyframe request must be granted")

        // Second request at t=10.05 (50ms later): REJECTED by cooldown
        assert(!debouncer.shouldRequest(currentTime: 10.05), "Keyframe request within cooldown must be suppressed")

        // Third request at t=10.30 (300ms later): REJECTED by cooldown
        assert(!debouncer.shouldRequest(currentTime: 10.30), "Keyframe request within cooldown must be suppressed")

        // Fourth request at t=10.55 (550ms later > 500ms): Granted
        assert(debouncer.shouldRequest(currentTime: 10.55), "Keyframe request after cooldown must be granted")

        assert(debouncer.totalRequestsAttempted == 4, "Total attempted should be 4")
        assert(debouncer.totalRequestsGranted == 2, "Total granted should be 2")

        print("  ✓ Keyframe storm prevented: 4 rapid requests safely debounced to 2.")
    }

    // MARK: - Test 9: USB Policy
    static func test9_USBPolicy() {
        print("[Test 9] Native USB Policy (Zero-Wi-Fi Interference)...")
        let config = AdaptiveConfiguration(
            initialBitrate: 8_000_000,
            maxBitrate: 12_000_000,
            bitrateIncreaseStep: 1_000_000,
            evaluationIntervalSeconds: 0.1
        )
        let controller = AdaptiveStreamingController(config: config)

        let usbMetrics = StreamingMetricsSnapshot(
            transportType: .usb,
            rttMs: 1.2,
            queueDepth: 0,
            currentFPS: 60.0,
            timestamp: 600.0
        )
        let dec = controller.evaluate(metrics: usbMetrics)

        assert(dec.state == .stable, "USB state must remain .stable")
        assert(dec.targetFPS == 60, "USB must maintain full 60 FPS")
        assert(dec.targetBitrate >= 8_000_000, "USB must target high bitrate")

        print("  ✓ USB transport prioritizes maximal responsiveness and 60 FPS.")
    }

    // MARK: - Test 10: UDP Policy
    static func test10_UDPPolicy() {
        print("[Test 10] UDP Policy (Loss and Jitter Detection)...")
        let controller = AdaptiveStreamingController()

        // Sequence gaps observed on UDP wire
        let udpGaps = StreamingMetricsSnapshot(
            transportType: .udp,
            rttMs: 25.0,
            packetLossRate: 0.05,
            sequenceGaps: 4,
            queueDepth: 0,
            timestamp: 700.0
        )
        let dec = controller.evaluate(metrics: udpGaps)

        assert(dec.state == .congested, "UDP sequence gaps must trigger .congested state")
        assert(dec.shouldDropStaleFrames == true, "UDP must drop stale frames aggressively")
        assert(dec.reason.contains("UDP congestion"), "Reason must specify UDP congestion")

        print("  ✓ UDP policy correctly identified packet loss and adapted stream parameters.")
    }

    // MARK: - Test 11: TCP Policy
    static func test11_TCPPolicy() {
        print("[Test 11] TCP Policy (Bufferbloat & Head-of-Line Blocking)...")
        let controller = AdaptiveStreamingController()

        // TCP RTT spikes and queue backs up
        let tcpBufferbloat = StreamingMetricsSnapshot(
            transportType: .tcp,
            rttMs: 58.0,
            queueDepth: 2,
            timestamp: 800.0
        )
        let dec = controller.evaluate(metrics: tcpBufferbloat)

        assert(dec.state == .congested, "TCP bufferbloat must trigger .congested state")
        assert(dec.reason.contains("TCP bufferbloat"), "Reason must identify TCP bufferbloat")
        assert(dec.targetFPS <= 45, "Target FPS must be reduced to mitigate head-of-line blocking")

        print("  ✓ TCP policy successfully countered head-of-line blocking and bufferbloat.")
    }

    // MARK: - Test 12: Adaptive Feedback Serialization
    static func test12_AdaptiveFeedbackSerialization() {
        print("[Test 12] Adaptive Feedback Payload Round-Trip Serialization...")
        let original = AdaptiveFeedbackPayload(
            rttMs: 18.5,
            oneWayTransitMs: 2.1,
            jitterMs: 3.4,
            packetLossRate: 0.015,
            sequenceGaps: 2,
            staleDrops: 5,
            decoderDrops: 0,
            displayDrops: 12,
            receiverFPS: 58.4,
            currentFrameAgeMs: 19.8,
            transport: "USB"
        )

        let data = original.serialize()
        assert(!data.isEmpty, "Serialized data must not be empty")

        guard let parsed = AdaptiveFeedbackPayload.deserialize(from: data) else {
            fatalError("Failed to deserialize AdaptiveFeedbackPayload")
        }

        assert(parsed == original, "Parsed payload must match original bit-for-bit")
        assert(parsed.rttMs == 18.5)
        assert(parsed.transport == "USB")
        assert(parsed.displayDrops == 12)

        print("  ✓ Full 11-field telemetry payload serialized and deserialized with 100% precision.")
    }
}
