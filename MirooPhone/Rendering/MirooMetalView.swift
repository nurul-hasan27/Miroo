//
//  MirooMetalView.swift
//  Miroo
//
//  Phase 5: SwiftUI wrapper for MTKView supporting both iOS (UIViewRepresentable)
//  and macOS (NSViewRepresentable) for live hardware-accelerated video display.
//

import SwiftUI
import MetalKit

#if os(iOS)
import UIKit

public struct MirooMetalView: UIViewRepresentable {
    public let renderer: MetalRenderer

    public init(renderer: MetalRenderer) {
        self.renderer = renderer
    }

    public func makeUIView(context: Context) -> MTKView {
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

    public func updateUIView(_ uiView: MTKView, context: Context) {}
}

#elseif os(macOS)
import AppKit

public struct MirooMetalView: NSViewRepresentable {
    public let renderer: MetalRenderer

    public init(renderer: MetalRenderer) {
        self.renderer = renderer
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

    public func updateNSView(_ nsView: MTKView, context: Context) {}
}
#endif
