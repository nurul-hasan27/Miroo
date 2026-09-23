//
//  AdaptiveStreamingController.swift
//  Miroo
//
//  Phase 9: Centralized Adaptive Streaming & Latency Controller.
//  Dynamically regulates bitrate, framerate, frame queue depth, stale-frame dropping,
//  and keyframe recovery based on real-time transport telemetry.
//

import Foundation
import QuartzCore
import os.lock

// MARK: - Adaptive States

public enum AdaptiveState: String, Codable, Sendable {
    case stable     = "Stable"
    case congested  = "Congested"
    case recovering = "Recovering"
}

// MARK: - Configuration

public struct AdaptiveConfiguration: Sendable, Equatable {
    public var minBitrate: Int32
    public var initialBitrate: Int32
    public var maxBitrate: Int32
    
    public var minFPS: Int32
    public var targetFPS: Int32
    public var maxFPS: Int32
    
    public var rttCongestionThresholdMs: Double
    public var rttSevereCongestionThresholdMs: Double
    public var packetLossCongestionThreshold: Double
    public var packetLossSevereThreshold: Double
    
    public var bitrateIncreaseStep: Int32
    public var bitrateDecreaseFactor: Double
    
    public var recoveryDurationSeconds: Double
    public var evaluationIntervalSeconds: Double
    public var keyframeCooldownSeconds: Double
    public var maxAcceptableFrameAgeMs: Double
    public var maxQueueDepth: Int

    public init(
        minBitrate: Int32 = 2_000_000,
        initialBitrate: Int32 = 8_000_000,
        maxBitrate: Int32 = 14_000_000,
        minFPS: Int32 = 30,
        targetFPS: Int32 = 60,
        maxFPS: Int32 = 60,
        rttCongestionThresholdMs: Double = 35.0,
        rttSevereCongestionThresholdMs: Double = 60.0,
        packetLossCongestionThreshold: Double = 0.02,
        packetLossSevereThreshold: Double = 0.08,
        bitrateIncreaseStep: Int32 = 500_000,
        bitrateDecreaseFactor: Double = 0.75,
        recoveryDurationSeconds: Double = 1.5,
        evaluationIntervalSeconds: Double = 0.5,
        keyframeCooldownSeconds: Double = 0.500,
        maxAcceptableFrameAgeMs: Double = 50.0,
        maxQueueDepth: Int = 1
    ) {
        self.minBitrate = minBitrate
        self.initialBitrate = initialBitrate
        self.maxBitrate = maxBitrate
        self.minFPS = minFPS
        self.targetFPS = targetFPS
        self.maxFPS = maxFPS
        self.rttCongestionThresholdMs = rttCongestionThresholdMs
        self.rttSevereCongestionThresholdMs = rttSevereCongestionThresholdMs
        self.packetLossCongestionThreshold = packetLossCongestionThreshold
        self.packetLossSevereThreshold = packetLossSevereThreshold
        self.bitrateIncreaseStep = bitrateIncreaseStep
        self.bitrateDecreaseFactor = bitrateDecreaseFactor
        self.recoveryDurationSeconds = recoveryDurationSeconds
        self.evaluationIntervalSeconds = evaluationIntervalSeconds
        self.keyframeCooldownSeconds = keyframeCooldownSeconds
        self.maxAcceptableFrameAgeMs = maxAcceptableFrameAgeMs
        self.maxQueueDepth = maxQueueDepth
    }
}

// MARK: - Telemetry Inputs

public struct StreamingMetricsSnapshot: Sendable {
    public let transportType: VideoTransportType
    public let rttMs: Double
    public let oneWayTransitMs: Double
    public let packetLossRate: Double
    public let sequenceGaps: UInt64
    public let queueDepth: Int
    public let frameDrops: UInt64
    public let currentFPS: Double
    public let timestamp: CFTimeInterval

    public init(
        transportType: VideoTransportType,
        rttMs: Double,
        oneWayTransitMs: Double = 0.0,
        packetLossRate: Double = 0.0,
        sequenceGaps: UInt64 = 0,
        queueDepth: Int = 0,
        frameDrops: UInt64 = 0,
        currentFPS: Double = 60.0,
        timestamp: CFTimeInterval = CACurrentMediaTime()
    ) {
        self.transportType = transportType
        self.rttMs = rttMs
        self.oneWayTransitMs = oneWayTransitMs
        self.packetLossRate = packetLossRate
        self.sequenceGaps = sequenceGaps
        self.queueDepth = queueDepth
        self.frameDrops = frameDrops
        self.currentFPS = currentFPS
        self.timestamp = timestamp
    }
}

// MARK: - Controller Decisions

public struct AdaptiveDecision: Sendable, Equatable {
    public let state: AdaptiveState
    public let targetBitrate: Int32
    public let targetFPS: Int32
    public let maxQueueDepth: Int
    public let shouldDropStaleFrames: Bool
    public let reason: String

    public init(
        state: AdaptiveState,
        targetBitrate: Int32,
        targetFPS: Int32,
        maxQueueDepth: Int,
        shouldDropStaleFrames: Bool,
        reason: String
    ) {
        self.state = state
        self.targetBitrate = targetBitrate
        self.targetFPS = targetFPS
        self.maxQueueDepth = maxQueueDepth
        self.shouldDropStaleFrames = shouldDropStaleFrames
        self.reason = reason
    }
}

// MARK: - Keyframe Request Debouncer

public final class KeyframeDebouncer: @unchecked Sendable {
    public let cooldownSeconds: Double
    private var lastRequestTime: CFTimeInterval = 0
    private var lock = os_unfair_lock_s()

    public private(set) var totalRequestsAttempted: UInt64 = 0
    public private(set) var totalRequestsGranted: UInt64 = 0

    public init(cooldownSeconds: Double = 0.500) {
        self.cooldownSeconds = cooldownSeconds
    }

    /// Evaluates whether a keyframe request should be permitted under the cooldown limit.
    public func shouldRequest(currentTime: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        totalRequestsAttempted += 1
        let elapsed = currentTime - lastRequestTime
        if lastRequestTime == 0 || elapsed >= cooldownSeconds {
            lastRequestTime = currentTime
            totalRequestsGranted += 1
            return true
        }
        return false
    }

    /// Resets the debouncer cooldown immediately (e.g. on manual re-connect or resolution change).
    public func reset() {
        os_unfair_lock_lock(&lock)
        lastRequestTime = 0
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - Frame Dropping Policy

public struct FrameDropPolicy: Sendable {
    public let maxAcceptableAgeMs: Double
    public let maxQueueDepth: Int

    public init(maxAcceptableAgeMs: Double = 50.0, maxQueueDepth: Int = 1) {
        self.maxAcceptableAgeMs = maxAcceptableAgeMs
        self.maxQueueDepth = max(1, maxQueueDepth)
    }

    /// Evaluates if an unrendered delta frame is stale and should be discarded.
    /// Keyframes are NEVER discarded because they establish the decoding reference base.
    public func shouldDrop(frameAgeMs: Double, queueDepth: Int, isKeyframe: Bool) -> Bool {
        if isKeyframe {
            return false
        }
        if queueDepth > maxQueueDepth {
            return true
        }
        if frameAgeMs > maxAcceptableAgeMs {
            return true
        }
        return false
    }
}

// MARK: - Centralized Adaptive Streaming Controller

public final class AdaptiveStreamingController: @unchecked Sendable {

    public let config: AdaptiveConfiguration
    public let keyframeDebouncer: KeyframeDebouncer
    public let frameDropPolicy: FrameDropPolicy

    private var lock = os_unfair_lock_s()

    // Dynamic State
    public private(set) var state: AdaptiveState = .stable
    public private(set) var currentBitrate: Int32
    public private(set) var currentTargetFPS: Int32
    public private(set) var lastDecision: AdaptiveDecision

    private var lastEvaluationTime: CFTimeInterval = 0
    private var healthyStateStartTime: CFTimeInterval = 0
    private var lastObservedSequenceGaps: UInt64 = 0
    private var lastObservedFrameDrops: UInt64 = 0

    public init(config: AdaptiveConfiguration = AdaptiveConfiguration()) {
        self.config = config
        self.currentBitrate = config.initialBitrate
        self.currentTargetFPS = config.targetFPS
        self.keyframeDebouncer = KeyframeDebouncer(cooldownSeconds: config.keyframeCooldownSeconds)
        self.frameDropPolicy = FrameDropPolicy(
            maxAcceptableAgeMs: config.maxAcceptableFrameAgeMs,
            maxQueueDepth: config.maxQueueDepth
        )
        self.lastDecision = AdaptiveDecision(
            state: .stable,
            targetBitrate: config.initialBitrate,
            targetFPS: config.targetFPS,
            maxQueueDepth: config.maxQueueDepth,
            shouldDropStaleFrames: true,
            reason: "Initial baseline"
        )
    }

    /// Evaluates real-time telemetry snapshot and determines adaptive streaming actions.
    @discardableResult
    public func evaluate(metrics: StreamingMetricsSnapshot) -> AdaptiveDecision {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let now = metrics.timestamp
        let timeSinceLastEval = (lastEvaluationTime > 0) ? (now - lastEvaluationTime) : config.evaluationIntervalSeconds

        // Respect evaluation interval unless immediate severe congestion is reported
        let gapDiff = metrics.sequenceGaps >= lastObservedSequenceGaps ? (metrics.sequenceGaps - lastObservedSequenceGaps) : 0
        let dropDiff = metrics.frameDrops >= lastObservedFrameDrops ? (metrics.frameDrops - lastObservedFrameDrops) : 0
        lastObservedSequenceGaps = metrics.sequenceGaps
        lastObservedFrameDrops = metrics.frameDrops

        let isSevereCongestion = metrics.rttMs > config.rttSevereCongestionThresholdMs || metrics.packetLossRate > config.packetLossSevereThreshold || metrics.queueDepth >= 2

        if timeSinceLastEval < config.evaluationIntervalSeconds && !isSevereCongestion {
            return lastDecision
        }
        lastEvaluationTime = now

        // --- TRANSPORT-SPECIFIC POLICIES ---
        switch metrics.transportType {
        case .usb:
            evaluateUSBPolicy(metrics: metrics, now: now, queueDepth: metrics.queueDepth)

        case .udp:
            evaluateUDPPolicy(metrics: metrics, now: now, gapCount: gapDiff, dropCount: dropDiff)

        case .tcp:
            evaluateTCPPolicy(metrics: metrics, now: now, dropCount: dropDiff)
        }

        return lastDecision
    }

    // MARK: - USB Transport Policy
    // Prioritize maximum responsiveness, stable high bitrate, 60 FPS, minimal buffering.
    // Dedicated physical wire: bypass Wi-Fi congestion and airtime contention heuristics.
    private func evaluateUSBPolicy(metrics: StreamingMetricsSnapshot, now: CFTimeInterval, queueDepth: Int) {
        if queueDepth >= 2 {
            // Rare host encode backlog
            currentBitrate = max(config.minBitrate, Int32(Double(currentBitrate) * 0.85))
            state = .congested
            healthyStateStartTime = 0
            lastDecision = AdaptiveDecision(
                state: .congested,
                targetBitrate: currentBitrate,
                targetFPS: config.targetFPS, // USB stays 60 FPS
                maxQueueDepth: 1,
                shouldDropStaleFrames: true,
                reason: "USB host queue depth backlog (\(queueDepth))"
            )
        } else {
            // Healthy USB streaming: target maximum quality at 60 FPS
            if currentBitrate < config.maxBitrate {
                currentBitrate = min(config.maxBitrate, currentBitrate + config.bitrateIncreaseStep)
            }
            currentTargetFPS = config.maxFPS
            state = .stable
            lastDecision = AdaptiveDecision(
                state: .stable,
                targetBitrate: currentBitrate,
                targetFPS: currentTargetFPS,
                maxQueueDepth: 1,
                shouldDropStaleFrames: true,
                reason: "USB transport stable high-speed tunnel"
            )
        }
    }

    // MARK: - UDP Transport Policy
    // Prioritize lowest latency, detect packet loss & sequence gaps, aggressively drop stale frames,
    // and trigger debounced keyframe recovery.
    private func evaluateUDPPolicy(
        metrics: StreamingMetricsSnapshot,
        now: CFTimeInterval,
        gapCount: UInt64,
        dropCount: UInt64
    ) {
        let hasLoss = metrics.packetLossRate > config.packetLossCongestionThreshold || gapCount > 0
        let hasHighRTT = metrics.rttMs > config.rttCongestionThresholdMs
        let hasSevereRTT = metrics.rttMs > config.rttSevereCongestionThresholdMs
        let isCongested = hasLoss || hasHighRTT || metrics.queueDepth >= 1

        if isCongested {
            // Rapid Bitrate Reduction (Fast-down)
            let previousBitrate = currentBitrate
            let reduced = Int32(Double(currentBitrate) * config.bitrateDecreaseFactor)
            currentBitrate = max(config.minBitrate, reduced)

            // FPS Adaptation under moderate/severe congestion
            if hasSevereRTT || metrics.packetLossRate > config.packetLossSevereThreshold {
                currentTargetFPS = config.minFPS // 30 FPS
            } else if hasHighRTT || metrics.packetLossRate > config.packetLossCongestionThreshold {
                currentTargetFPS = 45 // 45 FPS intermediate tier
            }

            state = .congested
            healthyStateStartTime = 0

            lastDecision = AdaptiveDecision(
                state: .congested,
                targetBitrate: currentBitrate,
                targetFPS: currentTargetFPS,
                maxQueueDepth: 1,
                shouldDropStaleFrames: true,
                reason: "UDP congestion: loss=\(String(format: "%.1f%%", metrics.packetLossRate * 100)), RTT=\(String(format: "%.1f", metrics.rttMs))ms, gaps=\(gapCount), bitrate \(previousBitrate/1_000_000)M -> \(currentBitrate/1_000_000)M"
            )
        } else {
            // Conditions are healthy: Apply Hysteresis & Gradual Recovery (Slow-up)
            if healthyStateStartTime == 0 {
                healthyStateStartTime = now
                state = .recovering
            }

            let healthyDuration = now - healthyStateStartTime

            if healthyDuration >= config.recoveryDurationSeconds {
                // Recover FPS first toward 60 FPS
                if currentTargetFPS < 45 {
                    currentTargetFPS = 45
                } else if currentTargetFPS < config.maxFPS {
                    currentTargetFPS = config.maxFPS
                }

                // Slowly increase bitrate in conservative increments up to maxBitrate
                if currentBitrate < config.maxBitrate {
                    currentBitrate = min(config.maxBitrate, currentBitrate + config.bitrateIncreaseStep)
                }

                if currentBitrate >= config.initialBitrate && currentTargetFPS >= config.maxFPS {
                    state = .stable
                } else {
                    state = .recovering
                }

                lastDecision = AdaptiveDecision(
                    state: state,
                    targetBitrate: currentBitrate,
                    targetFPS: currentTargetFPS,
                    maxQueueDepth: 1,
                    shouldDropStaleFrames: true,
                    reason: "UDP recovery: sustained healthy for \(String(format: "%.1f", healthyDuration))s, bitrate=\(Double(currentBitrate)/1_000_000.0)M, fps=\(currentTargetFPS)"
                )
            } else {
                state = .recovering
                lastDecision = AdaptiveDecision(
                    state: .recovering,
                    targetBitrate: currentBitrate,
                    targetFPS: currentTargetFPS,
                    maxQueueDepth: 1,
                    shouldDropStaleFrames: true,
                    reason: "UDP recovering: observing link stability (\(String(format: "%.1f", healthyDuration))s / \(config.recoveryDurationSeconds)s)"
                )
            }
        }
    }

    // MARK: - TCP Transport Policy
    // Prioritize reliability, detect head-of-line blocking (RTT spikes & queue buildup),
    // prevent accumulated stale frames from being rendered late, and drop stale delta frames.
    private func evaluateTCPPolicy(
        metrics: StreamingMetricsSnapshot,
        now: CFTimeInterval,
        dropCount: UInt64
    ) {
        let hasBufferBloat = metrics.rttMs > config.rttCongestionThresholdMs || metrics.queueDepth >= 1

        if hasBufferBloat {
            // TCP Head-of-line blocking detected
            currentBitrate = max(config.minBitrate, Int32(Double(currentBitrate) * config.bitrateDecreaseFactor))

            if metrics.rttMs > config.rttSevereCongestionThresholdMs {
                currentTargetFPS = config.minFPS // 30 FPS
            } else {
                currentTargetFPS = 45
            }

            state = .congested
            healthyStateStartTime = 0

            lastDecision = AdaptiveDecision(
                state: .congested,
                targetBitrate: currentBitrate,
                targetFPS: currentTargetFPS,
                maxQueueDepth: 1,
                shouldDropStaleFrames: true,
                reason: "TCP bufferbloat detected: RTT=\(String(format: "%.1f", metrics.rttMs))ms, queue=\(metrics.queueDepth)"
            )
        } else {
            // TCP link healthy
            if healthyStateStartTime == 0 {
                healthyStateStartTime = now
                state = .recovering
            }

            let healthyDuration = now - healthyStateStartTime

            if healthyDuration >= config.recoveryDurationSeconds {
                if currentTargetFPS < config.maxFPS {
                    currentTargetFPS = min(config.maxFPS, currentTargetFPS + 15)
                }
                if currentBitrate < config.maxBitrate {
                    currentBitrate = min(config.maxBitrate, currentBitrate + config.bitrateIncreaseStep)
                }

                if currentBitrate >= config.initialBitrate && currentTargetFPS >= config.maxFPS {
                    state = .stable
                } else {
                    state = .recovering
                }

                lastDecision = AdaptiveDecision(
                    state: state,
                    targetBitrate: currentBitrate,
                    targetFPS: currentTargetFPS,
                    maxQueueDepth: 1,
                    shouldDropStaleFrames: true,
                    reason: "TCP recovered: RTT low, bitrate=\(Double(currentBitrate)/1_000_000.0)M, fps=\(currentTargetFPS)"
                )
            } else {
                state = .recovering
                lastDecision = AdaptiveDecision(
                    state: .recovering,
                    targetBitrate: currentBitrate,
                    targetFPS: currentTargetFPS,
                    maxQueueDepth: 1,
                    shouldDropStaleFrames: true,
                    reason: "TCP link observing stability"
                )
            }
        }
    }

    /// Resets all adaptive state back to baseline initial configuration.
    public func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        currentBitrate = config.initialBitrate
        currentTargetFPS = config.targetFPS
        state = .stable
        lastEvaluationTime = 0
        healthyStateStartTime = 0
        lastObservedSequenceGaps = 0
        lastObservedFrameDrops = 0
        keyframeDebouncer.reset()
        lastDecision = AdaptiveDecision(
            state: .stable,
            targetBitrate: config.initialBitrate,
            targetFPS: config.targetFPS,
            maxQueueDepth: config.maxQueueDepth,
            shouldDropStaleFrames: true,
            reason: "Controller reset"
        )
    }
}
