import Foundation
import Darwin
import MirooCore

/// UDP proxy emulating a bad Wi-Fi link: random loss, fixed delay + jitter, bandwidth cap with a drop-tail queue.
/// Sender -> proxy(listenPort) -> target(127.0.0.1:targetPort); replies travel back to the sender.
public final class ImpairmentProxy: @unchecked Sendable {
    public struct Profile {
        public var lossPct = 0.0, delayMs = 0.0, jitterMs = 0.0, rateMbps = 0.0 /* 0 = unlimited */, queueMs = 60.0
        public var burstLossPct = 0.0       // probability of starting a 3-packet loss burst
        public var stallMs = 0.0, stallEveryMs = 0.0, stallDrops = true   // periodic blackout; packets inside it are dropped (or delayed until it ends)
        public init(lossPct: Double = 0, delayMs: Double = 0, jitterMs: Double = 0, rateMbps: Double = 0, queueMs: Double = 60, burstLossPct: Double = 0, stallMs: Double = 0, stallEveryMs: Double = 0, stallDrops: Bool = true) {
            self.stallMs = stallMs; self.stallEveryMs = stallEveryMs; self.stallDrops = stallDrops
            self.lossPct = lossPct; self.delayMs = delayMs; self.jitterMs = jitterMs; self.rateMbps = rateMbps
            self.queueMs = queueMs; self.burstLossPct = burstLossPct
        }
    }

    private struct Pkt { var data: [UInt8]; var release: UInt64; var toTarget: Bool }
    private let down: Int32, up: Int32          // down: listen socket (sender side), up: socket facing target
    private var senderAddr = sockaddr_in()
    private var haveSender = false
    public var profile: Profile
    private var rng = SplitMix(seed: 1234)
    private let lock = NSLock()
    private var heap = [Pkt]()
    private var linkFreeUs: UInt64 = 0
    private var burstLeft = 0
    private var running = true
    public private(set) var dropped = 0, forwarded = 0, queueDrops = 0
    private let targetPort: UInt16
    private let startUs = LinkClock.nowUs()

    public init(listenPort: UInt16, targetPort: UInt16, profile: Profile) throws {
        self.profile = profile; self.targetPort = targetPort
        func sock(bindPort: UInt16) -> Int32 {
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = bindPort.bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var sz: Int32 = 4 << 20
            setsockopt(s, SOL_SOCKET, SO_RCVBUF, &sz, 4); setsockopt(s, SOL_SOCKET, SO_SNDBUF, &sz, 4)
            return s
        }
        down = sock(bindPort: listenPort); up = sock(bindPort: 0)
        for (fd, toTarget) in [(down, true), (up, false)] {
            let t = Thread { [weak self] in self?.readLoop(fd: fd, toTarget: toTarget) }
            t.qualityOfService = .userInteractive; t.start()
        }
        let d = Thread { [weak self] in self?.deliverLoop() }
        d.qualityOfService = .userInteractive; d.start()
    }

    public func stop() { running = false; close(down); close(up) }

    private func readLoop(fd: Int32, toTarget: Bool) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while running {
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) } }
            if n <= 0 { if !running { return }; continue }
            let now = LinkClock.nowUs()
            lock.lock()
            if toTarget { senderAddr = from; haveSender = true }
            var drop = false
            if toTarget {   // impair only the media direction (sender -> receiver)
                if burstLeft > 0 { burstLeft -= 1; drop = true }
                else if Double(rng.next() % 100_000) / 1000 < profile.lossPct { drop = true }
                else if profile.burstLossPct > 0, Double(rng.next() % 100_000) / 1000 < profile.burstLossPct { burstLeft = 2; drop = true }
            }
            var release = now
            if toTarget, profile.stallEveryMs > 0 {
                let period = UInt64(profile.stallEveryMs * 1000), len = UInt64(profile.stallMs * 1000)
                let phase = (now &- startUs) % period
                if phase < len { if profile.stallDrops { drop = true } else { release = now &+ (len &- phase) } }
            }
            if toTarget, profile.rateMbps > 0 {
                let start = max(now, linkFreeUs)
                if start - now > UInt64(profile.queueMs * 1000) { drop = true; queueDrops += 1 }
                else { linkFreeUs = start + UInt64(Double(n) * 8 / profile.rateMbps); release = linkFreeUs }
            }
            if drop { dropped += 1; lock.unlock(); continue }
            let jitter = profile.jitterMs > 0 ? Double(rng.next() % 1000) / 1000 * profile.jitterMs : 0
            release += UInt64((profile.delayMs + jitter) * 1000)
            heap.append(Pkt(data: Array(buf[0..<n]), release: release, toTarget: toTarget))
            lock.unlock()
        }
    }

    private func deliverLoop() {
        while running {
            let now = LinkClock.nowUs()
            lock.lock()
            // pick packets due (insertion order preserved except for jitter, which may reorder slightly)
            var due = [Pkt](); var keep = [Pkt]()
            for p in heap { if p.release <= now { due.append(p) } else { keep.append(p) } }
            heap = keep
            let sender = senderAddr, have = haveSender
            lock.unlock()
            for p in due {
                forwarded += 1
                if p.toTarget {
                    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = targetPort.bigEndian
                    a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(up, p.data, p.data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                } else if have {
                    var a = sender
                    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(down, p.data, p.data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                }
            }
            usleep(due.isEmpty ? 200 : 0)
        }
    }
}
