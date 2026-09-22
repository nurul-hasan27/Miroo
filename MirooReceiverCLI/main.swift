//
//  main.swift
//  MirooReceiverCLI
//
//  Phase 5: Standalone macOS receiver tool with live VideoToolbox hardware H.264
//  decoding and zero-copy Metal GPU rendering in an NSWindow or headless telemetry mode.
//

import Foundation
import AppKit
import MetalKit
#if canImport(MirooNetworking)
import MirooNetworking
#endif

print("=======================================================")
print("     Miroo Receiver & Metal Player (Phase 5)           ")
print("=======================================================")

let isHeadless = CommandLine.arguments.contains("--headless")

let receiver = MirooReceiver(clientName: "Miroo Mac Player")
let decoder = H264Decoder()
let renderer = MetalRenderer()

receiver.onFrameReceived = { seq, pts, isKeyframe, data, timing, netRecvNs, netTransitMs, jitterMs in
    decoder.decode(
        annexBData: data,
        sequence: UInt64(seq),
        ptsNanoseconds: Int64(pts),
        isKeyframeHint: isKeyframe,
        timing: timing,
        networkReceiveTimestampNs: netRecvNs,
        networkTransitMs: netTransitMs,
        jitterMs: jitterMs
    )
}

decoder.onFrameDecoded = { frame in
    if isHeadless {
        renderer?.renderOffscreen(frame: frame)
    } else {
        renderer?.enqueueFrame(frame)
    }
}

// Telemetry output
renderer?.onTelemetryUpdate = { renderedFPS, renderLatency, decodeLatency, g2gLatency in
    print("")
    print("------------- [Miroo Live Video Player] -------------")
    print(" Rendered:   \(String(format: "%.1f", renderedFPS)) FPS")
    print(" Decode:     \(String(format: "%.2f", decodeLatency)) ms (Hardware VideoToolbox)")
    print(" Render:     \(String(format: "%.2f", renderLatency)) ms (Metal Zero-Copy)")
    print(" Est. G2G:   \(String(format: "%.2f", g2gLatency)) ms (Network + Decode + Render)")
    print(" Drops:      \(renderer?.totalDisplayDrops ?? 0)")
    print("-----------------------------------------------------")
}

// Signal handling
signal(SIGINT) { _ in
    print("\n[Receiver CLI] Interrupted. Stopping pipeline...")
    receiver.stop()
    decoder.invalidate()
    exit(0)
}

signal(SIGTERM) { _ in
    print("\n[Receiver CLI] Terminating. Stopping pipeline...")
    receiver.stop()
    decoder.invalidate()
    exit(0)
}

receiver.onConnected = { hostName in
    print("[Receiver CLI] Connected to Mac: \(hostName)")
}

receiver.onDisconnected = { error in
    print("[Receiver CLI] Disconnected: \(error?.localizedDescription ?? "Clean")")
}

print("[Receiver CLI] Starting Bonjour discovery for '_miroo._tcp'...")
receiver.start()

if isHeadless {
    print("[Receiver CLI] Running in headless telemetry mode. Press Ctrl+C to quit.")
    RunLoop.main.run()
} else {
    // Launch Cocoa App with Metal View Window
    print("[Receiver CLI] Opening live Metal preview window...")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    // Physical iPhone resolution is 1170x2532. We display at 0.5x scale (585x1266) to fit desktop comfortably.
    let windowRect = NSRect(x: 0, y: 0, width: 450, height: 974)
    let window = NSWindow(
        contentRect: windowRect,
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Miroo iPhone Secondary Display (Metal)"
    window.center()

    if let renderer = renderer {
        let mtkView = MTKView(frame: window.contentView!.bounds, device: renderer.device)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.delegate = renderer
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        window.contentView?.addSubview(mtkView)
    }

    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
}
