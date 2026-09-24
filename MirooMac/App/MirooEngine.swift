//
//  MirooEngine.swift
//  MirooMac
//
//  Phase 12: Production macOS Application Engine.
//  Encapsulates virtual display lifecycle, ScreenCaptureKit capture stream,
//  hardware VideoToolbox encoding, network server, input injection, and settings.
//  Provides an ObservableObject interface for native macOS Menu Bar UI and Settings.
//

import Cocoa
import CoreGraphics
import CoreMedia
import VideoToolbox
import ScreenCaptureKit
import ServiceManagement
import Combine
#if canImport(MirooNetworking)
import MirooNetworking
#endif

/// Central coordinator for the Miroo macOS application.
@MainActor
public final class MirooEngine: ObservableObject {

    public static let shared = MirooEngine()

    // MARK: - Published State for UI

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var isStreamingPaused: Bool = false
    @Published public private(set) var isClientConnected: Bool = false
    @Published public private(set) var connectedClientName: String? = nil
    @Published public private(set) var activeTransport: String = "None"
    @Published public private(set) var currentOrientation: MirooOrientation = .portrait

    // Live Telemetry
    @Published public private(set) var currentFPS: Double = 0.0
    @Published public private(set) var currentBitrateMbps: Double = 0.0
    @Published public private(set) var currentPipelineLatencyMs: Double = 0.0
    @Published public private(set) var activeWidth: Int = Int(VirtualDisplayManager.physicalWidth)
    @Published public private(set) var activeHeight: Int = Int(VirtualDisplayManager.physicalHeight)

    // User Preferences (Settings)
    @Published public var targetFPS: Int = 60 {
        didSet { applyTargetFPS(targetFPS) }
    }
    @Published public var targetBitrateMbps: Int = 8 {
        didSet { applyTargetBitrate(targetBitrateMbps) }
    }
    @Published public var preferredTransport: String = "auto" {
        didSet { applyPreferredTransport(preferredTransport) }
    }
    @Published public var launchAtLogin: Bool = false {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }
    @Published public private(set) var statusMessage: String = "Ready"

    // MARK: - Core Components

    public private(set) var displayManager: VirtualDisplayManager?
    public private(set) var capturer: DisplayStreamCapturer?
    public private(set) var encoder: VideoEncoder?
    public private(set) var server: MirooServer?
    public private(set) var inputController: MacInputController?

    private var telemetryTimer: Timer?
    private var isSwitchingOrientation = false
    private var sleepObserver: Any?
    private var wakeObserver: Any?

    // MARK: - Initialization

    public init() {
        checkLaunchAtLoginStatus()
    }

    deinit {
        // Observers cleanup
        if let obs = sleepObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = wakeObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Lifecycle Controls

    /// Starts the entire Miroo pipeline (Virtual Display -> Capturer -> Encoder -> Network Server).
    public func start() async throws {
        guard !isRunning else { return }

        statusMessage = "Starting virtual display..."
        print("[MirooEngine] Starting streaming engine...")

        // 1. Create Virtual Display
        let manager = VirtualDisplayManager()
        self.displayManager = manager

        let success = manager.create()
        guard success else {
            statusMessage = "Error: Failed to create virtual display"
            print("[MirooEngine] ERROR: Failed to create virtual display.")
            throw NSError(domain: "com.miroo.engine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create virtual display"])
        }

        let displayID = manager.displayID
        let displayName = VirtualDisplayManager.defaultDisplayName
        let targetWidth = Int(VirtualDisplayManager.physicalWidth)
        let targetHeight = Int(VirtualDisplayManager.physicalHeight)
        self.activeWidth = targetWidth
        self.activeHeight = targetHeight
        self.currentOrientation = manager.currentOrientation

        // 2. Initialize MirooServer
        let initialTransport: VideoTransportType
        if preferredTransport == "udp" {
            initialTransport = .udp
        } else if preferredTransport == "tcp" {
            initialTransport = .tcp
        } else {
            initialTransport = .tcp // Default auto baseline; USB mux auto-connects when phone attaches
        }

        let server = MirooServer(
            serviceName: Host.current().localizedName ?? "Miroo Mac",
            width: targetWidth,
            height: targetHeight,
            targetFPS: targetFPS,
            bitrate: targetBitrateMbps * 1_000_000,
            maxQueueDepth: 1,
            initialTransport: initialTransport
        )
        self.server = server

        // 3. Initialize MacInputController
        let inputController = MacInputController()
        self.inputController = inputController

        server.onTouchEvent = { [weak inputController, weak manager] payload in
            guard let inputController = inputController, let manager = manager else { return }
            inputController.handleTouchEvent(payload, displayID: manager.displayID)
        }

        server.onScrollEvent = { [weak inputController] payload in
            inputController?.scroll(deltaX: payload.deltaX, deltaY: payload.deltaY)
        }

        server.onRightClick = { [weak inputController] _ in
            inputController?.rightClick()
        }

        server.onClientDisconnected = { [weak inputController, weak self] in
            inputController?.releaseAllButtons()
            Task { @MainActor in
                self?.isClientConnected = false
                self?.connectedClientName = nil
                self?.activeTransport = "None"
                self?.statusMessage = "Waiting for iPhone..."
            }
        }

        server.onClientConnected = { [weak self] client in
            Task { @MainActor in
                self?.isClientConnected = true
                self?.connectedClientName = client
                self?.updateActiveTransport()
                self?.statusMessage = "Connected to \(client)"
            }
        }

        server.onStreamingStarted = { [weak self] in
            Task { @MainActor in
                self?.isClientConnected = true
                self?.updateActiveTransport()
            }
        }

        // 4. Initialize Hardware VideoEncoder
        let encoder = VideoEncoder(
            width: Int32(targetWidth),
            height: Int32(targetHeight),
            targetFPS: Int32(targetFPS),
            averageBitrate: Int32(targetBitrateMbps * 1_000_000),
            keyframeInterval: 180
        )
        self.encoder = encoder

        do {
            try encoder.setup()
        } catch {
            statusMessage = "Error: Video encoder setup failed"
            print("[MirooEngine] ERROR: Failed to setup VideoEncoder: \(error.localizedDescription)")
            stop()
            throw error
        }

        encoder.onEncodedFrame = { [weak server, weak self] data, pts, isKeyframe, captureNs, encStartNs, encCompNs, encodeDurationUs in
            guard let self = self, !self.isStreamingPaused else { return }
            server?.enqueueFrame(
                data: data,
                pts: pts,
                isKeyframe: isKeyframe,
                captureTimestampNs: captureNs,
                encodeStartNs: encStartNs,
                encodeCompleteNs: encCompNs,
                encodeDurationUs: encodeDurationUs
            )
        }

        // 5. Initialize DisplayStreamCapturer
        let capturer = DisplayStreamCapturer()
        self.capturer = capturer

        capturer.onFrameCaptured = { [weak server, weak encoder, weak self] pixelBuffer, presentationTime, captureTimestampNs in
            guard let self = self, !self.isStreamingPaused else { return }
            let forceKey = server?.frameQueue.needsImmediateKeyframe ?? false
            encoder?.encode(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                captureTimestampNs: captureTimestampNs,
                forceKeyframe: forceKey
            )
        }

        server.onOrientationChangeRequested = { [weak self] newOrientation in
            Task { @MainActor in
                await self?.switchOrientation(to: newOrientation)
            }
        }

        server.onRequestKeyframe = { [weak encoder] in
            encoder?.requestKeyframe()
        }

        server.onAdaptiveDecision = { [weak encoder] decision in
            encoder?.setBitrate(decision.targetBitrate)
            encoder?.setTargetFPS(decision.targetFPS)
        }

        // 6. Start ScreenCaptureKit Stream & Server
        statusMessage = "Starting screen capture..."
        try await capturer.startCapture(
            displayID: displayID,
            displayName: displayName,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            targetFPS: targetFPS
        )

        statusMessage = "Starting network server..."
        try server.start()

        // 7. Setup system sleep/wake notifications
        setupSleepWakeObservers()

        // 8. Start live telemetry ticker
        startTelemetryTimer()

        self.isRunning = true
        self.isStreamingPaused = false
        self.statusMessage = "Miroo Running — Waiting for iPhone"
        print("[MirooEngine] Engine started successfully.")
    }

    /// Stops all pipeline components and frees hardware resources gracefully.
    public func stop() {
        guard isRunning else { return }
        print("[MirooEngine] Stopping streaming engine...")

        statusMessage = "Stopping..."
        stopTelemetryTimer()

        inputController?.releaseAllButtons()
        inputController = nil

        server?.stop()
        server = nil

        capturer?.stopCaptureSync()
        capturer = nil

        encoder?.invalidate()
        encoder = nil

        displayManager?.destroy()
        displayManager = nil

        isRunning = false
        isClientConnected = false
        connectedClientName = nil
        activeTransport = "None"
        currentFPS = 0.0
        currentBitrateMbps = 0.0
        currentPipelineLatencyMs = 0.0
        statusMessage = "Stopped"
        print("[MirooEngine] Engine stopped cleanly.")
    }

    // MARK: - Stream Controls

    /// Toggles pause state. When paused, frames are dropped without encoding; when unpaused, an IDR keyframe is triggered.
    public func togglePause() {
        guard isRunning else { return }
        isStreamingPaused.toggle()
        if !isStreamingPaused {
            encoder?.requestKeyframe()
            statusMessage = isClientConnected ? "Streaming Active" : "Waiting for iPhone"
            print("[MirooEngine] Streaming resumed (forced IDR keyframe).")
        } else {
            statusMessage = "Streaming Paused"
            print("[MirooEngine] Streaming paused.")
        }
    }

    /// Explicitly forces an IDR keyframe.
    public func requestKeyframe() {
        encoder?.requestKeyframe()
        print("[MirooEngine] IDR keyframe explicitly requested.")
    }

    /// Switches the display orientation between portrait and landscape.
    public func switchOrientation(to newOrientation: MirooOrientation) async {
        guard isRunning, let manager = displayManager, let capturer = capturer, let encoder = encoder, let server = server else { return }
        guard !isSwitchingOrientation else { return }
        guard manager.currentOrientation != newOrientation else { return }

        isSwitchingOrientation = true
        defer { isSwitchingOrientation = false }

        print("[MirooEngine] Switching orientation to \(newOrientation.rawValue)...")
        inputController?.releaseAllButtons()

        let success = manager.setOrientation(newOrientation)
        guard success else {
            print("[MirooEngine] ERROR: Failed to switch virtual display orientation.")
            return
        }

        let newWidth = (newOrientation == .landscape) ? Int(VirtualDisplayManager.physicalHeight) : Int(VirtualDisplayManager.physicalWidth)
        let newHeight = (newOrientation == .landscape) ? Int(VirtualDisplayManager.physicalWidth) : Int(VirtualDisplayManager.physicalHeight)
        self.activeWidth = newWidth
        self.activeHeight = newHeight
        self.currentOrientation = newOrientation

        // Update capturer resolution
        do {
            try await capturer.updateResolution(targetWidth: newWidth, targetHeight: newHeight)
        } catch {
            await capturer.stopCapture()
            try? await capturer.startCapture(
                displayID: manager.displayID,
                displayName: VirtualDisplayManager.defaultDisplayName,
                targetWidth: newWidth,
                targetHeight: newHeight,
                targetFPS: targetFPS
            )
        }

        // Reconfigure encoder
        do {
            try encoder.reconfigure(width: Int32(newWidth), height: Int32(newHeight))
        } catch {
            print("[MirooEngine] Failed to reconfigure encoder: \(error.localizedDescription)")
        }

        // Notify client and force immediate keyframe
        server.sendStreamConfig(width: newWidth, height: newHeight, orientation: newOrientation)
        server.frameQueue.requestImmediateKeyframe()
        print("[MirooEngine] Orientation switched to \(newOrientation.rawValue) (\(newWidth)x\(newHeight)).")
    }

    // MARK: - Preferences & Parameter Tuning

    private func applyTargetFPS(_ fps: Int) {
        encoder?.setTargetFPS(Int32(fps))
    }

    private func applyTargetBitrate(_ mbps: Int) {
        encoder?.setBitrate(Int32(mbps * 1_000_000))
    }

    private func applyPreferredTransport(_ pref: String) {
        guard let server = server else { return }
        if pref == "udp" {
            server.setVideoTransportType(.udp)
        } else if pref == "tcp" {
            server.setVideoTransportType(.tcp)
        }
        updateActiveTransport()
    }

    private func updateActiveTransport() {
        guard let server = server else {
            activeTransport = "None"
            return
        }
        if server.isUSBActive {
            activeTransport = "USB"
        } else {
            activeTransport = server.currentTransportType.rawValue.uppercased()
        }
    }

    // MARK: - Launch at Login (SMAppService)

    public func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                        print("[MirooEngine] Launch at Login registered successfully.")
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                        print("[MirooEngine] Launch at Login unregistered successfully.")
                    }
                }
            } catch {
                print("[MirooEngine] Warning: SMAppService Launch at Login modification failed: \(error.localizedDescription)")
            }
        }
    }

    private func checkLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    // MARK: - System Sleep / Wake Handlers

    private func setupSleepWakeObservers() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                print("[MirooEngine] Screens went to sleep. Pausing capture...")
                self?.inputController?.releaseAllButtons()
                self?.isStreamingPaused = true
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                print("[MirooEngine] Screens woke up. Resuming capture and requesting IDR keyframe...")
                self?.isStreamingPaused = false
                self?.encoder?.requestKeyframe()
            }
        }
    }

    // MARK: - Live Telemetry Ticker

    private func startTelemetryTimer() {
        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTelemetry()
            }
        }
    }

    private func stopTelemetryTimer() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }

    private func refreshTelemetry() {
        guard let server = server else { return }
        updateActiveTransport()

        let snap = server.metrics.snapshot()
        self.currentFPS = snap.sendFps
        self.currentBitrateMbps = snap.sendThroughputMbps

        let benchReport = PipelineBenchmark.shared.generateReport()
        if benchReport.glassToRender.p50 > 0 {
            self.currentPipelineLatencyMs = benchReport.glassToRender.p50
        }
    }
}
