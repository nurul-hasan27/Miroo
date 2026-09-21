//
//  MirooPhoneApp.swift
//  MirooPhone
//
//  Phase 5 & 6: Ultra-low-latency iPhone Secondary Display Receiver Application.
//  Push-driven MTKView rendering, zero-copy VideoToolbox H.264 decoding,
//  and real-time diagnostic latency HUD with microsecond stage breakdown.
//

import SwiftUI
import MetalKit
import Combine

@main
struct MirooPhoneApp: App {
    @StateObject private var receiverViewModel = ReceiverViewModel()

    var body: some Scene {
        WindowGroup {
            ReceiverContentView(viewModel: receiverViewModel)
        }
    }
}

// MARK: - View Model

@MainActor
final class ReceiverViewModel: ObservableObject {
    @Published var status: String = "Idle"
    @Published var connectedHost: String? = nil
    @Published var displayDetails: String = "No display connected"
    @Published var streamDetails: String = "No stream active"
    @Published var isStreaming: Bool = false
    @Published var currentOrientation: MirooOrientation = .portrait
    @Published var showHUD: Bool = true
    @Published var diagnostics: FrameDiagnostics = FrameDiagnostics()

    let receiver = MirooReceiver(clientName: "iPhone Secondary Display")
    let decoder = H264Decoder()
    let renderer: MetalRenderer? = MetalRenderer()

    private var isStarted = false
    private var lastRequestedOrientation: MirooOrientation? = nil

    init() {
        setupPipeline()
        startReceiving()
    }

    func startReceiving() {
        guard !isStarted else { return }
        receiver.start()
        isStarted = true
        status = "Browsing for Miroo Mac..."
    }

    func toggleConnection() {
        if isStarted {
            receiver.stop()
            decoder.invalidate()
            isStarted = false
            isStreaming = false
            status = "Disconnected"
            connectedHost = nil
        } else {
            startReceiving()
        }
    }

    func updateOrientationIfNeeded(_ orientation: MirooOrientation) {
        guard orientation != lastRequestedOrientation else { return }
        lastRequestedOrientation = orientation
        currentOrientation = orientation
        print("[Miroo App] Requesting display orientation switch to: \(orientation.rawValue)")
        receiver.sendOrientation(orientation)
    }

    private func setupPipeline() {
        // 1. Connection Callbacks
        receiver.onConnected = { [weak self] hostName in
            Task { @MainActor in
                self?.status = "Connected"
                self?.connectedHost = hostName
                // If device is already in landscape upon connection, sync with Mac
                if let cur = self?.currentOrientation, cur != .portrait {
                    print("[Miroo App] Connected while in \(cur.rawValue) -> notifying Mac")
                    self?.receiver.sendOrientation(cur)
                }
            }
        }

        receiver.onDisconnected = { [weak self] _ in
            Task { @MainActor in
                self?.status = "Disconnected (Auto-reconnecting...)"
                self?.connectedHost = nil
                self?.isStreaming = false
                self?.decoder.invalidate()
            }
        }

        // Stream config updates (initial or runtime orientation change)
        receiver.onStreamConfigUpdated = { [weak self] config in
            Task { @MainActor in
                self?.streamDetails = "\(config.width)x\(config.height) (\(config.orientation.rawValue)) @ \(config.fps) FPS (\(config.codec))"
                if let orientation = MirooOrientation(rawValue: config.orientation.rawValue) {
                    self?.currentOrientation = orientation
                }
            }
        }

        // 2. High-performance frame ingestion without per-frame MainActor dispatch
        receiver.onFrameReceived = { [weak self] seq, pts, isKeyframe, data, timing, netTransitMs, jitterMs in
            guard let self = self else { return }
            self.renderer?.currentJitterMs = jitterMs
            self.renderer?.currentBitrateMbps = self.receiver.metrics.snapshot().recvThroughputMbps

            self.decoder.decode(
                annexBData: data,
                sequence: seq,
                ptsNanoseconds: pts,
                isKeyframeHint: isKeyframe,
                timing: timing,
                networkTransitMs: netTransitMs,
                jitterMs: jitterMs
            )
        }

        // 3. Decoder output -> Metal push queue
        decoder.onFrameDecoded = { [weak self] frame in
            guard let self = self else { return }
            self.renderer?.enqueueFrame(frame)

            if !self.isStreaming {
                Task { @MainActor in
                    self.isStreaming = true
                    self.status = "Streaming"
                    if let info = self.receiver.displayInfo {
                        self.displayDetails = "\(info.name) (\(info.width)x\(info.height))"
                    }
                    if let config = self.receiver.streamConfig {
                        self.streamDetails = "\(config.width)x\(config.height) @ \(config.fps) FPS (\(config.codec))"
                    }
                }
            }
        }

        // 4. Throttled ~4 Hz diagnostic telemetry updates to avoid view invalidation storms
        renderer?.onDiagnosticsUpdate = { [weak self] diag in
            Task { @MainActor in
                self?.diagnostics = diag
            }
        }
    }
}

// MARK: - SwiftUI View

struct ReceiverContentView: View {
    @ObservedObject var viewModel: ReceiverViewModel

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let detectedOrientation: MirooOrientation = isLandscape ? .landscape : .portrait

            Group {
                if viewModel.isStreaming, let renderer = viewModel.renderer {
                    // Live Metal display with low-latency HUD overlay
                    ZStack(alignment: .topLeading) {
                        Color.black.ignoresSafeArea()

                        MirooMetalView(renderer: renderer)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    viewModel.showHUD.toggle()
                                }
                            }

                        if viewModel.showHUD {
                            DiagnosticHUDView(d: viewModel.diagnostics, orientation: viewModel.currentOrientation) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    viewModel.showHUD = false
                                }
                            }
                            .padding(.top, isLandscape ? 20 : 48)
                            .padding(.leading, isLandscape ? 44 : 16)
                            .transition(.opacity)
                        }

                        // Disconnect button in top-right
                        VStack {
                            HStack {
                                Spacer()
                                Button(action: { viewModel.toggleConnection() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(8)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Circle())
                                }
                                .padding(.top, isLandscape ? 20 : 48)
                                .padding(.trailing, isLandscape ? 44 : 16)
                            }
                            Spacer()
                        }
                    }
                } else {
                    // Configuration and connection screen
                    NavigationStack {
                        List {
                            Section("Connection Status") {
                                HStack {
                                    Text("Status")
                                    Spacer()
                                    Text(viewModel.status)
                                        .foregroundColor(viewModel.status.contains("Streaming") ? .green : .secondary)
                                        .bold()
                                }
                                if let host = viewModel.connectedHost {
                                    HStack {
                                        Text("Host Mac")
                                        Spacer()
                                        Text(host).foregroundColor(.primary)
                                    }
                                }
                                HStack {
                                    Text("Active Orientation")
                                    Spacer()
                                    Text(viewModel.currentOrientation.rawValue.capitalized)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Section("Display & Stream Config") {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Display").font(.caption).foregroundColor(.secondary)
                                    Text(viewModel.displayDetails).font(.subheadline)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Stream").font(.caption).foregroundColor(.secondary)
                                    Text(viewModel.streamDetails).font(.subheadline)
                                }
                            }

                            Section("Performance Telemetry") {
                                HStack {
                                    Text("Pipeline Latency")
                                    Spacer()
                                    Text(String(format: "%.1f ms", viewModel.diagnostics.pipelineMs)).bold()
                                }
                                HStack {
                                    Text("Framerate")
                                    Spacer()
                                    Text(String(format: "%.1f FPS", viewModel.diagnostics.fps)).bold()
                                }
                                HStack {
                                    Text("Frame Jitter")
                                    Spacer()
                                    Text(String(format: "%.1f ms", viewModel.diagnostics.jitterMs)).bold()
                                }
                                HStack {
                                    Text("Throughput")
                                    Spacer()
                                    Text(String(format: "%.1f Mbps", viewModel.diagnostics.bitrateMbps)).bold()
                                }
                            }

                            Section {
                                Button(action: { viewModel.toggleConnection() }) {
                                    HStack {
                                        Spacer()
                                        Text(viewModel.status.contains("Streaming") || viewModel.status.contains("Connected") ? "Disconnect" : "Start Receiving")
                                            .bold()
                                            .foregroundColor(.white)
                                        Spacer()
                                    }
                                }
                                .listRowBackground(Color.blue)
                            }
                        }
                        .navigationTitle("Miroo Receiver")
                    }
                }
            }
            .onAppear {
                viewModel.updateOrientationIfNeeded(detectedOrientation)
            }
            .onChange(of: geo.size) { newSize in
                let newOrientation: MirooOrientation = (newSize.width > newSize.height) ? .landscape : .portrait
                viewModel.updateOrientationIfNeeded(newOrientation)
            }
        }
    }
}

// MARK: - Section 2 Diagnostic Latency HUD

struct DiagnosticHUDView: View {
    let d: FrameDiagnostics
    var orientation: MirooOrientation = .portrait
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("MIROO LATENCY")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                        .font(.system(size: 14))
                }
            }
            .padding(.bottom, 2)

            Divider().background(Color.white.opacity(0.25))

            hudRow(label: "Mode", value: "\(orientation.rawValue.capitalized)")

            hudRow(label: "Capture", value: String(format: "%.1f ms", d.captureMs))
            hudRow(label: "Encode", value: String(format: "%.1f ms", d.encodeMs))
            hudRow(label: "Network", value: String(format: "%.1f ms", d.networkMs))
            hudRow(label: "Decode", value: String(format: "%.1f ms", d.decodeMs))
            hudRow(label: "Metal", value: String(format: "%.1f ms", d.metalMs))
            hudRow(label: "Queue", value: String(format: "%.1f ms", d.queueMs))

            Divider().background(Color.white.opacity(0.25))

            hudRow(label: "Pipeline", value: String(format: "%.1f ms", d.pipelineMs), isHighlight: true)

            Divider().background(Color.white.opacity(0.25))

            hudRow(label: "FPS", value: String(format: "%.1f", d.fps))
            hudRow(label: "Frame Jitter", value: String(format: "%.1f ms", d.jitterMs))
            hudRow(label: "Dropped", value: String(format: "%.1f %%", d.dropPercentage))
            hudRow(label: "Queue Depth", value: "\(d.queueDepth) frame\(d.queueDepth == 1 ? "" : "s")")
            hudRow(label: "Bitrate", value: String(format: "%.1f Mbps", d.bitrateMbps))
        }
        .padding(12)
        .frame(width: 220)
        .background(Color.black.opacity(0.80))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
    }

    private func hudRow(label: String, value: String, isHighlight: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: isHighlight ? .bold : .regular, design: .monospaced))
                .foregroundColor(isHighlight ? .green : .white.opacity(0.85))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(isHighlight ? .green : .white)
        }
    }
}
