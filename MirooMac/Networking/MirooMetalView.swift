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

/// Custom MTKView subclass that observes safe area and bounds changes dynamically,
/// handles single-finger touch interaction with absolute normalization,
/// and immediately notifies the MetalRenderer.
public final class MirooMTKView: MTKView {
    public var onLayoutChange: ((CGRect, UIEdgeInsets) -> Void)?
    public var onTouchEvent: ((TouchEventPayload) -> Void)?
    public weak var renderer: MetalRenderer?

    private var activeTouch: UITouch?

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        cancelActiveTouchIfNeeded()
        onLayoutChange?(bounds, safeAreaInsets)
        self.draw()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutChange?(bounds, safeAreaInsets)
        self.draw()
    }

    public func cancelActiveTouchIfNeeded() {
        guard let active = activeTouch else { return }
        activeTouch = nil
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
    }

    // MARK: - Single-Finger Touch Tracking

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        let location = touch.location(in: self)
        guard let layout = renderer?.currentViewportLayout,
              let norm = layout.touchToNormalizedVideoCoordinate(location, clamp: false) else {
            // Touch began outside rendered display area (e.g. notch margins) -> ignore
            return
        }
        activeTouch = touch
        let payload = TouchEventPayload(
            phase: .began,
            touchID: 0,
            x: Float(norm.x),
            y: Float(norm.y),
            timestampNs: UInt64(CACurrentMediaTime() * 1_000_000_000)
        )
        onTouchEvent?(payload)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
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
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        activeTouch = nil
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
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        activeTouch = nil
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
    }
}

public struct MirooMetalView: UIViewRepresentable {
    public let renderer: MetalRenderer
    public var onTouchEvent: ((TouchEventPayload) -> Void)?

    public init(renderer: MetalRenderer, onTouchEvent: ((TouchEventPayload) -> Void)? = nil) {
        self.renderer = renderer
        self.onTouchEvent = onTouchEvent
    }

    public func makeUIView(context: Context) -> MirooMTKView {
        let mtkView = MirooMTKView(frame: .zero, device: renderer.device)
        mtkView.delegate = renderer
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.isMultipleTouchEnabled = false
        mtkView.isUserInteractionEnabled = true
        mtkView.renderer = renderer
        mtkView.onTouchEvent = onTouchEvent
        
        mtkView.onLayoutChange = { [weak renderer] bounds, insets in
            renderer?.updateViewLayout(bounds: bounds, safeAreaInsets: insets)
        }
        
        renderer.view = mtkView
        return mtkView
    }

    public func updateUIView(_ uiView: MirooMTKView, context: Context) {
        uiView.renderer = renderer
        uiView.onTouchEvent = onTouchEvent
        renderer.updateViewLayout(bounds: uiView.bounds, safeAreaInsets: uiView.safeAreaInsets)
    }
}

#elseif os(macOS)
import AppKit

public struct MirooMetalView: NSViewRepresentable {
    public let renderer: MetalRenderer
    public var onTouchEvent: ((TouchEventPayload) -> Void)?

    public init(renderer: MetalRenderer, onTouchEvent: ((TouchEventPayload) -> Void)? = nil) {
        self.renderer = renderer
        self.onTouchEvent = onTouchEvent
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
