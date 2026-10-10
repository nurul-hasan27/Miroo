import Foundation

/// Sender-side adaptation driven by receiver feedback.
///  * `targetBitrate` – what the encoder is asked to produce. Reduced on *congestion* signals only:
///    queueing delay growth, or frames that FEC could not repair. Plain random packet loss (typical for Wi-Fi)
///    is not congestion: it only raises the FEC parity ratio.
///  * `paceRateBps`   – how fast datagrams may leave. Probes upward only while the pacer is actually the bottleneck.
public final class RateController {
    public struct Limits {
        public var minBitrate = 2_000_000, maxBitrate = 30_000_000, startBitrate = 5_000_000
        public var minPace = 16_000_000.0, maxPace = 400_000_000.0
        public init() {}
    }

    public let limits: Limits
    public private(set) var targetBitrate: Int
    public private(set) var paceRateBps: Double
    public private(set) var lossRate: Double = 0        // packet loss over the last second (pre-FEC)
    public private(set) var rttUs: Double = 0
    public private(set) var queueDelayUs: Double = 0
    public private(set) var standingQueueUs: Double = 0
    public private(set) var decreases = 0
    private var lastDecrease: UInt64 = 0, lastIncrease: UInt64 = 0, lastPaceChange: UInt64 = 0
    private var window: [(t: UInt64, expected: Int, received: Int, framesLost: Int)] = []
    private var backlogSeenSincePaceChange: UInt64 = 0
    private var slowStart = true
    private var recentRecoveries: [UInt64] = []
    private var lastFeedbackUs: UInt64 = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
        targetBitrate = limits.startBitrate
        paceRateBps = max(60_000_000, Double(limits.startBitrate) * 4)
    }

    /// Fraction of extra parity packets to add per frame (callers always add at least one parity packet).
    public var parityRatio: Double { min(0.5, 0.05 + lossRate * 2.5) }

    /// Minimum parity packets per frame. Wi-Fi loss is bursty, so lossy links get extra protection even on tiny frames.
    public var minParity: Int { lossRate > 0.03 ? 4 : lossRate > 0.01 ? 3 : lossRate > 0.002 ? 2 : 1 }
    /// On a clean link tiny frames skip parity entirely (every extra packet costs airtime); repair requests cover the rare hit.
    public func parity(forDataPackets k: Int) -> Int {
        let byRatio = Int((Double(k) * parityRatio).rounded(.up))
        if lossRate < 0.002, k <= 2 { return 0 }
        return max(minParity, byRatio)
    }

    /// - Parameters:
    ///   - sentBitrate: bitrate the encoder actually produced recently (no point raising the target when idle).
    ///   - pacerBacklogUs: how long the oldest datagram waited in the pacer at feedback time.
    ///   - starved: the encoder is dropping frames because its budget is too small for the content.
    public func onFeedback(_ f: Feedback, nowUs: UInt64, rttUs sample: Double?, sentBitrate: Double, pacerBacklogUs: UInt64, starved: Bool = false) {
        lastFeedbackUs = nowUs
        if let s = sample, s > 0 { rttUs = rttUs == 0 ? s : rttUs * 0.85 + s * 0.15 }
        queueDelayUs = Double(f.queueDelayUs)
        backlogSeenSincePaceChange = max(backlogSeenSincePaceChange, pacerBacklogUs)

        window.append((nowUs, Int(f.packetsExpected), Int(f.packetsReceived), Int(f.framesLost)))
        window.removeAll { nowUs &- $0.t > 1_000_000 }
        let exp = window.reduce(0) { $0 + $1.expected }, rec = window.reduce(0) { $0 + $1.received }
        let framesLost = window.reduce(0) { $0 + $1.framesLost }
        lossRate = exp > 20 ? Double(max(0, exp - rec)) / Double(exp) : lossRate * 0.98

        // Congestion = a *standing* queue (min delay over ~100 ms stays high) or frames FEC could not repair.
        // Single jitter spikes (Wi-Fi power-save, retries) raise `queueDelayUs` but not the standing queue.
        let standing = Double(f.standingQueueUs)
        standingQueueUs = standing
        let congested = standing > 15_000 || framesLost >= 4
        let calm = standing < 6_000 && framesLost <= 1

        if congested, nowUs &- lastDecrease > 200_000 {
            lastDecrease = nowUs; decreases += 1; slowStart = false
            // back off toward what actually got through, never below the floor
            let goodput = Double(f.goodputKbps) * 1000
            var t = Double(targetBitrate) * 0.8
            if goodput > 0 { t = min(t, goodput * 0.9) }
            targetBitrate = max(limits.minBitrate, Int(t))
            paceRateBps = max(limits.minPace, paceRateBps * 0.85)
            lastPaceChange = nowUs; backlogSeenSincePaceChange = 0
        } else if calm {
            if nowUs &- lastIncrease > 250_000, (sentBitrate > Double(targetBitrate) * 0.35 || starved) {
                lastIncrease = nowUs
                let g = slowStart ? 1.25 : 1.08
                targetBitrate = min(limits.maxBitrate, Int(Double(targetBitrate) * g) + 100_000)
            }
            if nowUs &- lastPaceChange > 500_000 {
                if backlogSeenSincePaceChange > 1_500 { paceRateBps = min(limits.maxPace, paceRateBps * 1.15) }
                lastPaceChange = nowUs; backlogSeenSincePaceChange = 0
            }
        }
        paceRateBps = max(paceRateBps, Double(targetBitrate) * 2.5)
    }

    /// No feedback for a while while streaming: assume the path collapsed, shrink to the floor.
    public func onSilence(nowUs: UInt64) {
        guard lastFeedbackUs != 0, nowUs &- lastFeedbackUs > 250_000, nowUs &- lastDecrease > 250_000 else { return }
        lastDecrease = nowUs; slowStart = false; decreases += 1
        targetBitrate = max(limits.minBitrate, Int(Double(targetBitrate) * 0.6))
        paceRateBps = max(limits.minPace, paceRateBps * 0.7)
    }

    /// A recovery (keyframe) was needed: repeated recoveries mean the link cannot carry our frames — shrink them.
    public func onRecovery(nowUs: UInt64) {
        recentRecoveries.append(nowUs)
        recentRecoveries.removeAll { nowUs &- $0 > 3_000_000 }
        if recentRecoveries.count >= 3, nowUs &- lastDecrease > 300_000 {
            lastDecrease = nowUs; slowStart = false; decreases += 1
            targetBitrate = max(limits.minBitrate, Int(Double(targetBitrate) * 0.75))
            paceRateBps = max(limits.minPace, paceRateBps * 0.85)
        }
    }
    /// Minimum spacing between recovery frames: grows while recoveries keep happening (storm control).
    /// - Parameters:
    ///   - lastRecoveryBytes: size of the previous recovery frame; a big one needs time to arrive before asking again.
    public func recoveryCooldownUs(rttUs: Double, lastRecoveryBytes: Int = 0) -> UInt64 {
        let n = recentRecoveries.count
        let transit = lastRecoveryBytes > 0 ? Double(lastRecoveryBytes) * 8 / max(paceRateBps, 1_000_000) * 1_000_000 * 2 + rttUs * 3 : 0
        let base = max(90_000.0, rttUs * 3, transit)
        return UInt64(min(1_000_000.0, base * pow(2.0, Double(max(0, n - 2)))))   // doubles only once recoveries pile up
    }

    /// The pacer had to throw queued frames away: the link is slower than we thought.
    public func onFlush(nowUs: UInt64) {
        lastDecrease = nowUs; slowStart = false; decreases += 1
        targetBitrate = max(limits.minBitrate, Int(Double(targetBitrate) * 0.65))
    }
}
