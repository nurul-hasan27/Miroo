//
//  MirooPhoneApp.swift
//  MirooPhone
//
//  Phase 10: Production UX, Connection Lifecycle & Reliability Hardening.
//  Clean native Apple-style connection UI, automatic Mac discovery,
//  one-tap "Start Receiving", seamless USB/Wi-Fi fallback, and discrete debug mode.
//

import SwiftUI
import MetalKit
import Combine

@main
struct MirooPhoneApp: App {
    @StateObject private var receiverViewModel = ReceiverViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ReceiverContentView(viewModel: receiverViewModel)
                .onChange(of: scenePhase) { newPhase in
                    if newPhase != .active {
                        receiverViewModel.sendCancelTouch()
                    }
                }
        }
    }
}

// MARK: - View Model

@MainActor
final class ReceiverViewModel: ObservableObject {
    @Published var lifecycleState: ConnectionLifecycleState = .idle
    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var selectedHost: DiscoveredHost? = nil
    @Published var connectedHost: String? = nil
    @Published var displayDetails: String = "No display connected"
    @Published var streamDetails: String = "No stream active"
    @Published var isStreaming: Bool = false
    @Published var currentOrientation: MirooOrientation = .portrait
    @Published var showDebugHUD: Bool = false
    @Published var diagnostics: FrameDiagnostics = FrameDiagnostics()
    @Published var transportType: String = "TCP"
    @Published var errorMessage: String? = nil

    let receiver = MirooReceiver(clientName: "iPhone Secondary Display")
    let decoder = H264Decoder()
    let renderer: MetalRenderer? = MetalRenderer()

    private var lastRequestedOrientation: MirooOrientation? = nil
    private var userStoppedManually: Bool = false

    init() {
        setupPipeline()
        startDiscovery()
    }

    func startDiscovery() {
        errorMessage = nil
        userStoppedManually = false
        receiver.startDiscovery()
    }

    func startReceiving() {
        errorMessage = nil
        userStoppedManually = false
        receiver.startReceiving(targetHost: selectedHost)
    }

    func stopReceiving() {
        userStoppedManually = true
        receiver.stopReceiving()
        decoder.invalidate()
        isStreaming = false
        connectedHost = nil
    }

    func retry() {
        errorMessage = nil
        if selectedHost != nil || !discoveredHosts.isEmpty {
            startReceiving()
        } else {
            startDiscovery()
        }
    }

    func updateOrientationIfNeeded(_ orientation: MirooOrientation) {
        guard orientation != lastRequestedOrientation else { return }
        lastRequestedOrientation = orientation
        currentOrientation = orientation
        print("[Miroo App] Requesting display orientation switch to: \(orientation.rawValue)")
        receiver.sendOrientation(orientation)
    }

    func forceOrientation(_ orientation: MirooOrientation) {
        lastRequestedOrientation = orientation
        currentOrientation = orientation
        print("[Miroo App] Explicitly forcing orientation switch to: \(orientation.rawValue)")
        receiver.sendOrientation(orientation)
    }

    func sendTouchEvent(_ payload: TouchEventPayload) {
        receiver.sendTouchEvent(payload)
    }

    func sendScrollEvent(_ payload: ScrollEventPayload) {
        receiver.sendScrollEvent(payload)
    }

    func sendRightClick(_ payload: RightClickPayload) {
        receiver.sendRightClick(payload)
    }

    func sendCancelTouch() {
        let payload = TouchEventPayload(
            phase: .cancelled,
            touchID: 0,
            x: 0.5,
            y: 0.5,
            timestampNs: UInt64(CACurrentMediaTime() * 1_000_000_000)
        )
        receiver.sendTouchEvent(payload)
    }

    private func setupPipeline() {
        // 1. Connection Lifecycle Transitions
        receiver.onLifecycleChanged = { [weak self] newState in
            Task { @MainActor in
                self?.lifecycleState = newState
                switch newState {
                case .connected(let host, let transport):
                    self?.connectedHost = host
                    self?.transportType = transport.rawValue
                    self?.isStreaming = true
                    self?.errorMessage = nil
                    PipelineBenchmark.shared.activeTransport = transport.rawValue

                    // Sync orientation with Mac if already in landscape
                    if let cur = self?.currentOrientation, cur != .portrait {
                        self?.receiver.sendOrientation(cur)
                    }

                case .connecting(let target, let transport):
                    self?.transportType = transport.rawValue
                    self?.connectedHost = target

                case .error(let message):
                    self?.errorMessage = message
                    self?.isStreaming = false

                case .disconnected:
                    self?.isStreaming = false
                    self?.decoder.invalidate()

                case .reconnecting:
                    // Keep existing frame buffer or show reconnecting overlay
                    break

                default:
                    break
                }
            }
        }

        // 2. Discovered Hosts Update
        receiver.onDiscoveredHostsUpdated = { [weak self] hosts in
            Task { @MainActor in
                guard let self = self else { return }
                self.discoveredHosts = hosts
                if self.selectedHost == nil || !hosts.contains(where: { $0.id == self.selectedHost?.id }) {
                    // Automatically prefer USB if available, otherwise first discovered host
                    self.selectedHost = hosts.first(where: { $0.isUSB }) ?? hosts.first
                }

                // Seamless connection to available Mac
                if let host = self.selectedHost, !self.isStreaming, !self.lifecycleState.isConnecting, !self.userStoppedManually {
                    print("[Miroo App] Auto-connecting to discovered host: \(host.name)")
                    self.startReceiving()
                }
            }
        }

        // 3. Backward-compatible Connection Callbacks
        receiver.onConnected = { [weak self] hostName in
            Task { @MainActor in
                self?.connectedHost = hostName
            }
        }

        receiver.onDisconnected = { [weak self] _ in
            Task { @MainActor in
                self?.sendCancelTouch()
            }
        }

        // 4. High-performance frame ingestion
        receiver.onFrameReceived = { [weak self] seq, pts, isKeyframe, data, timing, netRecvNs, netTransitMs, jitterMs in
            guard let self = self else { return }
            self.renderer?.currentJitterMs = jitterMs
            let snap = self.receiver.metrics.snapshot()
            self.renderer?.currentBitrateMbps = snap.recvThroughputMbps
            self.renderer?.currentKeyframeRequests = self.receiver.totalKeyframeRequestsSent
            self.renderer?.currentPacketLossCount = self.receiver.totalDetectedGaps
            let lossRate = (snap.framesReceived > 0) ? Double(self.receiver.totalDetectedGaps) / Double(snap.framesReceived + self.receiver.totalDetectedGaps) : 0.0
            self.renderer?.currentPacketLossRate = lossRate
            self.renderer?.currentAdaptiveState = self.receiver.adaptiveController.state.rawValue
            self.renderer?.targetFps = Double(self.receiver.adaptiveController.currentTargetFPS)

            self.decoder.decode(
                annexBData: data,
                sequence: seq,
                ptsNanoseconds: pts,
                isKeyframeHint: isKeyframe,
                timing: timing,
                networkReceiveTimestampNs: netRecvNs,
                networkTransitMs: netTransitMs,
                jitterMs: jitterMs
            )
        }

        // 5. Decoder output -> Metal push queue
        decoder.onFrameDecoded = { [weak self] frame in
            guard let self = self else { return }
            self.renderer?.enqueueFrame(frame)

            if !self.isStreaming {
                Task { @MainActor in
                    self.isStreaming = true
                    let isUSB = self.receiver.isUSBActive || self.receiver.currentTransportType == .usb
                    self.transportType = isUSB ? "USB" : self.receiver.currentTransportType.rawValue
                    PipelineBenchmark.shared.activeTransport = self.transportType
                    if let info = self.receiver.displayInfo {
                        self.displayDetails = "\(info.name) (\(info.width)x\(info.height))"
                    }
                    if let config = self.receiver.streamConfig {
                        self.streamDetails = "\(config.width)x\(config.height) @ \(config.fps) FPS (\(config.codec)) [\(config.transport)]"
                        self.transportType = config.transport
                        PipelineBenchmark.shared.activeTransport = config.transport
                    }
                }
            }
        }

        decoder.onKeyframeNeeded = { [weak self] in
            self?.receiver.requestKeyframe(reason: "decode_error")
        }

        // 6. Throttled diagnostic telemetry updates
        renderer?.onDiagnosticsUpdate = { [weak self] diag in
            Task { @MainActor in
                self?.diagnostics = diag
                self?.transportType = self?.receiver.currentTransportType.rawValue ?? "TCP"
                PipelineBenchmark.shared.activeTransport = self?.transportType ?? "TCP"
            }
        }

        renderer?.onBenchmarkReportGenerated = { [weak self] report in
            if let json = report.toJSONString() {
                self?.receiver.sendBenchmarkReport(json)
            }
        }
    }
}

// MARK: - SwiftUI View

struct ReceiverContentView: View {
    @ObservedObject var viewModel: ReceiverViewModel
    @State private var showControlsOverlay: Bool = true
    @State private var hideControlsTimer: Timer? = nil

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let detectedOrientation: MirooOrientation = isLandscape ? .landscape : .portrait

            Group {
                if viewModel.isStreaming, let renderer = viewModel.renderer {
                    // Streaming Experience
                    ZStack(alignment: .top) {
                        Color.black

                        MirooMetalView(
                            renderer: renderer,
                            onTouchEvent: { payload in
                                viewModel.sendTouchEvent(payload)
                            },
                            onScrollEvent: { payload in
                                viewModel.sendScrollEvent(payload)
                            },
                            onRightClick: { payload in
                                viewModel.sendRightClick(payload)
                            }
                        )
                        .frame(width: geo.size.width, height: geo.size.height)

                        // Reconnection Banner
                        if viewModel.lifecycleState.isReconnecting {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                                Text(viewModel.lifecycleState.userFriendlyMessage)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                Spacer()
                                Button("Cancel") {
                                    viewModel.stopReceiving()
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.yellow)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                            .padding(.top, isLandscape ? 12 : 50)
                            .padding(.horizontal, 24)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // Top Minimal Floating Pill Bar
                        if showControlsOverlay {
                            HStack(spacing: 12) {
                                // Status Indicator
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(viewModel.transportType == "USB" ? Color.yellow : Color.green)
                                        .frame(width: 8, height: 8)
                                    Text(viewModel.connectedHost ?? "Mac")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("·")
                                        .foregroundColor(.white.opacity(0.6))
                                    Text(viewModel.transportType)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(viewModel.transportType == "USB" ? .yellow : .green)
                                }

                                Spacer()

                                // Optional Subtle Telemetry
                                if viewModel.diagnostics.fps > 0 {
                                    Text(String(format: "%.0f FPS · %.0f ms", viewModel.diagnostics.fps, viewModel.diagnostics.pipelineMs))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.75))
                                }

                                // Debug HUD Toggle
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        viewModel.showDebugHUD.toggle()
                                    }
                                }) {
                                    Image(systemName: "chart.xyaxis.line")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(viewModel.showDebugHUD ? .yellow : .white.opacity(0.8))
                                        .padding(6)
                                        .background(Circle().fill(Color.white.opacity(0.15)))
                                }

                                // Collapse Overlay Button
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showControlsOverlay = false
                                    }
                                }) {
                                    Image(systemName: "chevron.compact.up")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(6)
                                        .background(Circle().fill(Color.white.opacity(0.15)))
                                }

                                // Stop Receiving Button
                                Button(action: {
                                    viewModel.stopReceiving()
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(7)
                                        .background(Circle().fill(Color.white.opacity(0.2)))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(24)
                            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
                            .padding(.top, isLandscape ? 12 : 50)
                            .padding(.horizontal, 20)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        } else {
                            // Discreet Top Handle when collapsed
                            Button(action: {
                                withAnimation(.spring()) {
                                    showControlsOverlay = true
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(viewModel.transportType == "USB" ? Color.yellow : Color.green)
                                        .frame(width: 6, height: 6)
                                    Text(viewModel.connectedHost ?? "Mac")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.8))
                                    Image(systemName: "chevron.compact.down")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial)
                                .cornerRadius(14)
                                .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
                            }
                            .padding(.top, isLandscape ? 8 : 46)
                            .transition(.opacity)
                        }

                        // Debug HUD Overlay
                        if viewModel.showDebugHUD {
                            DiagnosticHUDView(
                                d: viewModel.diagnostics,
                                orientation: viewModel.currentOrientation,
                                transport: viewModel.transportType,
                                onDismiss: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        viewModel.showDebugHUD = false
                                    }
                                },
                                onToggleOrientation: {
                                    let next: MirooOrientation = (viewModel.currentOrientation == .portrait) ? .landscape : .portrait
                                    viewModel.forceOrientation(next)
                                }
                            )
                            .padding(.top, isLandscape ? 56 : 100)
                            .padding(.leading, isLandscape ? 44 : 16)
                            .transition(.opacity)
                        }
                    }
                } else {
                    // Production Connection Screen
                    NavigationStack {
                        VStack(spacing: 24) {
                            // Header
                            VStack(spacing: 6) {
                                Image(systemName: "display.2")
                                    .font(.system(size: 54))
                                    .foregroundColor(.blue)
                                    .padding(.bottom, 4)

                                Text("Miroo")
                                    .font(.system(size: 32, weight: .bold))

                                Text("Ultra-Low Latency Secondary Display")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 24)

                            // Error Banner
                            if let error = viewModel.errorMessage {
                                HStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(error)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.primary)
                                    }
                                    Spacer()
                                    Button("Retry") {
                                        viewModel.retry()
                                    }
                                    .font(.system(size: 12, weight: .bold))
                                    .buttonStyle(.bordered)
                                }
                                .padding(12)
                                .background(Color.orange.opacity(0.12))
                                .cornerRadius(12)
                                .padding(.horizontal)
                            }

                            // Discovered Hosts List
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("AVAILABLE MACS")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    if viewModel.lifecycleState.isSearching {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    }
                                }
                                .padding(.horizontal)

                                if viewModel.discoveredHosts.isEmpty {
                                    VStack(spacing: 12) {
                                        ProgressView()
                                            .scaleEffect(1.0)
                                            .padding(.top, 12)
                                        Text("Looking for your Mac...")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        Text("Ensure Miroo is running on your Mac and connected via USB or Wi-Fi.")
                                            .font(.caption)
                                            .foregroundColor(.secondary.opacity(0.8))
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 24)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 120)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                                    .cornerRadius(16)
                                    .padding(.horizontal)
                                } else {
                                    VStack(spacing: 8) {
                                        ForEach(viewModel.discoveredHosts) { host in
                                            Button(action: {
                                                viewModel.selectedHost = host
                                            }) {
                                                HStack(spacing: 14) {
                                                    Image(systemName: "laptopcomputer")
                                                        .font(.system(size: 24))
                                                        .foregroundColor(.blue)

                                                    VStack(alignment: .leading, spacing: 3) {
                                                        Text(host.name)
                                                            .font(.system(size: 16, weight: .semibold))
                                                            .foregroundColor(.primary)

                                                        Text(host.isUSB ? "USB Connected · Ultra-Low Latency" : "Wi-Fi Network")
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                    }

                                                    Spacer()

                                                    // Badge
                                                    Text(host.isUSB ? "USB" : "Wi-Fi")
                                                        .font(.system(size: 11, weight: .bold))
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(host.isUSB ? Color.yellow.opacity(0.2) : Color.blue.opacity(0.12))
                                                        .foregroundColor(host.isUSB ? .orange : .blue)
                                                        .cornerRadius(8)

                                                    if viewModel.selectedHost?.id == host.id {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .foregroundColor(.blue)
                                                    }
                                                }
                                                .padding(14)
                                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                                                .cornerRadius(14)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 14)
                                                        .stroke(viewModel.selectedHost?.id == host.id ? Color.blue : Color.clear, lineWidth: 2)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }

                            Spacer()

                            // Primary Action Button
                            VStack(spacing: 12) {
                                Button(action: {
                                    viewModel.startReceiving()
                                }) {
                                    HStack {
                                        Spacer()
                                        if viewModel.lifecycleState.isConnecting {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                                .padding(.trailing, 6)
                                            Text(viewModel.lifecycleState.userFriendlyMessage)
                                                .font(.headline)
                                                .foregroundColor(.white)
                                        } else {
                                            Text("Start Receiving")
                                                .font(.headline)
                                                .foregroundColor(.white)
                                        }
                                        Spacer()
                                    }
                                    .frame(height: 52)
                                    .background(viewModel.selectedHost != nil ? Color.blue : Color.gray)
                                    .cornerRadius(14)
                                }
                                .disabled(viewModel.selectedHost == nil || viewModel.lifecycleState.isConnecting)

                                HStack {
                                    Text("Orientation:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(viewModel.currentOrientation.rawValue.capitalized)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Button(action: {
                                        viewModel.showDebugHUD.toggle()
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "wrench.and.screwdriver")
                                            Text("Debug HUD")
                                        }
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 6)
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 20)
                        }
                        .background(Color(uiColor: .systemGroupedBackground))
                        .navigationBarHidden(true)
                    }
                }
            }
            .onAppear {
                viewModel.updateOrientationIfNeeded(detectedOrientation)
                resetControlsTimer()
            }
            .onChange(of: geo.size) { newSize in
                let newOrientation: MirooOrientation = (newSize.width > newSize.height) ? .landscape : .portrait
                viewModel.updateOrientationIfNeeded(newOrientation)
            }
        }
        .ignoresSafeArea()
    }

    private func resetControlsTimer() {
        // Overlay is explicitly controlled via collapse / expand controls
    }
}

// MARK: - Section 2 Diagnostic Latency HUD

struct DiagnosticHUDView: View {
    let d: FrameDiagnostics
    var orientation: MirooOrientation = .portrait
    var transport: String = "TCP"
    let onDismiss: () -> Void
    var onToggleOrientation: (() -> Void)? = nil

    private var adaptiveStateColor: Color {
        if d.adaptiveState == "Stable" {
            return .green
        } else if d.adaptiveState == "Congested" {
            return .orange
        } else {
            return .yellow
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerSection
            Divider().background(Color.white.opacity(0.25))
            stateSection
            Divider().background(Color.white.opacity(0.25))
            stagesSection
            Divider().background(Color.white.opacity(0.25))
            totalsSection
            Divider().background(Color.white.opacity(0.25))
            metricsSection
        }
        .padding(10)
        .frame(width: 250)
        .background(Color.black.opacity(0.85))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            Text("MIROO DIAGNOSTICS")
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
    }

    @ViewBuilder
    private var stateSection: some View {
        metricRow("Transport", value: transport, color: transport == "USB" ? .yellow : (transport == "UDP" ? .cyan : .green))
        metricRow("Adaptive", value: d.adaptiveState, color: adaptiveStateColor)

        HStack {
            Text("Mode")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            if let onToggle = onToggleOrientation {
                Button(action: onToggle) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                        Text(orientation.rawValue.capitalized)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.6))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                }
            } else {
                Text(orientation.rawValue.capitalized)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
    }

    @ViewBuilder
    private var stagesSection: some View {
        metricRow("Capture", value: String(format: "%.1f ms", d.captureMs))
        metricRow("Encode", value: String(format: "%.1f ms", d.encodeMs))
        metricRow("Network", value: String(format: "%.1f ms", d.networkMs))
        metricRow("Decode", value: String(format: "%.1f ms", d.decodeMs))
        metricRow("Metal", value: String(format: "%.1f ms", d.metalMs))
        metricRow("Queue", value: String(format: "%.1f ms", d.queueMs))
    }

    @ViewBuilder
    private var totalsSection: some View {
        metricRow("Glass-to-Render", value: String(format: "%.1f ms", d.pipelineMs), color: .green)
        metricRow("G2R p50/95/99", value: "\(Int(d.p50GlassToRenderMs))/\(Int(d.p95GlassToRenderMs))/\(Int(d.p99GlassToRenderMs)) ms")
        metricRow("Frame Age p50/95", value: "\(Int(d.p50FrameAgeMs))/\(Int(d.p95FrameAgeMs)) ms")
    }

    @ViewBuilder
    private var metricsSection: some View {
        metricRow("FPS (Cur/Tgt)", value: String(format: "%.1f / %.0f", d.fps, d.targetFps))
        metricRow("Bitrate", value: String(format: "%.1f Mbps", d.bitrateMbps))
        metricRow("Queue Depth", value: "\(d.queueDepth)")
        metricRow("Frame Jitter", value: String(format: "%.1f ms", d.jitterMs))
        metricRow("Loss", value: "\(d.packetLossCount) (\(String(format: "%.1f", d.packetLossRate * 100))%)", color: d.packetLossRate > 0.02 ? .orange : .white)
        metricRow("Keyframes", value: "\(d.keyframeRequestCount)")
    }

    private func metricRow(_ title: String, value: String, color: Color = .white) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
    }
}
