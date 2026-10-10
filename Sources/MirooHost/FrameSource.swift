import Foundation
import CoreVideo
import CoreGraphics
import AppKit
import MirooCore

/// Anything that produces video frames for the link (real display capture or a synthetic pattern).
public protocol FrameSource: AnyObject {
    var onFrame: ((CVPixelBuffer, UInt32) -> Void)? { get set }
    /// Global bounds of the display that touches should control (nil = input not supported).
    var inputBounds: CGRect? { get }
    func stop() async
    /// Stops capturing but keeps what is expensive to rebuild (the virtual display) for a short grace period.
    func suspend() async
    /// Re-targets the source to a new pixel size without losing the display (rotation). Returns false if unsupported.
    func resize(width: Int, height: Int) async -> Bool
    /// Switches the display's "looks like" resolution step (0 = biggest text … last = most room).
    func setLook(_ index: Int) async
    /// Called when the user changes the resolution in System Settings > Displays.
    var onLookChanged: ((Int) -> Void)? { get set }
}

public extension FrameSource {
    func resize(width: Int, height: Int) async -> Bool { false }
    func suspend() async { await stop() }
    func setLook(_ index: Int) async {}
}

/// Display capture: owns the virtual display + ScreenCaptureKit stream.
public final class DisplayFrameSource: FrameSource {
    public var onFrame: ((CVPixelBuffer, UInt32) -> Void)? { didSet { capturer.onFrame = onFrame } }
    public let display: VirtualDisplay
    public var inputBounds: CGRect? { display.bounds }
    public var onLookChanged: ((Int) -> Void)?
    private var lastLook: Int?
    private var observer: NSObjectProtocol?
    private let capturer = ScreenCapturer()
    private var patternWindow: PatternWindow?
    private let serial: UInt32?

    public init(name: String, width: Int, height: Int, lookIndex: Int = 0, pattern: Bool = false, patternFPS: Double = 60, serial: UInt32? = nil) async throws {
        let tVD = LinkClock.nowUs()
        guard let vd = await MainActor.run(body: { VirtualDisplayPool.shared.acquire(name: name, width: width, height: height, lookIndex: lookIndex, serial: serial) }) else {
            throw CaptureError.failed("could not create the virtual display")
        }
        display = vd
        self.serial = serial
        lastLook = vd.lookIndex
        if pattern { patternWindow = await MainActor.run { PatternWindow(on: vd.displayID, fps: patternFPS) } }
        let tCap = LinkClock.nowUs()
        try await capturer.start(displayID: vd.displayID, width: width, height: height)
        print("[source] virtual display \(Int(Double(tCap &- tVD) / 1000)) ms, capture start \(Int(Double(LinkClock.nowUs() &- tCap) / 1000)) ms")
        // The user may pick another resolution in System Settings > Displays: follow it (and tell the app so its menu agrees).
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let idx = self.display.currentLookIndex, idx != self.lastLook else { return }
            self.lastLook = idx
            self.display.noteLook(idx)
            self.onLookChanged?(idx)
        }
    }

    public func setLook(_ index: Int) async {
        await MainActor.run { lastLook = index; _ = display.selectLook(index) }     // set first: the screen-change notification can fire inline
    }

    public func resize(width: Int, height: Int) async -> Bool {
        await capturer.stop()
        let ok = await MainActor.run { display.resize(pixelWidth: width, pixelHeight: height) }
        guard ok else { return false }
        capturer.onFrame = onFrame
        do { try await capturer.start(displayID: display.displayID, width: width, height: height); return true } catch { return false }
    }

    public func stop() async {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        await capturer.stop()
        await MainActor.run { patternWindow?.close(); VirtualDisplayPool.shared.release(display, serial: serial, keepFor: 0) }
    }

    public func suspend() async {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        await capturer.stop()
        await MainActor.run { patternWindow?.close(); VirtualDisplayPool.shared.release(display, serial: serial, keepFor: 60) }
    }
}

/// Synthetic "desktop": static text-like background, a moving window, a running counter. For link tests without screen capture.
public final class SyntheticFrameSource: FrameSource {
    public var onFrame: ((CVPixelBuffer, UInt32) -> Void)?
    public var onLookChanged: ((Int) -> Void)?
    public var inputBounds: CGRect? { nil }
    private let w: Int, h: Int
    private var pool: CVPixelBufferPool?
    private var base: [UInt8]
    private var timer: DispatchSourceTimer?
    private var i = 0
    private let busy: Bool

    public init(width: Int, height: Int, busy: Bool = false) {
        w = width; h = height; self.busy = busy
        base = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let grid = (x % 40 < 2 || y % 40 < 2) ? 90 : 0
                let text = (y % 22 < 11 && (x / 7 + y / 22) % 5 != 0) ? 150 : 0
                base[y * width + x] = UInt8(truncatingIfNeeded: 40 + grid + (y > 120 ? text : 0))
            }
        }
        CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "miroo.synthetic", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .microseconds(16_667), leeway: .microseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }

    public func stop() async { timer?.cancel(); timer = nil }

    private func tick() {
        guard let pool else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buf = pb else { return }
        CVPixelBufferLockBaseAddress(buf, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        base.withUnsafeBufferPointer { b in for row in 0..<h { memcpy(y + row * ys, b.baseAddress! + row * w, w) } }
        let bw = min(w / 2, 420), bh = min(h / 3, 300)
        let bx = (i * 9) % max(1, w - bw), by = 60 + (i * 4) % max(1, h - bh - 80)
        for row in by..<min(h, by + bh) { for col in bx..<min(w, bx + bw) { y[row * ys + col] = UInt8(truncatingIfNeeded: 215 + ((col - bx) / 20 + (row - by) / 20) % 2 * 25) } }
        // frame counter bar: its width encodes i, so a camera/eyeball can see staleness
        let barW = (i % 600) * w / 600
        for row in (h - 24)..<h { for col in 0..<barW { y[row * ys + col] = 255 } }
        if busy {
            var seed = UInt32(truncatingIfNeeded: i) &* 2654435761
            for row in (h / 2)..<min(h, h / 2 + 200) { for col in stride(from: 0, to: w, by: 2) {
                seed = seed &* 1664525 &+ 1013904223
                let v = UInt8(truncatingIfNeeded: 90 + ((seed >> 24) & 0x3F)); y[row * ys + col] = v; y[row * ys + col + 1] = v } }
        }
        let uv = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt8.self)
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buf, 1) * CVPixelBufferGetHeightOfPlane(buf, 1))
        CVPixelBufferUnlockBaseAddress(buf, [])
        i += 1
        onFrame?(buf, LinkClock.nowUs32())
    }
}
