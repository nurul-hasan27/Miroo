import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import MirooCore

/// Turns phone touch events into macOS mouse/scroll events on the virtual display.
public final class InputInjector: @unchecked Sendable {
    /// Current bounds of the streamed display in global (top-left origin) coordinates.
    public var displayBounds: () -> CGRect
    private var leftDown = false
    private var lastPoint = CGPoint.zero
    private var clickCount = 1
    private var lastDownTime: TimeInterval = 0
    private var lastDownPoint = CGPoint(x: -1000, y: -1000)
    private var scrolling = false
    private let lock = NSLock()

    public init(displayBounds: @escaping () -> CGRect) { self.displayBounds = displayBounds }

    public static func hasAccessibility(prompt: Bool) -> Bool {
        let ax = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
        let post = CGPreflightPostEventAccess()
        print("[input] accessibility trusted=\(ax) postEventAccess=\(post)")
        return ax || post
    }

    public func apply(_ events: [InputEvent]) {
        lock.lock(); defer { lock.unlock() }
        let b = displayBounds()
        guard b.width > 0, b.height > 0 else { return }
        for e in events {
            let p = CGPoint(x: b.minX + CGFloat(min(max(e.x, 0), 1)) * b.width, y: b.minY + CGFloat(min(max(e.y, 0), 1)) * b.height)
            switch e.kind {
            case .down:
                if leftDown { releaseLocked() }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastDownTime < NSEvent.doubleClickInterval, hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y) < 12 { clickCount = min(3, clickCount + 1) } else { clickCount = 1 }
                lastDownTime = now; lastDownPoint = p
                post(.mouseMoved, p)
                post(.leftMouseDown, p, click: clickCount)
                leftDown = true; lastPoint = p
            case .move:
                post(leftDown ? .leftMouseDragged : .mouseMoved, p, click: leftDown ? clickCount : 0)
                lastPoint = p
            case .up:
                if leftDown { post(.leftMouseUp, p, click: clickCount); leftDown = false }
                lastPoint = p
            case .cancel:
                releaseLocked()
            case .scroll:
                postScroll(dx: Double(e.x), dy: Double(e.y), phase: scrolling ? 2 : 1)   // 1 began, 2 changed
                scrolling = true
            case .scrollEnd:
                if scrolling { postScroll(dx: 0, dy: 0, phase: 4); scrolling = false }   // 4 ended
            case .secondaryClick:
                post(.mouseMoved, p)
                post(.rightMouseDown, p, button: .right, click: 1)
                post(.rightMouseUp, p, button: .right, click: 1)
            }
        }
    }

    public func releaseAll() { lock.lock(); releaseLocked(); lock.unlock() }

    private func releaseLocked() {
        if leftDown { post(.leftMouseUp, lastPoint, click: clickCount); leftDown = false }
        if scrolling { postScroll(dx: 0, dy: 0, phase: 4); scrolling = false }
    }

    private func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, click: Int = 0) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if click > 0 { ev.setIntegerValueField(.mouseEventClickState, value: Int64(click)) }
        ev.post(tap: .cghidEventTap)
    }

    private func postScroll(dx: Double, dy: Double, phase: Int64) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        ev.post(tap: .cghidEventTap)
    }
}
