import Foundation

public enum SequencerAction: Equatable, Sendable {
    /// Hand this frame to the decoder.
    case decode(frameId: UInt32)
    /// The decode chain is broken; ask the sender for a recovery (LTR refresh / IDR) frame.
    case requestRecovery
}

/// Enforces in-order decoding of a predictive stream without ever waiting longer than `holdUs`
/// for a missing frame, and drives loss recovery. Pure logic (no I/O), time is injected.
public final class FrameSequencer {
    public private(set) var expectedNext: UInt32?
    public private(set) var waitingForRecovery = true     // true until the first recovery frame arrives
    private var held: [UInt32: (AssembledFrame, UInt64)] = [:]   // out-of-order complete frames + hold start
    private var gapSince: UInt64?
    private let holdUs: UInt64
    private var highestAnnounced: UInt32?                  // from probe packets / seen frames
    private var tailSince: UInt64?, tailExp: UInt32?

    public init(holdUs: UInt64 = 32_000) { self.holdUs = holdUs }

    @inline(__always) private func isAfter(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }

    /// A completed frame arrived. Returns frames to decode in order (possibly several) and recovery requests.
    public func onFrame(_ f: AssembledFrame, nowUs: UInt64) -> (decode: [AssembledFrame], actions: [SequencerAction]) {
        noteAnnounced(f.frameId)
        var out = [AssembledFrame](), acts = [SequencerAction]()

        if f.flags.contains(.recovery) {
            // Self-sufficient frame: resume right here, drop anything older.
            held = held.filter { isAfter($0.key, f.frameId) }
            expectedNext = f.frameId &+ 1
            waitingForRecovery = false
            gapSince = nil
            out.append(f)
            drain(&out)
            return (out, acts)
        }
        if waitingForRecovery {
            if expectedNext == nil || !isAfter(expectedNext!, f.frameId) { acts.append(.requestRecovery) }
            return (out, acts)
        }
        guard let exp = expectedNext else { return (out, [.requestRecovery]) }
        if f.frameId == exp {
            expectedNext = exp &+ 1
            out.append(f)
            drain(&out)
            if held.isEmpty { gapSince = nil }
        } else if isAfter(f.frameId, exp) {
            if held[f.frameId] == nil { held[f.frameId] = (f, nowUs) }
            if gapSince == nil { gapSince = nowUs }
        } // else: duplicate / stale
        return (out, acts)
    }

    /// A probe or other packet announced that frame `id` exists (detects loss of the stream tail).
    public func noteAnnounced(_ id: UInt32) {
        if highestAnnounced == nil || isAfter(id, highestAnnounced!) { highestAnnounced = id }
    }

    /// Call periodically (every few ms). Declares loss after `holdUs` and requests recovery.
    public func tick(nowUs: UInt64, sawIncomplete: Bool = false) -> [SequencerAction] {
        guard !waitingForRecovery, let exp = expectedNext else { return [] }
        if let g = gapSince, nowUs &- g > holdUs { return declareLoss() }
        // Tail loss: frames >= expectedNext exist (seen or announced by a probe) but expectedNext has not completed
        // for longer than the hold time. The timer restarts whenever expectedNext advances.
        if let hi = highestAnnounced, isAfter(hi, exp &- 1), held.isEmpty {
            if tailExp != exp { tailExp = exp; tailSince = nowUs }
            else if let t = tailSince, nowUs &- t > holdUs { return declareLoss() }
        } else { tailSince = nil; tailExp = nil }
        return []
    }

    /// Frames the assembler abandoned (never completed). Chain is broken if any is >= expectedNext.
    public func onFramesAbandoned(_ ids: [UInt32]) -> [SequencerAction] {
        guard !waitingForRecovery, let exp = expectedNext else { return [] }
        if ids.contains(where: { !isAfter(exp, $0) }) { return declareLoss() }
        return []
    }

    /// Gives up on the current chain immediately (e.g. after an outage longer than the sender keeps repair history).
    public func forceRecovery() -> [SequencerAction] {
        guard expectedNext != nil, !waitingForRecovery else { return [] }
        return declareLoss()
    }

    private func declareLoss() -> [SequencerAction] {
        waitingForRecovery = true
        held.removeAll()
        gapSince = nil; tailSince = nil; tailExp = nil
        return [.requestRecovery]
    }

    private func drain(_ out: inout [AssembledFrame]) {
        while let exp = expectedNext, let h = held.removeValue(forKey: exp) {
            out.append(h.0)
            expectedNext = exp &+ 1
        }
        if held.isEmpty { gapSince = nil }
    }

    public func isHeld(_ id: UInt32) -> Bool { held[id] != nil }
    /// Highest frame id announced by any packet (frames or probes).
    public var highestSeen: UInt32? { highestAnnounced }

    public func reset() {
        expectedNext = nil; waitingForRecovery = true; held.removeAll(); gapSince = nil; highestAnnounced = nil; tailSince = nil; tailExp = nil
    }
}
