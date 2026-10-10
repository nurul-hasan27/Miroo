import AppKit
import MirooCore

/// Animated window placed on a given display: moving bar, running counter, and a block of text for sharpness checks.
@MainActor
public final class PatternWindow {
    private let window: NSWindow
    private let view: PatternView
    private var timer: Timer?

    public init?(on displayID: CGDirectDisplayID, fps: Double = 60) {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) else { return nil }
        view = PatternView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: true)
        window.contentView = view
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            guard let v = self?.view else { return }
            v.tick += 1; v.needsDisplay = true
        }
    }

    public func close() { timer?.invalidate(); window.orderOut(nil) }
}

final class PatternView: NSView {
    var tick = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill(); bounds.fill()
        let w = bounds.width, h = bounds.height
        let x = CGFloat(tick * 7 % max(1, Int(w - 140)))
        NSColor.systemOrange.setFill(); NSRect(x: x, y: 70, width: 140, height: 90).fill()
        NSColor.systemTeal.setFill(); NSRect(x: w - 60 - CGFloat(tick * 5 % max(1, Int(w - 120))), y: 170, width: 60, height: 60).fill()
        ("frame \(tick)" as NSString).draw(at: NSPoint(x: 16, y: 20), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.white])
        let lines = ["The quick brown fox jumps over the lazy dog", "0123456789 !@#$%^&*() Miroo text sharpness", "Sphinx of black quartz, judge my vow",
                     "Pack my box with five dozen liquor jugs"]
        for i in 0..<14 {
            (lines[i % lines.count] as NSString).draw(at: NSPoint(x: 16, y: 250 + CGFloat(i) * 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)])
        }
        NSColor.white.setFill(); NSRect(x: 0, y: h - 14, width: w * CGFloat(tick % 300) / 300, height: 14).fill()
    }
}
