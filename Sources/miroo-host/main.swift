import Foundation
import AppKit
import Network
import MirooCore
import MirooNet
import MirooSession
import MirooHost
import MirooMedia
import CGVirtualDisplayBridge
import CoreVideo
import CoreGraphics

// miroo-host connect [--device NAME] [--synthetic] [--busy] [--seconds N]
setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
func opt(_ n: String, _ d: Int) -> Int { if let i = args.firstIndex(of: "--\(n)"), i + 1 < args.count, let v = Int(args[i + 1]) { return v }; return d }
func sopt(_ n: String) -> String? { if let i = args.firstIndex(of: "--\(n)"), i + 1 < args.count { return args[i + 1] }; return nil }
for flag in ["--no-ack", "--no-adapt"] where args.contains(flag) {
    setenv(flag == "--no-ack" ? "MIROO_NO_ACK" : "MIROO_NO_ADAPT", "1", 1)
}
if let i = args.firstIndex(of: "--keepalive-ms"), i + 1 < args.count { setenv("MIROO_KEEPALIVE_MS", args[i + 1], 1) }
if args.contains("--debug") { setenv("MIROO_DEBUG_LINK", "1", 1); setenv("MIROO_DEBUG_ENC", "1", 1) }
let seconds = opt("seconds", 20)
let synthetic = args.contains("--synthetic"), busy = args.contains("--busy")
let wanted = sopt("device")

if args.first == "looktest" {
    // Create the display, capture it, cycle through every "looks like" step and check capture keeps delivering frames.
    let W = opt("w", 1792), H = opt("h", 828)
    Task { @MainActor in
        do {
            let src = try await DisplayFrameSource(name: "Miroo looktest", width: W, height: H, lookIndex: 0, pattern: true, patternFPS: 60, serial: 0x1234)
            var frames = 0; var lastSize = ""
            src.onFrame = { pb, _ in frames += 1; lastSize = "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))" }
            src.onLookChanged = { print("  (macOS reported a user mode change -> step \($0))") }
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let usable = ((CGDisplayCopyAllDisplayModes(src.display.displayID, opts) as? [CGDisplayMode]) ?? [])
                .filter { $0.isUsableForDesktopGUI() && $0.pixelWidth > $0.width }.map { "\($0.width)x\($0.height)" }
            print("HiDPI modes System Settings can offer: \(usable)")
            for i in 0..<VirtualDisplay.lookSteps.count {
                await src.setLook(i)
                try await Task.sleep(nanoseconds: 300_000_000)
                let before = frames
                try await Task.sleep(nanoseconds: 1_200_000_000)
                let m = CGDisplayCopyDisplayMode(src.display.displayID)
                print("step \(i): mode \(m?.width ?? 0)x\(m?.height ?? 0) pt (\(m?.pixelWidth ?? 0)x\(m?.pixelHeight ?? 0) px) bounds \(src.display.bounds.size) -> captured \(frames - before) frames in 1.2 s, frame size \(lastSize)")
            }
            print("rotate to portrait \(H)x\(W) ...")
            let ok = await src.resize(width: H, height: W)
            try await Task.sleep(nanoseconds: 500_000_000)
            let b2 = frames; try await Task.sleep(nanoseconds: 1_200_000_000)
            let m = CGDisplayCopyDisplayMode(src.display.displayID)
            print("portrait ok=\(ok): mode \(m?.width ?? 0)x\(m?.height ?? 0) -> \(frames - b2) frames, frame size \(lastSize), look step kept = \(src.display.lookIndex)")
            await src.stop()
        } catch { print("looktest failed: \(error)") }
        exit(0)
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
if args.first == "modes" {
    // Dump what macOS offers for a virtual display built with a list of resolutions (diagnostic).
    let W = opt("w", 1792), H = opt("h", 828), maxPx = opt("max", 4096)
    var factors: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    if let i = args.firstIndex(of: "--factors"), i + 1 < args.count { factors = args[i + 1].split(separator: ",").compactMap { Double($0) } }
    let base = (W / 2, H / 2)
    let sizes = factors.map { f in NSValue(size: NSSize(width: (Double(base.0) * f / 2).rounded() * 2, height: (Double(base.1) * f / 2).rounded() * 2)) }
    guard let b = try? CGVirtualDisplayBridge(name: "Miroo modes test", logicalWidth: UInt32(base.0), logicalHeight: UInt32(base.1), scaleFactor: 2,
                                              vendorID: 0x5043, productID: 0x4F54, serialNum: 0x7777, sizeInMillimeters: CGSize(width: Double(opt("mmw", 140)), height: Double(opt("mmh", 65))),
                                              maxPixels: UInt32(maxPx), queue: .main) else { print("create failed"); exit(1) }
    print("created id \(b.displayID); applyLogicalSizes -> \(b.applyLogicalSizes(sizes))")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    let modes = (CGDisplayCopyAllDisplayModes(b.displayID, opts) as? [CGDisplayMode]) ?? []
    print("macOS lists \(modes.count) modes:")
    for m in modes { print("  \(m.width)x\(m.height) points  <- \(m.pixelWidth)x\(m.pixelHeight) pixels  hiDPI=\(m.pixelWidth > m.width)  usable=\(m.isUsableForDesktopGUI())  \(m.refreshRate)Hz") }
    if let cur = CGDisplayCopyDisplayMode(b.displayID) { print("current: \(cur.width)x\(cur.height) (\(cur.pixelWidth)x\(cur.pixelHeight) px)") }
    b.destroy(); exit(0)
}
if args.first == "inputtest2" {
    // touch events -> cursor position on the main display (move only; never clicks)
    let main = CGDisplayBounds(CGMainDisplayID())
    let inj = InputInjector(displayBounds: { main })
    let before = CGEvent(source: nil)?.location ?? .zero
    var seq: UInt32 = 0
    func ev(_ k: InputKind, _ x: Float, _ y: Float) -> InputEvent { seq += 1; return InputEvent(seq: seq, kind: k, x: x, y: y) }
    var ok = true
    for (nx, ny) in [(Float(0.25), Float(0.25)), (0.5, 0.5), (0.75, 0.6)] {
        inj.apply([ev(.move, nx, ny)])
        Thread.sleep(forTimeInterval: 0.15)
        let now = CGEvent(source: nil)?.location ?? .zero
        let want = CGPoint(x: main.minX + CGFloat(nx) * main.width, y: main.minY + CGFloat(ny) * main.height)
        let hit = hypot(now.x - want.x, now.y - want.y) < 3
        ok = ok && hit
        print("[inputtest2] move(\(nx),\(ny)) -> cursor \(now) wanted \(want) \(hit ? "OK" : "MISS")")
    }
    inj.releaseAll()
    CGWarpMouseCursorPosition(before)
    print("[inputtest2] RESULT \(ok ? "PASS" : "FAIL")")
    exit(ok ? 0 : 1)
}
if args.first == "inputtest" {
    let before = CGEvent(source: nil)?.location ?? .zero
    _ = InputInjector.hasAccessibility(prompt: false)
    let target = CGPoint(x: before.x + 40, y: before.y + 25)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.2)
    let after = CGEvent(source: nil)?.location ?? .zero
    print("[inputtest] cursor before=\(before) after=\(after) moved=\(after != before)")
    if after != before { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: before, mouseButton: .left)?.post(tap: .cghidEventTap) }
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task.detached(priority: .utility) { LinkEncoder.warmUp() }
let browseQ = DispatchQueue(label: "miroo.browse")
let browser = LinkBrowser(queue: browseQ)
var session: HostSession?
var started = false

func makeSession() -> HostSession {
    let s = HostSession(hostName: Host.current().localizedName ?? "Mac", hostId: PairingStore.shared.localIdentity()) { w, h, _ in
        if synthetic { return SyntheticFrameSource(width: w, height: h, busy: busy) }
        return try await DisplayFrameSource(name: "Miroo", width: w, height: h, lookIndex: opt("look", 0), pattern: args.contains("--pattern"), patternFPS: Double(opt("pattern-fps", 60)))
    }
    s.onLog = { print("[host] \($0)") }
    s.onState = { print("[host] state -> \($0)") }
    return s
}

browser.onChange = { found in
    print("[host] discovered: \(found.map { $0.name })")
    guard !started, let f = found.first(where: { wanted == nil || $0.name.localizedCaseInsensitiveContains(wanted!) }) else { return }
    started = true
    print("[host] connecting to \(f.name)")
    let s = makeSession(); session = s
    s.connect(to: f.endpoint)
}
browser.start()
print("[host] browsing for phones ...")

DispatchQueue.main.async {
    Task {
        for t in 0..<seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let st = session?.streamerStats, session?.state == .streaming {
                print(String(format: "[host] t=%2d tx %.0ffps %.1fMbps (target %.1f pace %.0f) enc=%.1fms rtt=%.1fms glass=%.1fms loss=%.1f%% qdelay=%.1fms recov=%d drops=%d/%d capGap p50/p95/max %.1f/%.1f/%.0f ms",
                             t + 1, st.fps, st.sentMbps, st.targetMbps, st.paceMbps, st.encodeMsAvg, st.rttMs, st.glassMs, st.lossPct, st.queueDelayMs, st.recoveryFrames, st.encoderDrops, st.submitDrops, st.captureGapP50Ms, st.captureGapP95Ms, st.captureGapMaxMs))
            }
        }
        session?.stop(reason: "test finished")
        try? await Task.sleep(nanoseconds: 500_000_000)
        exit(0)
    }
}
app.run()
