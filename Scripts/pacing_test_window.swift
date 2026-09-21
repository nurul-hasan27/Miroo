//
//  pacing_test_window.swift
//  Miroo
//
//  Phase 6.5: Controlled 60 FPS motion test window on the Miroo secondary display.
//  Contains a rapidly oscillating horizontal bar, a high-contrast vertical edge,
//  a microsecond timestamp, and a continuous frame counter.
//

import AppKit
import QuartzCore

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let secondScreen = NSScreen.screens.first { $0.frame.origin.x >= 2560 } ?? NSScreen.screens.last!
print("Target screen: \(secondScreen.localizedName), frame: \(secondScreen.frame)")

let rect = NSRect(
    x: secondScreen.frame.origin.x + 30,
    y: secondScreen.frame.origin.y + 200,
    width: 525,
    height: 800
)

let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
window.title = "Miroo 60 FPS Frame-Pacing Test"
window.backgroundColor = .black
window.level = .screenSaver
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
window.isOpaque = true

class MotionTestView: NSView {
    var frameIndex: UInt64 = 0
    var positionX: CGFloat = 0.0
    var direction: CGFloat = 1.0
    var speed: CGFloat = 8.0 // pixels per frame at 60 FPS
    var lastTime: CFTimeInterval = CACurrentMediaTime()
    var intervals: [Double] = []

    let barWidth: CGFloat = 80.0
    let barHeight: CGFloat = 120.0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0))
        context.fill(bounds)

        // 1. High-Contrast Static Reference Grid (Vertical lines every 50px)
        context.setStrokeColor(CGColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1.0))
        context.setLineWidth(1.0)
        var x: CGFloat = 20
        while x < bounds.width {
            context.move(to: CGPoint(x: x, y: 150))
            context.addLine(to: CGPoint(x: x, y: 400))
            x += 50
        }
        context.strokePath()

        // 2. High-Contrast Moving Horizontal Object with Sharp Vertical Edges
        let barY: CGFloat = 220
        let barRect = CGRect(x: positionX, y: barY, width: barWidth, height: barHeight)

        // Outer white glow/border
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        context.fill(barRect.insetBy(dx: -3, dy: -3))

        // High-contrast neon green moving bar
        context.setFillColor(CGColor(red: 0.0, green: 1.0, blue: 0.4, alpha: 1.0))
        context.fill(barRect)

        // Center vertical edge line for tear/judder inspection
        context.setStrokeColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
        context.setLineWidth(4.0)
        context.move(to: CGPoint(x: positionX + barWidth / 2.0, y: barY))
        context.addLine(to: CGPoint(x: positionX + barWidth / 2.0, y: barY + barHeight))
        context.strokePath()

        // 3. Status and Counter Labels
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 26),
            .foregroundColor: NSColor.white
        ]
        NSString(string: "⚡ 60 FPS Pacing Test").draw(at: NSPoint(x: 24, y: 730), withAttributes: titleAttrs)

        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.cyan
        ]
        NSString(string: "Phase 6.5: Moving Object & Edge Judder Analysis").draw(at: NSPoint(x: 24, y: 700), withAttributes: subAttrs)

        // Frame Counter & Time
        let counterText = String(format: "Frame: #%llu", frameIndex)
        let counterAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .bold),
            .foregroundColor: NSColor.systemGreen
        ]
        NSString(string: counterText).draw(at: NSPoint(x: 24, y: 620), withAttributes: counterAttrs)

        let now = CACurrentMediaTime()
        let timeString = String(format: "Uptime: %.3f s", now)
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        NSString(string: timeString).draw(at: NSPoint(x: 24, y: 580), withAttributes: timeAttrs)

        // Speed & Position
        let posString = String(format: "Bar X: %.1f px (Velocity: %.1f px/f)", positionX, speed * direction)
        let posAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.yellow
        ]
        NSString(string: posString).draw(at: NSPoint(x: 24, y: 540), withAttributes: posAttrs)

        // Bottom Info
        let infoText = """
        • Pure 60.0 Hz display link updates
        • 8 px/frame continuous linear oscillation
        • Inspect moving vertical edges for judder
        • Check for micro-stutters or frame skips
        """
        let infoAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.lightGray
        ]
        NSString(string: infoText).draw(at: NSPoint(x: 24, y: 30), withAttributes: infoAttrs)
    }

    func updateAnimation() {
        let now = CACurrentMediaTime()
        let dt = now - lastTime
        lastTime = now
        intervals.append(dt * 1000.0)
        if intervals.count > 120 { intervals.removeFirst() }

        frameIndex += 1

        // Update oscillating bar position
        let minX: CGFloat = 20.0
        let maxX: CGFloat = bounds.width - barWidth - 20.0

        positionX += speed * direction
        if positionX >= maxX {
            positionX = maxX
            direction = -1.0
        } else if positionX <= minX {
            positionX = minX
            direction = 1.0
        }

        needsDisplay = true
    }
}

let testView = MotionTestView(frame: NSRect(x: 0, y: 0, width: 525, height: 800))
window.contentView = testView
window.setFrame(rect, display: true)
window.setFrameOrigin(rect.origin)
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()
app.activate(ignoringOtherApps: true)

print("Starting continuous 60 FPS motion render loop on screen...")

// 60 Hz high-precision render timer
let timer = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue.main)
timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .nanoseconds(500_000))
timer.setEventHandler {
    testView.updateAnimation()
}
timer.resume()

// Run for 90 seconds
let duration: TimeInterval = 90.0
let deadline = Date().addingTimeInterval(duration)

while Date() < deadline {
    let nextEventDate = Date().addingTimeInterval(0.005)
    if let event = app.nextEvent(matching: .any, until: nextEventDate, inMode: .default, dequeue: true) {
        app.sendEvent(event)
    }
}

timer.cancel()
print("Pacing test window completed.")
