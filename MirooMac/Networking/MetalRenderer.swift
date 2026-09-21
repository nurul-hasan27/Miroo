//
//  MetalRenderer.swift
//  Miroo
//
//  Phase 5: High-performance Metal renderer with CVMetalTextureCache zero-copy
//  bi-planar YUV420 to RGB GPU conversion, aspect-fit scaling, and bounded display queue.
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import os.lock
import QuartzCore

public struct DisplayUniforms {
    public var scale: SIMD2<Float>

    public init(scale: SIMD2<Float> = SIMD2<Float>(1.0, 1.0)) {
        self.scale = scale
    }
}

public final class MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {

    // MARK: - Metal Components
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?

    // Bounded Display Queue (depth 1 to guarantee zero display buffering)
    private var latestFrame: DecodedVideoFrame?
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

        // 1. Pop latest frame from display queue
        os_unfair_lock_lock(&lock)
        guard let frame = latestFrame else {
            os_unfair_lock_unlock(&lock)
            return
        }
        latestFrame = nil
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

        // 3. Compute Aspect-Fit scale uniforms
        let viewWidth = Float(view.drawableSize.width)
        let viewHeight = Float(view.drawableSize.height)
        let videoWidth = Float(frame.width)
        let videoHeight = Float(frame.height)

        var scale = SIMD2<Float>(1.0, 1.0)
        if viewWidth > 0 && viewHeight > 0 && videoWidth > 0 && videoHeight > 0 {
            let videoAspect = videoWidth / videoHeight
            let viewAspect = viewWidth / viewHeight

            if viewAspect > videoAspect {
                // View is wider than video: Pillarbox
                scale.x = videoAspect / viewAspect
            } else {
                // View is taller than video: Letterbox
                scale.y = viewAspect / videoAspect
            }
        }

        var uniforms = DisplayUniforms(scale: scale)

        // 4. Encode Metal render command
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        renderEncoder.setFragmentTexture(textureY, index: 0)
        renderEncoder.setFragmentTexture(textureUV, index: 1)

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // 5. Telemetry & Performance Tracking
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
                    bitrateMbps: currentBitrateMbps
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
