//
//  MovingContentTest.swift
//  Miroo
//
//  Phase 5 Verification: Spawns an animated 60 FPS Cocoa window directly on the Miroo
//  virtual display to test dynamic screen capture, video encoding, hardware decoding,
//  and Metal GPU rendering under active visual motion.
//

import Cocoa
import Metal
import QuartzCore

final class AnimatedTestView: NSView {
    private var angle: CGFloat = 0.0
    private var counter: Int = 0
    private var displayTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        startAnimation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func startAnimation() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.angle += 0.08
            self.counter += 1
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 1. Dynamic background color shift
        let hue = CGFloat((counter % 360)) / 360.0
        let bgColor = NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1.0)
        bgColor.setFill()
        dirtyRect.fill()

        // 2. Rotating star/rectangle
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.rotate(by: angle)

        let rectSize: CGFloat = 220.0
        let drawRect = CGRect(x: -rectSize / 2, y: -rectSize / 2, width: rectSize, height: rectSize)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(drawRect)
        ctx.restoreGState()

        // 3. High-contrast live counter text
        let text = "Miroo Live Display Test\nFrame #\(counter)\n60 FPS Dynamic Motion"
        let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        str.draw(at: NSPoint(x: 30, y: bounds.height - 130))
    }

    deinit {
        displayTimer?.invalidate()
    }
}

@main
struct MovingContentTestApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Locate Miroo Virtual Display
        var targetOrigin = CGPoint(x: 2560, y: 0)
        for screen in NSScreen.screens {
            if screen.localizedName.contains("Miroo") {
                targetOrigin = screen.frame.origin
                print("[Animation Window] Found Miroo screen at origin: \(targetOrigin), size: \(screen.frame.size)")
                break
            }
        }

        let windowRect = NSRect(x: targetOrigin.x + 40, y: targetOrigin.y + 100, width: 450, height: 750)
        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Miroo Virtual Display Motion Test"
        window.contentView = AnimatedTestView(frame: NSRect(x: 0, y: 0, width: 450, height: 750))
        window.makeKeyAndOrderFront(nil)

        // Close after duration if argument passed
        if let durationIdx = CommandLine.arguments.firstIndex(of: "--duration"),
           durationIdx + 1 < CommandLine.arguments.count,
           let seconds = Double(CommandLine.arguments[durationIdx + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                print("[Animation Window] Duration elapsed. Closing window.")
                exit(0)
            }
        }

        app.run()
    }
}
