//
//  FrameQueue.swift
//  Miroo
//
//  Phase 4: Thread-safe bounded video frame queue with backpressure policy.
//  Protects against unbounded memory growth, drops stale delta frames during network
//  congestion, and strictly prioritizes fresh frames and keyframes.
//

import Foundation
import QuartzCore
import os.lock

public struct QueuedFrame: Sendable {
    public let sequence: UInt64
    public let pts: Int64
    public let isKeyframe: Bool
    public let data: Data
    public let encodeDurationUs: UInt32
    public let timestamp: CFTimeInterval
    public let captureTimestampNs: UInt64
    public let encodeStartTimestampNs: UInt64
    public let encodeCompleteTimestampNs: UInt64

    public init(
        sequence: UInt64,
        pts: Int64,
        isKeyframe: Bool,
        data: Data,
        encodeDurationUs: UInt32 = 0,
        captureTimestampNs: UInt64 = 0,
        encodeStartTimestampNs: UInt64 = 0,
        encodeCompleteTimestampNs: UInt64 = 0
    ) {
        self.sequence = sequence
        self.pts = pts
        self.isKeyframe = isKeyframe
        self.data = data
        self.encodeDurationUs = encodeDurationUs
        self.timestamp = CACurrentMediaTime()
        self.captureTimestampNs = captureTimestampNs
        self.encodeStartTimestampNs = encodeStartTimestampNs
        self.encodeCompleteTimestampNs = encodeCompleteTimestampNs
    }
}

public final class FrameQueue: @unchecked Sendable {
    public let maxDepth: Int

    private var storage: [QueuedFrame] = []
    private var lock = os_unfair_lock_s()

    // Diagnostics
    private(set) public var totalEnqueued: UInt64 = 0
    private(set) public var totalDequeued: UInt64 = 0
    private(set) public var totalDropped: UInt64 = 0
    private(set) public var droppedKeyframes: UInt64 = 0
    private(set) public var droppedDeltaFrames: UInt64 = 0
    private(set) public var needsImmediateKeyframe: Bool = false

    public init(maxDepth: Int = 1) {
        self.maxDepth = max(1, maxDepth)
    }

    /// Enqueues a video frame. Implements bounded drop-stale backpressure.
    /// Returns true if frame was accepted into queue, false if dropped immediately.
    @discardableResult
    public func enqueue(_ frame: QueuedFrame) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        totalEnqueued += 1

        if frame.isKeyframe {
            needsImmediateKeyframe = false
        }

        if storage.count < maxDepth {
            storage.append(frame)
            return true
        }

        // Backpressure triggered: Queue is at capacity
        if frame.isKeyframe {
            // Priority 1: Keyframes are critical. Purge older delta frames to make room.
            let deltaIndices = storage.indices.filter { !storage[$0].isKeyframe }
            if !deltaIndices.isEmpty {
                // Drop all pending delta frames; a fresh keyframe renders them obsolete
                let droppedCount = deltaIndices.count
                storage.removeAll(where: { !$0.isKeyframe })
                storage.append(frame)
                totalDropped += UInt64(droppedCount)
                droppedDeltaFrames += UInt64(droppedCount)
                return true
            } else {
                // Queue is filled only with keyframes (extremely rare)
                // Drop the oldest keyframe to favor the newest
                storage.removeFirst()
                storage.append(frame)
                totalDropped += 1
                droppedKeyframes += 1
                return true
            }
        } else {
            // Delta frame: Favor freshest frames over old frames (Newest Frame Wins policy).
            // Find the oldest non-keyframe in the queue and replace it.
            if let firstDeltaIndex = storage.firstIndex(where: { !$0.isKeyframe }) {
                storage.remove(at: firstDeltaIndex)
                storage.append(frame)
                totalDropped += 1
                droppedDeltaFrames += 1
                needsImmediateKeyframe = true
                return true
            } else {
                // Queue has a keyframe. Drop this delta frame and signal immediate keyframe requirement.
                totalDropped += 1
                droppedDeltaFrames += 1
                needsImmediateKeyframe = true
                return false
            }
        }
    }

    /// Dequeues the next frame to transmit over the network.
    public func dequeue() -> QueuedFrame? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard !storage.isEmpty else { return nil }
        totalDequeued += 1
        return storage.removeFirst()
    }

    /// Current number of frames buffered.
    public var count: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return storage.count
    }

    /// Returns true if the queue is empty.
    public var isEmpty: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return storage.isEmpty
    }

    /// Explicitly flags that an immediate IDR keyframe is required (e.g. after orientation change or packet loss).
    public func requestImmediateKeyframe() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        needsImmediateKeyframe = true
    }

    /// Clears all queued frames.
    public func clear() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        storage.removeAll()
    }
}
