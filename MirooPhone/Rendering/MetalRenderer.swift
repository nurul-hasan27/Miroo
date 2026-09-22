//
//  MetalRenderer.swift
//  Miroo
//
//  Phase 5 & Usable Display: High-performance Metal renderer with CVMetalTextureCache zero-copy
//  bi-planar YUV420 to RGB GPU conversion, authoritative safe-area tracking, hardware MTLViewport
//  aspect-fit scaling, and notch exclusion.
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import os.lock
import QuartzCore

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Viewport & Layout Geometry

/// Encapsulates the complete layout, safe area, and transformation geometry for rendering
/// a decoded Mac display video frame within the usable area of the iPhone / host screen.
public struct RenderViewportLayout: Equatable, Sendable {
    /// Full view bounds in logical points
    public let viewBounds: CGRect

    #if os(iOS)
    /// Physical safe area insets in logical points
    public let safeAreaInsets: UIEdgeInsets
    #endif

    /// Usable viewport rectangle in logical points (bounds minus safe-area insets)
    public let usableRectPoints: CGRect

    /// Usable viewport rectangle in device pixels
    public let usableRectPixels: CGRect

    /// Native video frame size in pixels
    public let videoSize: CGSize

    /// Final aspect-fit content rectangle in logical points (used for touch mapping)
    public let contentRectPoints: CGRect

    /// Final aspect-fit render rectangle in device pixels (passed to MTLViewport / MTLScissorRect)
    public let renderRectPixels: CGRect

    /// Metal drawable size in device pixels
    public let drawableSize: CGSize

    /// Scaling factor from logical points to device pixels
    public let scaleX: CGFloat
    public let scaleY: CGFloat

    #if os(iOS)
    public init(
        viewBounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        usableRectPoints: CGRect,
        usableRectPixels: CGRect,
        videoSize: CGSize,
        contentRectPoints: CGRect,
        renderRectPixels: CGRect,
        drawableSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) {
        self.viewBounds = viewBounds
        self.safeAreaInsets = safeAreaInsets
        self.usableRectPoints = usableRectPoints
        self.usableRectPixels = usableRectPixels
        self.videoSize = videoSize
        self.contentRectPoints = contentRectPoints
        self.renderRectPixels = renderRectPixels
        self.drawableSize = drawableSize
        self.scaleX = scaleX
        self.scaleY = scaleY
    }
    #else
    public init(
        viewBounds: CGRect,
        usableRectPoints: CGRect,
        usableRectPixels: CGRect,
        videoSize: CGSize,
        contentRectPoints: CGRect,
        renderRectPixels: CGRect,
        drawableSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) {
        self.viewBounds = viewBounds
        self.usableRectPoints = usableRectPoints
        self.usableRectPixels = usableRectPixels
        self.videoSize = videoSize
        self.contentRectPoints = contentRectPoints
        self.renderRectPixels = renderRectPixels
        self.drawableSize = drawableSize
        self.scaleX = scaleX
        self.scaleY = scaleY
    }
    #endif

    #if os(iOS)
    /// Authoritative safe-area and Aspect-Fit calculation for iOS devices.
    /// Excludes notch, home indicator, and rounded corners according to UIKit insets.
    public static func compute(
        viewBounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        drawableSize: CGSize,
        videoSize: CGSize
    ) -> RenderViewportLayout {
        let scaleX: CGFloat = viewBounds.width > 0 ? (drawableSize.width / viewBounds.width) : 1.0
        let scaleY: CGFloat = viewBounds.height > 0 ? (drawableSize.height / viewBounds.height) : 1.0

        let usableX = safeAreaInsets.left
        let usableY = safeAreaInsets.top
        let usableWidth = max(0, viewBounds.width - safeAreaInsets.left - safeAreaInsets.right)
        let usableHeight = max(0, viewBounds.height - safeAreaInsets.top - safeAreaInsets.bottom)
        let usableRectPoints = CGRect(x: usableX, y: usableY, width: usableWidth, height: usableHeight)

        let usableRectPixels = CGRect(
            x: usableX * scaleX,
            y: usableY * scaleY,
            width: usableWidth * scaleX,
            height: usableHeight * scaleY
        )

        var renderRectPixels = CGRect.zero
        var contentRectPoints = CGRect.zero

        if videoSize.width > 0 && videoSize.height > 0 && usableRectPixels.width > 0 && usableRectPixels.height > 0 {
            let fitScale = min(
                usableRectPixels.width / videoSize.width,
                usableRectPixels.height / videoSize.height
            )
            let renderWidth = videoSize.width * fitScale
            let renderHeight = videoSize.height * fitScale
            let renderX = usableRectPixels.minX + (usableRectPixels.width - renderWidth) / 2.0
            let renderY = usableRectPixels.minY + (usableRectPixels.height - renderHeight) / 2.0
            renderRectPixels = CGRect(x: renderX, y: renderY, width: renderWidth, height: renderHeight)

            contentRectPoints = CGRect(
                x: renderX / scaleX,
                y: renderY / scaleY,
                width: renderWidth / scaleX,
                height: renderHeight / scaleY
            )
        }

        return RenderViewportLayout(
            viewBounds: viewBounds,
            safeAreaInsets: safeAreaInsets,
            usableRectPoints: usableRectPoints,
            usableRectPixels: usableRectPixels,
            videoSize: videoSize,
            contentRectPoints: contentRectPoints,
            renderRectPixels: renderRectPixels,
            drawableSize: drawableSize,
            scaleX: scaleX,
            scaleY: scaleY
        )
    }
    #elseif os(macOS)
    public static func compute(
        viewBounds: CGRect,
        drawableSize: CGSize,
        videoSize: CGSize
    ) -> RenderViewportLayout {
        let scaleX: CGFloat = viewBounds.width > 0 ? (drawableSize.width / viewBounds.width) : 1.0
        let scaleY: CGFloat = viewBounds.height > 0 ? (drawableSize.height / viewBounds.height) : 1.0
        let usableRectPoints = viewBounds
        let usableRectPixels = CGRect(origin: .zero, size: drawableSize)

        var renderRectPixels = CGRect.zero
        var contentRectPoints = CGRect.zero

        if videoSize.width > 0 && videoSize.height > 0 && usableRectPixels.width > 0 && usableRectPixels.height > 0 {
            let fitScale = min(
                usableRectPixels.width / videoSize.width,
                usableRectPixels.height / videoSize.height
            )
            let renderWidth = videoSize.width * fitScale
            let renderHeight = videoSize.height * fitScale
            let renderX = (usableRectPixels.width - renderWidth) / 2.0
            let renderY = (usableRectPixels.height - renderHeight) / 2.0
            renderRectPixels = CGRect(x: renderX, y: renderY, width: renderWidth, height: renderHeight)

            contentRectPoints = CGRect(
                x: renderX / scaleX,
                y: renderY / scaleY,
                width: renderWidth / scaleX,
                height: renderHeight / scaleY
            )
        }

        return RenderViewportLayout(
            viewBounds: viewBounds,
            usableRectPoints: usableRectPoints,
            usableRectPixels: usableRectPixels,
            videoSize: videoSize,
            contentRectPoints: contentRectPoints,
            renderRectPixels: renderRectPixels,
            drawableSize: drawableSize,
            scaleX: scaleX,
            scaleY: scaleY
        )
    }
    #endif

    // MARK: - Touch-to-Video Coordinate Transformation
    /// Converts a touch point on the host view (in logical points) into normalized video coordinates (0.0 ... 1.0).
    /// If clamp is false, returns nil if the touch occurred outside contentRectPoints (e.g. initial touch in notch or letterbox area).
    /// If clamp is true, clamps to [0.0, 1.0] allowing continuous drag tracking to screen edges.
    public func touchToNormalizedVideoCoordinate(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
        guard contentRectPoints.width > 0, contentRectPoints.height > 0 else { return nil }
        if !clamp && !contentRectPoints.contains(point) {
            return nil
        }
        let normX = (point.x - contentRectPoints.minX) / contentRectPoints.width
        let normY = (point.y - contentRectPoints.minY) / contentRectPoints.height
        return CGPoint(x: min(max(normX, 0.0), 1.0), y: min(max(normY, 0.0), 1.0))
    }

    /// Converts a touch point on the host view (in logical points) to Mac virtual display coordinates.
    public func touchToMacCoordinate(_ point: CGPoint, virtualDisplaySize: CGSize? = nil) -> CGPoint? {
        guard let norm = touchToNormalizedVideoCoordinate(point) else { return nil }
        let targetSize = virtualDisplaySize ?? videoSize
        return CGPoint(x: norm.x * targetSize.width, y: norm.y * targetSize.height)
    }
}

// MARK: - Display Uniforms

public struct DisplayUniforms {
    public var scale: SIMD2<Float>

    public init(scale: SIMD2<Float> = SIMD2<Float>(1.0, 1.0)) {
        self.scale = scale
    }
}

// MARK: - Metal Renderer

public final class MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {

    // MARK: - Metal Components
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?

    // Bounded Display Queue (depth 1 to guarantee zero display buffering)
    private var latestFrame: DecodedVideoFrame?
    private var lastRenderedFrame: DecodedVideoFrame?
    private var lock = os_unfair_lock_s()

    // Telemetry & Metrics
    private(set) public var totalFramesRendered: UInt64 = 0
    private(set) public var totalDisplayDrops: UInt64 = 0
    private(set) public var averageRenderLatencyMs: Double = 0.0
    private(set) public var lastGlassToGlassEstimateMs: Double = 0.0

    private var intervalRenderedFrames: UInt64 = 0
    private var intervalRenderLatencySum: Double = 0.0
    private var lastIntervalTime: CFTimeInterval = CACurrentMediaTime()

    // Push-driven rendering view reference
    weak public var view: MTKView?

    // Diagnostics & Stage Latency Tracking
    public var currentJitterMs: Double = 0.5
    public var currentBitrateMbps: Double = 15.0
    public var onDiagnosticsUpdate: ((FrameDiagnostics) -> Void)?

    private var avgCaptureMs: Double = 1.5
    private var avgEncodeMs: Double = 3.2
    private var avgNetworkMs: Double = 2.0
    private var avgDecodeMs: Double = 3.0
    private var avgMetalMs: Double = 0.5
    private var avgQueueMs: Double = 0.2
    private var currentFps: Double = 60.0

    // Callback for live UI telemetry updates
    public var onTelemetryUpdate: ((_ renderedFPS: Double, _ renderLatencyMs: Double, _ decodeLatencyMs: Double, _ g2gEstimateMs: Double) -> Void)?

    // Authoritative Viewport & Safe-Area Layout
    public private(set) var currentViewportLayout: RenderViewportLayout?
    private var cachedViewBounds: CGRect = .zero
    #if os(iOS)
    private var cachedSafeAreaInsets: UIEdgeInsets?
    #endif
    private var lastLoggedLayout: RenderViewportLayout?

    #if os(iOS)
    public func updateViewLayout(bounds: CGRect, safeAreaInsets: UIEdgeInsets) {
        self.cachedViewBounds = bounds
        if safeAreaInsets != .zero {
            self.cachedSafeAreaInsets = safeAreaInsets
        }
    }
    #elseif os(macOS)
    public func updateViewLayout(bounds: CGRect) {
        self.cachedViewBounds = bounds
    }
    #endif

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device = device,
              let queue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        super.init()

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if cacheStatus != kCVReturnSuccess {
            print("[Miroo Renderer] ERROR: CVMetalTextureCacheCreate failed: \(cacheStatus)")
        }
        self.textureCache = cache

        setupPipeline()
    }

    // MARK: - Pipeline Setup

    private func setupPipeline() {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOutput {
            float4 position [[position]];
            float2 texCoord;
        };

        struct DisplayUniforms {
            float2 scale;
        };

        vertex VertexOutput videoVertexShader(
            uint vertexID [[vertex_id]],
            constant DisplayUniforms &uniforms [[buffer(0)]]
        ) {
            float2 basePositions[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };

            float2 texCoords[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            VertexOutput out;
            out.position = float4(basePositions[vertexID] * uniforms.scale, 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        fragment float4 videoFragmentShader(
            VertexOutput in [[stage_in]],
            texture2d<float> textureY  [[texture(0)]],
            texture2d<float> textureUV [[texture(1)]]
        ) {
            constexpr sampler linearSampler(
                coord::normalized,
                address::clamp_to_edge,
                filter::linear
            );

            float y = textureY.sample(linearSampler, in.texCoord).r;
            float2 uv = textureUV.sample(linearSampler, in.texCoord).rg;

            // BT.709 Video Range to RGB
            float3 yuv;
            yuv.x = y - (16.0 / 255.0);
            yuv.y = uv.x - (128.0 / 255.0);
            yuv.z = uv.y - (128.0 / 255.0);

            float3 rgb;
            rgb.r = 1.164383 * yuv.x + 1.792741 * yuv.z;
            rgb.g = 1.164383 * yuv.x - 0.213249 * yuv.y - 0.532909 * yuv.z;
            rgb.b = 1.164383 * yuv.x + 2.112402 * yuv.y;

            return float4(clamp(rgb, 0.0, 1.0), 1.0);
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let vertexFunction = library.makeFunction(name: "videoVertexShader"),
                  let fragmentFunction = library.makeFunction(name: "videoFragmentShader") else {
                print("[Miroo Renderer] ERROR: Failed to find shader functions in Metal library.")
                return
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "MirooVideoPipeline"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            print("[Miroo Renderer] Metal render pipeline initialized successfully.")
        } catch {
            print("[Miroo Renderer] ERROR: Failed to compile Metal pipeline: \(error.localizedDescription)")
        }
    }

    // MARK: - Frame Ingestion

    /// Submits a newly decoded frame to the bounded display queue.
    public func enqueueFrame(_ frame: DecodedVideoFrame) {
        os_unfair_lock_lock(&lock)
        if latestFrame != nil {
            totalDisplayDrops += 1
        }
        latestFrame = frame
        os_unfair_lock_unlock(&lock)

        // Push-driven rendering: immediately trigger MTKView redraw on main thread
        DispatchQueue.main.async { [weak self] in
            self?.view?.draw()
        }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let renderStartTime = CACurrentMediaTime()

        // 1. Pop latest frame or retain last rendered frame for seamless layout redraw
        os_unfair_lock_lock(&lock)
        let frame: DecodedVideoFrame
        let isNewFrame: Bool
        if let next = latestFrame {
            frame = next
            latestFrame = nil
            lastRenderedFrame = next
            isNewFrame = true
        } else if let cached = lastRenderedFrame {
            frame = cached
            isNewFrame = false
        } else {
            os_unfair_lock_unlock(&lock)
            return
        }
        os_unfair_lock_unlock(&lock)

        // 2. Obtain textures from CVPixelBuffer using CVMetalTextureCache
        guard let cache = textureCache,
              let pipelineState = pipelineState,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        let pixelBuffer = frame.pixelBuffer
        let widthY = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let heightY = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let widthUV = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let heightUV = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        var cvTextureY: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .r8Unorm,
            widthY,
            heightY,
            0,
            &cvTextureY
        )

        var cvTextureUV: CVMetalTexture?
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            widthUV,
            heightUV,
            1,
            &cvTextureUV
        )

        guard yStatus == kCVReturnSuccess,
              uvStatus == kCVReturnSuccess,
              let cvY = cvTextureY,
              let cvUV = cvTextureUV,
              let textureY = CVMetalTextureGetTexture(cvY),
              let textureUV = CVMetalTextureGetTexture(cvUV) else {
            return
        }

        // 3. Authoritative Safe-Area & Aspect-Fit Layout Calculation
        let viewBounds = (view.bounds.width > 0 && view.bounds.height > 0) ? view.bounds : cachedViewBounds
        let videoSize = CGSize(width: frame.width, height: frame.height)

        #if os(iOS)
        var insets = view.safeAreaInsets
        if insets == .zero, let cached = cachedSafeAreaInsets, cached != .zero {
            insets = cached
        } else if insets == .zero, let winInsets = view.window?.safeAreaInsets, winInsets != .zero {
            insets = winInsets
        }
        let layout = RenderViewportLayout.compute(
            viewBounds: viewBounds,
            safeAreaInsets: insets,
            drawableSize: view.drawableSize,
            videoSize: videoSize
        )
        #elseif os(macOS)
        let layout = RenderViewportLayout.compute(
            viewBounds: viewBounds,
            drawableSize: view.drawableSize,
            videoSize: videoSize
        )
        #endif

        self.currentViewportLayout = layout

        guard layout.renderRectPixels.width > 0, layout.renderRectPixels.height > 0 else {
            return
        }

        // Log layout telemetry when orientation or viewport changes
        if lastLoggedLayout != layout {
            lastLoggedLayout = layout
            #if os(iOS)
            let topPx = Int(round(layout.safeAreaInsets.top * layout.scaleY))
            let btmPx = Int(round(layout.safeAreaInsets.bottom * layout.scaleY))
            let lftPx = Int(round(layout.safeAreaInsets.left * layout.scaleX))
            let rgtPx = Int(round(layout.safeAreaInsets.right * layout.scaleX))
            let orient = (layout.drawableSize.width > layout.drawableSize.height) ? "Landscape" : "Portrait"
            print("""
            [Miroo Layout]
            Screen: \(Int(layout.drawableSize.width)) × \(Int(layout.drawableSize.height))
            Safe Area: top=\(topPx), bottom=\(btmPx), left=\(lftPx), right=\(rgtPx)
            Usable: \(Int(layout.usableRectPixels.width)) × \(Int(layout.usableRectPixels.height))
            Video: \(Int(layout.videoSize.width)) × \(Int(layout.videoSize.height))
            RenderRect: x=\(Int(layout.renderRectPixels.minX)), y=\(Int(layout.renderRectPixels.minY)), w=\(Int(layout.renderRectPixels.width)), h=\(Int(layout.renderRectPixels.height))
            Orientation: \(orient)
            """)
            #endif
        }

        // 4. Encode Metal render command with hardware viewport and scissor clipping
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)

        // Set hardware viewport to the exact aspect-fit render rectangle inside safe area
        let viewport = MTLViewport(
            originX: Double(layout.renderRectPixels.origin.x),
            originY: Double(layout.renderRectPixels.origin.y),
            width: Double(layout.renderRectPixels.width),
            height: Double(layout.renderRectPixels.height),
            znear: 0.0,
            zfar: 1.0
        )
        renderEncoder.setViewport(viewport)

        // Restrict rasterization to prevent any bleed into the notch/margins
        let scissorX = max(0, Int(layout.renderRectPixels.minX))
        let scissorY = max(0, Int(layout.renderRectPixels.minY))
        let scissorW = min(Int(view.drawableSize.width) - scissorX, max(1, Int(layout.renderRectPixels.width)))
        let scissorH = min(Int(view.drawableSize.height) - scissorY, max(1, Int(layout.renderRectPixels.height)))
        renderEncoder.setScissorRect(MTLScissorRect(x: scissorX, y: scissorY, width: scissorW, height: scissorH))

        // Normalized quad vertices scaled 1:1 inside the custom viewport
        var uniforms = DisplayUniforms(scale: SIMD2<Float>(1.0, 1.0))
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        renderEncoder.setFragmentTexture(textureY, index: 0)
        renderEncoder.setFragmentTexture(textureUV, index: 1)

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // 5. Telemetry & Performance Tracking
        guard isNewFrame else { return }

        let renderLatencyMs = (CACurrentMediaTime() - renderStartTime) * 1000.0
        totalFramesRendered += 1
        intervalRenderedFrames += 1
        intervalRenderLatencySum += renderLatencyMs

        // Update exponential moving averages for smooth HUD display
        avgCaptureMs = 0.9 * avgCaptureMs + 0.1 * max(0.5, frame.captureMs)
        avgEncodeMs = 0.9 * avgEncodeMs + 0.1 * max(1.0, frame.encodeMs)
        avgQueueMs = 0.9 * avgQueueMs + 0.1 * max(0.1, frame.queueMs)
        avgNetworkMs = 0.9 * avgNetworkMs + 0.1 * max(0.5, frame.networkMs)
        avgDecodeMs = 0.9 * avgDecodeMs + 0.1 * max(1.0, frame.decodeDurationMs)
        avgMetalMs = 0.9 * avgMetalMs + 0.1 * max(0.1, renderLatencyMs)

        let pipelineSum = avgCaptureMs + avgEncodeMs + avgQueueMs + avgNetworkMs + avgDecodeMs + avgMetalMs
        lastGlassToGlassEstimateMs = pipelineSum

        // Periodically emit telemetry & diagnostics (~4 Hz) to keep SwiftUI smooth
        if totalFramesRendered % 15 == 0 {
            let now = CACurrentMediaTime()
            let elapsed = max(0.001, now - lastIntervalTime)
            if elapsed >= 0.20 {
                currentFps = Double(intervalRenderedFrames) / elapsed
                averageRenderLatencyMs = intervalRenderLatencySum / Double(max(1, intervalRenderedFrames))

                lastIntervalTime = now
                intervalRenderedFrames = 0
                intervalRenderLatencySum = 0

                let totalExpected = totalFramesRendered + totalDisplayDrops
                let dropPct = totalExpected > 0 ? (Double(totalDisplayDrops) / Double(totalExpected)) * 100.0 : 0.0

                let screenPx = "\(Int(layout.drawableSize.width))×\(Int(layout.drawableSize.height))"
                var safeAreaStr = ""
                #if os(iOS)
                let topPx = Int(round(layout.safeAreaInsets.top * layout.scaleY))
                let btmPx = Int(round(layout.safeAreaInsets.bottom * layout.scaleY))
                let lftPx = Int(round(layout.safeAreaInsets.left * layout.scaleX))
                let rgtPx = Int(round(layout.safeAreaInsets.right * layout.scaleX))
                safeAreaStr = "T:\(topPx) B:\(btmPx) L:\(lftPx) R:\(rgtPx)"
                #else
                safeAreaStr = "0,0,0,0"
                #endif
                let usableStr = "\(Int(layout.usableRectPixels.width))×\(Int(layout.usableRectPixels.height))"
                let videoStr = "\(Int(layout.videoSize.width))×\(Int(layout.videoSize.height))"
                let renderStr = "\(Int(layout.renderRectPixels.minX)),\(Int(layout.renderRectPixels.minY)) \(Int(layout.renderRectPixels.width))×\(Int(layout.renderRectPixels.height))"

                let diag = FrameDiagnostics(
                    captureMs: avgCaptureMs,
                    encodeMs: avgEncodeMs,
                    networkMs: avgNetworkMs,
                    decodeMs: avgDecodeMs,
                    metalMs: avgMetalMs,
                    queueMs: avgQueueMs,
                    pipelineMs: pipelineSum,
                    fps: currentFps,
                    jitterMs: currentJitterMs,
                    dropPercentage: dropPct,
                    queueDepth: 1,
                    bitrateMbps: currentBitrateMbps,
                    screenPixelsStr: screenPx,
                    safeAreaInsetsStr: safeAreaStr,
                    usableViewportStr: usableStr,
                    videoSizeStr: videoStr,
                    renderRectStr: renderStr
                )

                onDiagnosticsUpdate?(diag)
                onTelemetryUpdate?(currentFps, averageRenderLatencyMs, avgDecodeMs, pipelineSum)
            }
        }
    }

    // MARK: - Offscreen Metal Rendering (Headless Testing & Telemetry)

    private var offscreenTexture: MTLTexture?

    /// Renders a decoded frame through the Metal GPU shader pipeline offscreen.
    /// Used for benchmarking, headless testing, and accurate GPU render latency telemetry.
    public func renderOffscreen(frame: DecodedVideoFrame, outputWidth: Int = 585, outputHeight: Int = 1266) {
        let renderStartTime = CACurrentMediaTime()

        if offscreenTexture == nil || offscreenTexture?.width != outputWidth || offscreenTexture?.height != outputHeight {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: outputWidth, height: outputHeight, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            self.offscreenTexture = device.makeTexture(descriptor: desc)
        }

        guard let offscreen = offscreenTexture,
              let cache = textureCache,
              let pipelineState = pipelineState else { return }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = offscreen
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let pixelBuffer = frame.pixelBuffer
        let widthY = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let heightY = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let widthUV = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let heightUV = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        var cvTextureY: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .r8Unorm, widthY, heightY, 0, &cvTextureY)
        var cvTextureUV: CVMetalTexture?
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .rg8Unorm, widthUV, heightUV, 1, &cvTextureUV)

        guard yStatus == kCVReturnSuccess, uvStatus == kCVReturnSuccess,
              let cvY = cvTextureY, let cvUV = cvTextureUV,
              let textureY = CVMetalTextureGetTexture(cvY),
              let textureUV = CVMetalTextureGetTexture(cvUV) else { return }

        var scale = SIMD2<Float>(1.0, 1.0)
        let videoAspect = Float(frame.width) / Float(frame.height)
        let viewAspect = Float(outputWidth) / Float(outputHeight)
        if viewAspect > videoAspect {
            scale.x = videoAspect / viewAspect
        } else {
            scale.y = viewAspect / videoAspect
        }
        var uniforms = DisplayUniforms(scale: scale)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        renderEncoder.setFragmentTexture(textureY, index: 0)
        renderEncoder.setFragmentTexture(textureUV, index: 1)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let renderLatencyMs = (CACurrentMediaTime() - renderStartTime) * 1000.0
        totalFramesRendered += 1
        intervalRenderedFrames += 1
        intervalRenderLatencySum += renderLatencyMs

        if frame.captureTimestampNs > 0 {
            let ptsSeconds = Double(frame.captureTimestampNs) / 1_000_000_000.0
            let nowSeconds = CACurrentMediaTime()
            let estG2G = max(0.0, (nowSeconds - ptsSeconds) * 1000.0)
            lastGlassToGlassEstimateMs = estG2G
        }

        if totalFramesRendered % 60 == 0 {
            let now = CACurrentMediaTime()
            let elapsed = max(0.001, now - lastIntervalTime)
            let fps = Double(intervalRenderedFrames) / elapsed
            averageRenderLatencyMs = intervalRenderLatencySum / Double(max(1, intervalRenderedFrames))

            lastIntervalTime = now
            intervalRenderedFrames = 0
            intervalRenderLatencySum = 0

            print("[Miroo Renderer] Rendered #\(totalFramesRendered) (~Int(fps): \(Int(round(fps))) FPS, render: \(String(format: "%.2f", averageRenderLatencyMs)) ms, decode: \(String(format: "%.2f", frame.decodeDurationMs)) ms, est G2G: \(String(format: "%.2f", lastGlassToGlassEstimateMs)) ms, drops: \(totalDisplayDrops))")

            onTelemetryUpdate?(fps, averageRenderLatencyMs, frame.decodeDurationMs, lastGlassToGlassEstimateMs)
        }
    }
}
