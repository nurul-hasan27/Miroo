//
//  MacInputController.swift
//  MirooMac
//
//  Phase 6A: Injects absolute touch events from iPhone into macOS WindowServer
//  as CGEvent mouse cursor movement, left clicks, and dragging, with connection-loss safety.
//

import Foundation
import CoreGraphics
import ApplicationServices
import os.lock
#if canImport(AppKit)
import AppKit
#endif

public final class MacInputController: @unchecked Sendable {
    public private(set) var isLeftButtonDown: Bool = false
    public private(set) var lastCursorPosition: CGPoint = .zero
    private var lastClickTime: CFTimeInterval = 0
    private var lastClickLocation: CGPoint = .zero
    private var clickCount: Int = 1
    private var lastMoveLogTime: CFTimeInterval = 0
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    public init() {
        lock.initialize(to: os_unfair_lock())
        checkAccessibilityPermission()
    }

    deinit {
        releaseAllButtons()
        lock.deallocate()
    }

    /// Checks if this process has macOS Accessibility permissions to inject CGEvents.
    @discardableResult
    public func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        if !isTrusted {
            print("----------------------------------------------------------------------")
            print(" [Miroo Input] WARNING: Accessibility Permission Required!")
            print(" To control the Mac cursor from iPhone touch, enable Accessibility:")
            print(" 1. Open System Settings -> Privacy & Security -> Accessibility")
            print(" 2. Enable permission for 'Terminal' (or 'MirooMac')")
            print("----------------------------------------------------------------------")
        } else {
            print("[Miroo Input] Accessibility permissions verified: Active.")
        }
        return isTrusted
    }

    /// Injects a normalized touch event into macOS WindowServer for the target displayID.
    public func handleTouchEvent(_ payload: TouchEventPayload, displayID: CGDirectDisplayID) {
        guard displayID != 0 else { return }

        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let clampedX = CGFloat(min(max(payload.x, 0.0), 1.0))
        let clampedY = CGFloat(min(max(payload.y, 0.0), 1.0))

        let globalX = bounds.origin.x + clampedX * bounds.size.width
        let globalY = bounds.origin.y + clampedY * bounds.size.height
        let targetPoint = CGPoint(x: globalX, y: globalY)

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let now = CACurrentMediaTime()

        switch payload.phase {
        case .began:
            if isLeftButtonDown {
                releaseAllButtonsLocked()
            }
            let doubleClickInterval = NSEvent.doubleClickInterval
            let dist = hypot(targetPoint.x - lastClickLocation.x, targetPoint.y - lastClickLocation.y)
            if (now - lastClickTime) < doubleClickInterval && dist < 10.0 {
                clickCount = min(clickCount + 1, 3)
            } else {
                clickCount = 1
            }
            lastClickTime = now
            lastClickLocation = targetPoint

            // 1. Move cursor to initial touch location
            if let moveEv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left) {
                moveEv.post(tap: .cghidEventTap)
            }

            // 2. Depress left mouse button
            if let downEv = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left) {
                downEv.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
                downEv.post(tap: .cghidEventTap)
                isLeftButtonDown = true
                lastCursorPosition = targetPoint
            }
            print(String(format: "[Miroo Input] Touch BEGAN at norm (%.3f, %.3f) -> Mac (%d, %d), clickCount=%d", payload.x, payload.y, Int(targetPoint.x), Int(targetPoint.y), clickCount))

        case .moved:
            if isLeftButtonDown {
                // Drag while pressed
                if let dragEv = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    dragEv.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
                    dragEv.post(tap: .cghidEventTap)
                    lastCursorPosition = targetPoint
                }
            } else {
                // Movement without mouse down
                if let moveEv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    moveEv.post(tap: .cghidEventTap)
                    lastCursorPosition = targetPoint
                }
            }
            if now - lastMoveLogTime > 0.5 {
                lastMoveLogTime = now
                print(String(format: "[Miroo Input] Touch MOVED at norm (%.3f, %.3f) -> Mac (%d, %d), down=%@", payload.x, payload.y, Int(targetPoint.x), Int(targetPoint.y), isLeftButtonDown ? "true" : "false"))
            }

        case .ended:
            if let upEv = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left) {
                upEv.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
                upEv.post(tap: .cghidEventTap)
                isLeftButtonDown = false
                lastCursorPosition = targetPoint
            }
            print(String(format: "[Miroo Input] Touch ENDED at norm (%.3f, %.3f) -> Mac (%d, %d)", payload.x, payload.y, Int(targetPoint.x), Int(targetPoint.y)))

        case .cancelled:
            print("[Miroo Input] Touch CANCELLED -> releasing all buttons")
            releaseAllButtonsLocked()
        }
    }

    /// Releases all depressed mouse buttons to guarantee no stuck buttons on disconnect, error, or cancellation.
    public func releaseAllButtons() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        releaseAllButtonsLocked()
    }

    private func releaseAllButtonsLocked() {
        guard isLeftButtonDown else { return }
        isLeftButtonDown = false
        let currentPos = CGEvent(source: nil)?.location ?? lastCursorPosition
        if let upEv = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentPos, mouseButton: .left) {
            upEv.setIntegerValueField(.mouseEventClickState, value: 1)
            upEv.post(tap: .cghidEventTap)
            print("[Miroo Input] Connection-loss / cancel safety: Released held left mouse button at (\(Int(currentPos.x)), \(Int(currentPos.y))).")
        }
    }

    // MARK: - Phase 6B: Trackpad Scrolling & Right Click

    /// Configurable scroll sensitivity multiplier for smooth two-finger scrolling.
    public static var scrollSensitivity: Float = 1.5
    private var lastScrollLogTime: CFTimeInterval = 0

    /// Injects a two-finger continuous scroll event at the current cursor position.
    /// - Parameters:
    ///   - deltaX: Horizontal scroll delta in points (positive = swipe right / scroll right)
    ///   - deltaY: Vertical scroll delta in points (positive = swipe down / scroll down)
    public func scroll(deltaX: Float, deltaY: Float) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        // Safety: Release left button if held
        if isLeftButtonDown {
            releaseAllButtonsLocked()
        }

        let scaledDeltaX = deltaX * Self.scrollSensitivity
        let scaledDeltaY = deltaY * Self.scrollSensitivity

        guard abs(scaledDeltaX) >= 0.1 || abs(scaledDeltaY) >= 0.1 else { return }

        let targetPoint = (lastCursorPosition != .zero) ? lastCursorPosition : (CGEvent(source: nil)?.location ?? .zero)

        if let scrollEv = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(round(scaledDeltaY)),
            wheel2: Int32(round(scaledDeltaX)),
            wheel3: 0
        ) {
            scrollEv.location = targetPoint
            scrollEv.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            scrollEv.post(tap: .cghidEventTap)
        }

        let now = CACurrentMediaTime()
        if now - lastScrollLogTime > 0.5 {
            lastScrollLogTime = now
            print(String(format: "[Miroo Input] Scroll delta (%.1f, %.1f) -> Mac (%d, %d)", scaledDeltaX, scaledDeltaY, Int(targetPoint.x), Int(targetPoint.y)))
        }
    }

    /// Injects a right click (rightMouseDown followed by rightMouseUp) at the current cursor position.
    public func rightClick() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        // Safety: Release left button if held
        if isLeftButtonDown {
            releaseAllButtonsLocked()
        }

        let targetPoint = (lastCursorPosition != .zero) ? lastCursorPosition : (CGEvent(source: nil)?.location ?? .zero)

        if let downEv = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: targetPoint, mouseButton: .right) {
            downEv.setIntegerValueField(.mouseEventClickState, value: 1)
            downEv.post(tap: .cghidEventTap)
        }

        if let upEv = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: targetPoint, mouseButton: .right) {
            upEv.setIntegerValueField(.mouseEventClickState, value: 1)
            upEv.post(tap: .cghidEventTap)
        }

        print(String(format: "[Miroo Input] Injected right click at (%d, %d)", Int(targetPoint.x), Int(targetPoint.y)))
    }
}
