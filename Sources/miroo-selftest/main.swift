import Foundation
import Network
import CoreVideo
import MirooCore
import MirooMedia
import MirooNet
import MirooSession
import MirooTestKit

// miroo-selftest [--seconds N] [--loss P] [--delay MS] [--jitter MS] [--rate MBPS] [--codec h264|hevc] [--burst P] [--bitrate MBPS]
var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String, _ def: Double) -> Double {
    if let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
    return def
}
let seconds = opt("seconds", 15)
let busy = args.contains("--busy")
let codec: Codec = (args.firstIndex(of: "--codec").map { args[$0 + 1] } ?? "hevc") == "h264" ? .h264 : .hevc
let W = 1792, H = 828
let profile = ImpairmentProxy.Profile(lossPct: opt("loss", 0), delayMs: opt("delay", 0), jitterMs: opt("jitter", 0),
                                      rateMbps: opt("rate", 0), queueMs: 60, burstLossPct: opt("burst", 0),
                                      stallMs: opt("stall", 0), stallEveryMs: opt("stallevery", 0), stallDrops: !args.contains("--stalldelay"))
print("selftest: \(W)x\(H) \(codec) \(seconds)s profile=\(profile)")

let rxQueue = DispatchQueue(label: "rx", qos: .userInteractive)
let server = try UDPServer(queue: rxQueue)
let receiver = LinkReceiver(queue: rxQueue)
let t0Us = LinkClock.nowUs()
var shown = 0
var lastShownUs: UInt64 = 0
var gaps = [Double]()
let gapLock = NSLock()
receiver.onFrame = { _ in
    let now = LinkClock.nowUs()
    gapLock.lock(); shown += 1
    // the first 1.5 s include codec warm-up and the startup keyframe (measured separately); freeze statistics start after it
    if lastShownUs != 0, now &- t0Us > 1_500_000 { let g = Double(now &- lastShownUs) / 1000; gaps.append(g); if g > 100, ProcessInfo.processInfo.environment["MIROO_DEBUG_LINK"] != nil { print(String(format: "[FREEZE %.0f ms ended at t=%.1f]", g, Double(now &- t0Us) / 1000)) } }
    lastShownUs = now
    gapLock.unlock()
}
let ready = DispatchSemaphore(value: 0)
var serverPort: UInt16 = 0
server.onReady = { p in serverPort = p.rawValue; ready.signal() }
server.onFlow = { ch in receiver.attach(ch) }
server.start()
ready.wait()

let proxyPort: UInt16 = 40_000 + UInt16.random(in: 0..<2000)
let proxy = try ImpairmentProxy(listenPort: proxyPort, targetPort: serverPort, profile: profile)
let txQueue = DispatchQueue(label: "tx", qos: .userInteractive)
let txChannel = UDPChannel.connect(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, interface: nil, queue: txQueue)
let encrypted = args.contains("--encrypt")
let kM = LinkCrypto.newEphemeral(), kP = LinkCrypto.newEphemeral()
let sM = LinkCrypto.sharedSecret(kM, peerPub: kP.pub)!, sP = LinkCrypto.sharedSecret(kP, peerPub: kM.pub)!
let pk = LinkCrypto.pairingKey(sM, pubM: kM.pub, pubP: kP.pub)
let macSession = LinkCrypto.session(sM, pairingKey: pk, pubM: kM.pub, pubP: kP.pub, role: .mac)
let phoneSession = LinkCrypto.session(sP, pairingKey: pk, pubM: kM.pub, pubP: kP.pub, role: .phone)
if encrypted { receiver.cipher = phoneSession.udp }
let streamer = try LinkStreamer(config: .init(width: W, height: H, fps: 60, codec: codec, maxBitrate: Int(opt("bitrate", 30)) * 1_000_000, startBitrate: Int(opt("start", 5) * 1_000_000)), channel: txChannel, cipher: encrypted ? macSession.udp : nil)
streamer.onLog = { print("  [streamer] \($0)") }
txChannel.start()
// announce the flow (receiver learns the sender's address when the first datagram arrives)
var waited = 0
while !streamer.isConnected && waited < 200 {          // wait for the receiver's first feedback (flow established)
    streamer.knock(); usleep(10_000); waited += 1
    receiver.sendHelloIfNeeded()
}
print("flow established after \(waited * 10) ms")

// synthetic desktop: static pattern + moving window + scrolling text-like band
var pool: CVPixelBufferPool?
CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   kCVPixelBufferWidthKey: W, kCVPixelBufferHeightKey: H,
                                   kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
var base = [UInt8](repeating: 0, count: W * H)
for y in 0..<H { for x in 0..<W { base[y * W + x] = UInt8(truncatingIfNeeded: 70 + ((x / 24) ^ (y / 24)) % 60 + (x * y) % 3) } }
func frame(_ i: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
    for row in 0..<H { memcpy(y + row * ys, base.withUnsafeBufferPointer { $0.baseAddress! + row * W }, W) }
    let bx = (i * 11) % (W - 420), by = 80 + (i * 5) % (H - 400)
    for row in by..<(by + 300) { for col in bx..<(bx + 400) { y[row * ys + col] = UInt8(truncatingIfNeeded: 200 + (col + i) % 40) } }
    if busy {   // scrolling "video/photo" region that changes every frame -> high bitrate
        var seed = UInt32(truncatingIfNeeded: i / 1) &* 2654435761
        for row in 500..<(500 + 280) {
            for col in stride(from: 0, to: W, by: 2) {
                seed = seed &* 1664525 &+ 1013904223
                let v = UInt8(truncatingIfNeeded: 90 + ((seed >> 24) & 0x3F) + UInt32(col / 16))
                y[row * ys + col] = v; y[row * ys + col + 1] = v
            }
        }
    }
    let uv = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt8.self)
    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buf, 1) * CVPixelBufferGetHeightOfPlane(buf, 1))
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

let start = Date()
var i = 0
var nextReport = 1.0
let frameInterval = 1.0 / 60
var next = CACurrentMediaTimeShim()
func CACurrentMediaTimeShim() -> Double { Double(LinkClock.nowUs()) / 1e6 }
while Date().timeIntervalSince(start) < seconds {
    streamer.submit(frame(i), captureUs: LinkClock.nowUs32())
    i += 1
    next += frameInterval
    let wait = next - CACurrentMediaTimeShim()
    if wait > 0 { usleep(UInt32(wait * 1e6)) } else { next = CACurrentMediaTimeShim() }
    let el = Date().timeIntervalSince(start)
    if el >= nextReport {
        nextReport += 1
        let s = streamer.stats
        let r = receiver.stats
        print(String(format: "t=%2.0fs  tx: %.0f fps %.1f Mbps (target %.1f, pace %.0f) enc=%.1fms rtt=%.1fms glass=%.1fms | rx: %.0f fps %.1f Mbps decode=%.1fms qdelay=%.1fms | rec req=%d repaired=%d lost=%d recoveryFrames=%d dropped(proxy)=%d encDrops=%d subDrops=%d repairs=%d/%dpkts",
                     el, s.fps, s.sentMbps, s.targetMbps, s.paceMbps, s.encodeMsAvg, s.rttMs, s.glassMs,
                     r.fps, r.mbps, r.decodeMsAvg, r.queueDelayMs, r.recoveryRequests, r.framesRepaired, r.framesLost, s.recoveryFrames, proxy.dropped, s.encoderDrops, s.submitDrops, s.repairsServed, s.repairPackets))
    }
}
let s = streamer.stats, r = receiver.stats
gapLock.lock()
let sortedGaps = gaps.sorted()
let maxGap = sortedGaps.last ?? 0, p99Gap = sortedGaps.isEmpty ? 0 : sortedGaps[min(sortedGaps.count - 1, Int(Double(sortedGaps.count) * 0.99))]
let freezes = gaps.filter { $0 > 60 }.count
gapLock.unlock()
print(String(format: "FREEZE maxGap=%.0fms p99Gap=%.0fms gaps>60ms=%d", maxGap, p99Gap, freezes))
print("RESULT submitted=\(i) shown=\(shown) (\(Int(Double(shown) / Double(i) * 100))%) recoveryRequests=\(r.recoveryRequests) repaired=\(r.framesRepaired) lost=\(r.framesLost) recoveryFrames=\(s.recoveryFrames) glass=\(String(format: "%.1f", s.glassMs))ms")
streamer.stop(); receiver.stop(); proxy.stop()
exit(0)
