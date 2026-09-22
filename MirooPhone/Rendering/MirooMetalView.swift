//
//  MirooMetalView.swift
//  Miroo
//
//  Phase 5 & Usable Display: SwiftUI wrapper for MTKView supporting both iOS (UIViewRepresentable)
//  and macOS (NSViewRepresentable) for live hardware-accelerated video display with authoritative
//  safe-area tracking and dynamic orientation adaptation.
//

import SwiftUI
import MetalKit

#if os(iOS)
import UIKit

public enum TouchGestureState: Sendable {
    case none
    case singleFinger
    case twoFinger
    case resetting
}

/// Custom MTKView subclass that observes safe area and bounds changes dynamically,
/// handles single-finger touch interaction with absolute normalization,
/// two-finger scrolling, and two-finger tap right click.
public final class MirooMTKView: MTKView {
    public var onLayoutChange: ((CGRect, UIEdgeInsets) -> Void)?
    public var onTouchEvent: ((TouchEventPayload) -> Void)?
    public var onScrollEvent: ((ScrollEventPayload) -> Void)?
    public var onRightClick: ((RightClickPayload) -> Void)?
    public weak var renderer: MetalRenderer?

    // Gesture State Machine (Phase 6B)
    public private(set) var gestureState: TouchGestureState = .none
    private var firstTouch: UITouch?
    private var secondTouch: UITouch?

    // Two-finger gesture tracking
    private var twoFingerStartTime: CFTimeInterval = 0
    private var initialCentroid: CGPoint = .zero
    private var previousCentroid: CGPoint = .zero
    private var isPotentialTwoFingerTap: Bool = false

    // Tap detection constants
    public var maximumTapDuration: CFTimeInterval = 0.28
    public var maximumTapMovement: CGFloat = 12.0

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        resetGestureState()
        let effectiveInsets = window?.safeAreaInsets ?? safeAreaInsets
        onLayoutChange?(bounds, effectiveInsets)
        self.draw()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let effectiveInsets = window?.safeAreaInsets ?? safeAreaInsets
        onLayoutChange?(bounds, effectiveInsets)
        self.draw()
    }

    public func resetGestureState() {
        if gestureState == .singleFinger {
            cancelSingleFingerTouch()
        }
        firstTouch = nil
        secondTouch = nil
        isPotentialTwoFingerTap = false
        gestureState = .none
    }

    private func cancelSingleFingerTouch() {
        guard let active = firstTouch else { return }
        let location = active.location(in: self)
        let norm = renderer?.currentViewportLayout?.touchToNormalizedVideoCoordinate(location, clamp: true) ?? CGPoint(x: 0.5, y: 0.5)
        let payload = TouchEventPayload(
            phase: .cancelled,
            touchID: 0,
            x: Float(norm.x),
            y: Float(norm.y),
            timestampNs: UInt64(CACurrentMediaTime() * 1_000_000_000)
        )
        onTouchEvent?(payload)
        firstTouch = nil
    }

    // MARK: - Multi-Touch Handling (Phase 6A & 6B)

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let allTouches = event?.allTouches else { return }
        let currentTouches = allTouches.filter { $0.phase == .began || $0.phase == .moved || $0.phase == .stationary }

        switch gestureState {
        case .none:
            if currentTouches.count == 1, let touch = currentTouches.first {
                let location = touch.location(in: self)
                guard let layout = renderer?.currentViewportLayout,
                      let norm = layout.touchToNormalizedVideoCoordinate(location, clamp: false) else {
                    return
                }
                firstTouch = touch
                secondTouch = nil
                gestureState = .singleFinger
                let payload = TouchEventPayload(
                    phase: .began,
                    touchID: 0,
                    x: Float(norm.x),
                    y: Float(norm.y),
                    timestampNs: UInt64(CACurrentMediaTime() * 1_000_000_000)
                )
                onTouchEvent?(payload)
            } else if currentTouches.count >= 2 {
                startTwoFingerGesture(with: currentTouches)
            }

        case .singleFinger:
            if currentTouches.count >= 2 {
                // Case A: Second finger appeared while in single-finger mode!
                // Release the single-finger mouse interaction before entering two-finger mode
                cancelSingleFingerTouch()
                startTwoFingerGesture(with: currentTouches)
            }

        case .twoFinger:
            break

        case .resetting:
            break
        }
    }

    private func startTwoFingerGesture(with touches: Set<UITouch>) {
        let touchArray = Array(touches)
        guard touchArray.count >= 2 else { return }
        firstTouch = touchArray[0]
        secondTouch = touchArray[1]
        gestureState = .twoFinger

        let p1 = touchArray[0].location(in: self)
        let p2 = touchArray[1].location(in: self)
        let centroid = CGPoint(x: (p1.x + p2.x) / 2.0, y: (p1.y + p2.y) / 2.0)

        twoFingerStartTime = CACurrentMediaTime()
        initialCentroid = centroid
        previousCentroid = centroid
        isPotentialTwoFingerTap = true
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        switch gestureState {
        case .singleFinger:
            guard let active = firstTouch, touches.contains(active) else { return }
            let location = active.location(in: self)
            guard let layout = renderer?.currentViewportLayout,
                  let norm = layout.touchToNormalizedVideoCoordinate(location, clamp: true) else {
                return
            }
            let payload = TouchEventPayload(
                phase: .moved,
                touchID: 0,
                x: Float(norm.x),
                y: Float(norm.y),
                timestampNs: UInt64(CACurrentMediaTime() * 1_000_000_000)
            )
            onTouchEvent?(payload)

        case .twoFinger:
            guard let t1 = firstTouch, let t2 = secondTouch else { return }
            guard touches.contains(t1) || touches.contains(t2) else { return }

            let p1 = t1.location(in: self)
            let p2 = t2.location(in: self)
            let currentCentroid = CGPoint(x: (p1.x + p2.x) / 2.0, y: (p1.y + p2.y) / 2.0)

            let distFromStart = hypot(currentCentroid.x - initialCentroid.x, currentCentroid.y - initialCentroid.y)
            if distFromStart > maximumTapMovement {
                isPotentialTwoFingerTap = false
            }

            if !isPotentialTwoFingerTap {
                let deltaX = Float(currentCentroid.x - previousCentroid.x)
                let deltaY = Float(currentCentroid.y - previousCentroid.y)
                previousCentroid = currentCentroid

                if abs(deltaX) > 0.05 || abs(deltaY) > 0.05 {
                    let scrollPayload = ScrollEventPayload(
                        deltaX: deltaX,
                        deltaY: deltaY,
                        timestampNs: UInt64(CACurrentMediaTime() * 1_000_000_000)
                    )
                    onScrollEvent?(scrollPayload)
                }
            }

        case .none, .resetting:
            break
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let allTouches = event?.allTouches else { return }
        let remainingTouches = allTouches.filter { $0.phase != .ended && $0.phase != .cancelled }

        switch gestureState {
        case .singleFinger:
            if let active = firstTouch, touches.contains(active) {
                let location = active.location(in: self)
                let norm = renderer?.currentViewportLayout?.touchToNormalizedVideoCoordinate(location, clamp: true) ?? CGPoint(x: 0.5, y: 0.5)
                let payload = TouchEventPayload(
                    phase: .ended,
                    touchID: 0,
                    x: Float(norm.x),
                    y: Float(norm.y),
                    timestampNs: UInt64(CACurrentMediaTime() * 1_000_000_000)
                )
                onTouchEvent?(payload)
                firstTouch = nil
                secondTouch = nil
                gestureState = .none
            }

        case .twoFinger:
            guard let t1 = firstTouch, let t2 = secondTouch else {
                resetGestureState()
                return
            }

            let eitherEnded = touches.contains(t1) || touches.contains(t2)
            if eitherEnded {
                let elapsed = CACurrentMediaTime() - twoFingerStartTime
                if isPotentialTwoFingerTap && elapsed <= maximumTapDuration {
                    let rcPayload = RightClickPayload(timestampNs: UInt64(CACurrentMediaTime() * 1_000_000_000))
                    onRightClick?(rcPayload)
                }

                firstTouch = nil
                secondTouch = nil

                if remainingTouches.isEmpty {
                    gestureState = .none
                } else {
                    // Case B: One finger disappeared, remaining finger is still on screen.
                    // Transition to .resetting so the remaining finger cannot trigger a drag.
                    gestureState = .resetting
                }
            }

        case .resetting:
            if remainingTouches.isEmpty {
                gestureState = .none
            }

        case .none:
            break
        }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let allTouches = event?.allTouches else {
            resetGestureState()
            return
        }
        let remainingTouches = allTouches.filter { $0.phase != .ended && $0.phase != .cancelled }

        if gestureState == .singleFinger {
            cancelSingleFingerTouch()
        }

        firstTouch = nil
        secondTouch = nil

        if remainingTouches.isEmpty {
            gestureState = .none
        } else {
            gestureState = .resetting
        }
    }
}

public struct MirooMetalView: UIViewRepresentable {
    public let renderer: MetalRenderer
    public var onTouchEvent: ((TouchEventPayload) -> Void)?
    public var onScrollEvent: ((ScrollEventPayload) -> Void)?
    public var onRightClick: ((RightClickPayload) -> Void)?

    public init(
        renderer: MetalRenderer,
        onTouchEvent: ((TouchEventPayload) -> Void)? = nil,
        onScrollEvent: ((ScrollEventPayload) -> Void)? = nil,
        onRightClick: ((RightClickPayload) -> Void)? = nil
    ) {
        self.renderer = renderer
        self.onTouchEvent = onTouchEvent
        self.onScrollEvent = onScrollEvent
        self.onRightClick = onRightClick
    }

    public func makeUIView(context: Context) -> MirooMTKView {
        let mtkView = MirooMTKView(frame: .zero, device: renderer.device)
        mtkView.delegate = renderer
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.isMultipleTouchEnabled = true
        mtkView.isUserInteractionEnabled = true
        mtkView.renderer = renderer
        mtkView.onTouchEvent = onTouchEvent
        mtkView.onScrollEvent = onScrollEvent
        mtkView.onRightClick = onRightClick
        
        mtkView.onLayoutChange = { [weak renderer] bounds, insets in
            renderer?.updateViewLayout(bounds: bounds, safeAreaInsets: insets)
        }
        
        renderer.view = mtkView
        return mtkView
    }

    public func updateUIView(_ uiView: MirooMTKView, context: Context) {
        uiView.renderer = renderer
        uiView.onTouchEvent = onTouchEvent
        uiView.onScrollEvent = onScrollEvent
        uiView.onRightClick = onRightClick
        let effectiveInsets = uiView.window?.safeAreaInsets ?? uiView.safeAreaInsets
        renderer.updateViewLayout(bounds: uiView.bounds, safeAreaInsets: effectiveInsets)
    }
}

#elseif os(macOS)
import AppKit

public struct MirooMetalView: NSViewRepresentable {
    public let renderer: MetalRenderer
    public var onTouchEvent: ((TouchEventPayload) -> Void)?
    public var onScrollEvent: ((ScrollEventPayload) -> Void)?
    public var onRightClick: ((RightClickPayload) -> Void)?

    public init(
        renderer: MetalRenderer,
        onTouchEvent: ((TouchEventPayload) -> Void)? = nil,
        onScrollEvent: ((ScrollEventPayload) -> Void)? = nil,
        onRightClick: ((RightClickPayload) -> Void)? = nil
    ) {
        self.renderer = renderer
        self.onTouchEvent = onTouchEvent
        self.onScrollEvent = onScrollEvent
        self.onRightClick = onRightClick
    }

    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: renderer.device)
        mtkView.delegate = renderer
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderer.view = mtkView
        return mtkView
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        renderer.updateViewLayout(bounds: nsView.bounds)
    }
}
#endif
