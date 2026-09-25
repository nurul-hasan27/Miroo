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

    // MARK: - Discovery & Authorization
    public let authorizer = ConnectionAuthorizer.shared
    public let browser = MirooBrowser()
    public let usbmux = USBMuxClient()
    private var usbAttachedSerialMap: [UInt32: String] = [:]
    @Published public private(set) var nearbyPhones: [MirooDevice] = []

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
        setupDiscovery()
    }

    deinit {
        // Observers cleanup
        if let obs = sleepObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = wakeObserver { NotificationCenter.default.removeObserver(obs) }
        browser.stop()
        usbmux.stopMonitoring()
    }

    private func setupDiscovery() {
        browser.onDevicesUpdated = { [weak self] devices in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.nearbyPhones = devices.filter { $0.deviceType == .iphone }
            }
        }
        browser.start()

        usbmux.onDeviceAttached = { [weak self] usbDev in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.usbAttachedSerialMap[usbDev.deviceID] = usbDev.serialNumber
                let dev = MirooDevice(
                    id: usbDev.serialNumber,
                    deviceType: .iphone,
                    displayName: "iPhone (USB)",
                    modelName: "iPhone",
                    osVersion: nil,
                    isUSBAvailable: true,
                    isWiFiAvailable: false,
                    availability: .available,
                    lastSeen: Date(),
                    endpointDescription: "USB usbmuxd (port \(USBMuxClient.targetDevicePort))"
                )
                self.browser.upsertDirectDevice(dev)
            }
        }

        usbmux.onDeviceDetached = { [weak self] deviceID in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let serial = self.usbAttachedSerialMap.removeValue(forKey: deviceID) {
                    self.browser.removeDirectDevice(id: serial)
                }
            }
        }
        usbmux.startMonitoring()
    }

    public func connect(to device: MirooDevice) {
        print("[MirooEngine] User requested connection to \(device.displayName)...")
        if device.isUSBAvailable {
            server?.startUSBMonitoring()
        }
    }

    public func disconnectClient() {
        print("[MirooEngine] Disconnecting active client...")
        server?.disconnectActiveConnection()
        isClientConnected = false
        connectedClientName = nil
        activeTransport = "None"
        statusMessage = "Waiting for iPhone..."
    }

    // MARK: - Lifecycle Controls

    /// Starts the Miroo listening and discovery engine.
    /// CRITICAL ARCHITECTURAL BOUNDARY: Does NOT create virtual display or initialize encoder yet.
    /// Virtual display is strictly allocated upon explicit connection authorization.
    public func start() async throws {
        guard !isRunning else { return }

        statusMessage = "Starting Miroo..."
        print("[MirooEngine] Starting streaming engine in listening mode...")

        let targetWidth = Int(VirtualDisplayManager.physicalWidth)
        let targetHeight = Int(VirtualDisplayManager.physicalHeight)
        self.activeWidth = targetWidth
        self.activeHeight = targetHeight

        // 1. Initialize MirooServer
        let initialTransport: VideoTransportType
        if preferredTransport == "udp" {
            initialTransport = .udp
        } else if preferredTransport == "tcp" {
            initialTransport = .tcp
        } else {
            initialTransport = .tcp
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

        // 2. Initialize MacInputController
        let inputController = MacInputController()
        self.inputController = inputController

        server.onTouchEvent = { [weak inputController, weak self] payload in
            guard let inputController = inputController, let manager = self?.displayManager else { return }
            inputController.handleTouchEvent(payload, displayID: manager.displayID)
        }

        server.onScrollEvent = { [weak inputController] payload in
            inputController?.scroll(deltaX: payload.deltaX, deltaY: payload.deltaY)
        }

        server.onRightClick = { [weak inputController] _ in
            inputController?.rightClick()
        }

        server.onClientDisconnected = { [weak self] in
            Task { @MainActor in
                self?.stopDisplaySession(reason: .userDisconnected)
            }
        }

        server.onClientConnected = { [weak self] client in
            Task { @MainActor in
                self?.isClientConnected = true
                self?.connectedClientName = client
                self?.updateActiveTransport()
                self?.statusMessage = "Connected to \(client)"
                self?.displayManager?.restoreSavedArrangement()
            }
        }

        server.onStreamingStarted = { [weak self] in
            Task { @MainActor in
                self?.isClientConnected = true
                self?.updateActiveTransport()
            }
        }

        server.onOrientationChangeRequested = { [weak self] newOrientation in
            Task { @MainActor in
                await self?.switchOrientation(to: newOrientation)
            }
        }

        server.onRequestKeyframe = { [weak self] in
            self?.encoder?.requestKeyframe()
        }

        server.onAdaptiveDecision = { [weak self] decision in
            self?.encoder?.setBitrate(decision.targetBitrate)
            self?.encoder?.setTargetFPS(decision.targetFPS)
        }

        // 3. Setup Connection Authorization Flow (Phase 13)
        server.onConnectionRequest = { [weak self] request, conn in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.handleIncomingConnectionRequest(request, connection: conn)
            }
        }

        server.onConnectionCancelled = { [weak self] cancelled in
            Task { @MainActor [weak self] in
                self?.authorizer.cancel(sessionID: cancelled.sessionID)
            }
        }

        server.onSessionEnded = { [weak self] ended in
            Task { @MainActor [weak self] in
                self?.stopDisplaySession(reason: ended.reason)
            }
        }

        authorizer.onRequestTimeout = { [weak self] sessionID in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                MirooApprovalWindowController.shared.dismissPrompt(sessionID: sessionID)
                self.server?.activeConnection?.send(message: .connectionRejected(
                    ConnectionRejectedPayload(sessionID: sessionID, reasonCode: .timeout, reasonMessage: "Authorization timed out after 30 seconds.")
                ))
                self.server?.disconnectActiveConnection()
            }
        }

        authorizer.onRequestCancelled = { sessionID in
            Task { @MainActor in
                MirooApprovalWindowController.shared.dismissPrompt(sessionID: sessionID)
            }
        }

        // 4. Start Network Server & Bonjour Advertisement
        try server.start()

        // 5. Setup Sleep/Wake & Telemetry
        setupSleepWakeObservers()
        startTelemetryTimer()

        self.isRunning = true
        self.isStreamingPaused = false
        self.statusMessage = "Miroo Running — Waiting for iPhone"
        print("[MirooEngine] Engine started in listening mode (no virtual display created yet).")
    }

    private func handleIncomingConnectionRequest(_ request: ConnectionRequestPayload, connection: MirooConnection) {
        let isStreaming = (displayManager != nil && isClientConnected)
        let transport = (server?.currentTransportType == .usb) ? "USB" : "Wi-Fi"
        let decision = authorizer.processRequest(request, isCurrentlyStreaming: isStreaming, transport: transport)

        switch decision {
        case .approved:
            print("[MirooEngine] Request automatically approved for trusted client '\(request.clientName)'")
            Task { @MainActor in
                await self.startDisplaySession(for: request, connection: connection)
            }

        case .promptUser:
            print("[MirooEngine] Prompting user for connection request from '\(request.clientName)'")
            if let pending = authorizer.getPendingRequest(sessionID: request.sessionID) {
                MirooApprovalWindowController.shared.showRequestPrompt(request: pending) { [weak self] sessionID, approved, remember in
                    guard let self = self else { return }
                    if approved {
                        if let appReq = self.authorizer.approve(sessionID: sessionID, rememberDevice: remember) {
                            Task { @MainActor in
                                await self.startDisplaySession(for: appReq, connection: connection)
                            }
                        }
                    } else {
                        if let rej = self.authorizer.reject(sessionID: sessionID) {
                            connection.send(message: .connectionRejected(
                                ConnectionRejectedPayload(
                                    sessionID: sessionID,
                                    reasonCode: rej.reason,
                                    reasonMessage: "Connection rejected by Mac user."
                                )
                            ))
                            connection.disconnect()
                        }
                    }
                }
            }

        case .rejected(let reason, let message):
            print("[MirooEngine] Request rejected: \(reason.rawValue) - \(message)")
            connection.send(message: .connectionRejected(
                ConnectionRejectedPayload(sessionID: request.sessionID, reasonCode: reason, reasonMessage: message)
            ))
            connection.disconnect()
        }
    }

    /// Allocates the virtual display, captures screen, and starts encoding strictly AFTER connection authorization.
    public func startDisplaySession(for request: ConnectionRequestPayload, connection: MirooConnection) async {
        print("[MirooEngine] Starting display session for '\(request.clientName)' (Session: \(request.sessionID))...")
        statusMessage = "Allocating virtual display for \(request.clientName)..."

        let targetWidth = request.preferredWidth > 0 ? request.preferredWidth : Int(VirtualDisplayManager.physicalWidth)
        let targetHeight = request.preferredHeight > 0 ? request.preferredHeight : Int(VirtualDisplayManager.physicalHeight)

        // 1. Send CONNECTION_ACCEPTED
        let accepted = ConnectionAcceptedPayload(
            sessionID: request.sessionID,
            hostID: DeviceIdentity.currentID,
            hostName: server?.serviceName ?? "Miroo Mac",
            width: targetWidth,
            height: targetHeight,
            targetFPS: targetFPS,
            scale: 2.0,
            selectedTransport: server?.currentTransportType.rawValue ?? "TCP",
            udpPort: server?.udpPort ?? 51042,
            sessionToken: server?.udpSessionToken ?? 0
        )
        connection.send(message: .connectionAccepted(accepted))

        // 2. Send SESSION_STARTING
        connection.send(message: .sessionStarting(SessionStartingPayload(sessionID: request.sessionID)))

        // 3. Allocate Virtual Display
        let manager = VirtualDisplayManager()
        self.displayManager = manager

        guard manager.create() else {
            print("[MirooEngine] ERROR: Failed to create virtual display.")
            statusMessage = "Error: Failed to create virtual display"
            connection.send(message: .connectionRejected(
                ConnectionRejectedPayload(sessionID: request.sessionID, reasonCode: .unsupportedCapabilities, reasonMessage: "Failed to create virtual display on Mac.")
            ))
            connection.disconnect()
            stopDisplaySession(reason: .shutdown)
            return
        }

        let displayID = manager.displayID
        self.activeWidth = targetWidth
        self.activeHeight = targetHeight
        self.currentOrientation = manager.currentOrientation
        manager.restoreSavedArrangement()

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
            print("[MirooEngine] ERROR: Video encoder setup failed: \(error.localizedDescription)")
            statusMessage = "Error: Video encoder setup failed"
            connection.disconnect()
            stopDisplaySession(reason: .shutdown)
            return
        }

        encoder.onEncodedFrame = { [weak self] data, pts, isKeyframe, captureNs, encStartNs, encCompNs, encodeDurationUs in
            guard let self = self, !self.isStreamingPaused else { return }
            self.server?.enqueueFrame(
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

        capturer.onFrameCaptured = { [weak self] pixelBuffer, presentationTime, captureTimestampNs in
            guard let self = self, !self.isStreamingPaused else { return }
            let forceKey = self.server?.frameQueue.needsImmediateKeyframe ?? false
            self.encoder?.encode(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                captureTimestampNs: captureTimestampNs,
                forceKeyframe: forceKey
            )
        }

        do {
            try await capturer.startCapture(
                displayID: displayID,
                displayName: VirtualDisplayManager.defaultDisplayName,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                targetFPS: targetFPS
            )
        } catch {
            print("[MirooEngine] ERROR: Screen capture failed: \(error.localizedDescription)")
            statusMessage = "Error: Screen capture failed"
            connection.disconnect()
            stopDisplaySession(reason: .shutdown)
            return
        }

        // 6. Send SESSION_STARTED
        connection.send(message: .sessionStarted(SessionStartedPayload(sessionID: request.sessionID, width: targetWidth, height: targetHeight)))

        // 7. Send DISPLAY_INFO & STREAM_CONFIG
        let displayMsg = MirooMessage.displayInfo(width: targetWidth, height: targetHeight, scaleFactor: 2.0, name: "Miroo Extended iPhone")
        let streamMsg = MirooMessage.streamConfig(
            codec: "H264",
            width: targetWidth,
            height: targetHeight,
            fps: targetFPS,
            bitrate: targetBitrateMbps * 1_000_000,
            orientation: (targetWidth > targetHeight) ? .landscape : .portrait,
            transport: server?.currentTransportType.rawValue ?? "TCP",
            udpPort: server?.udpPort ?? 51042,
            sessionToken: server?.udpSessionToken ?? 0,
            serverHost: nil
        )
        connection.send(message: displayMsg)
        connection.send(message: streamMsg)

        // 8. Update State
        self.isClientConnected = true
        self.connectedClientName = request.clientName
        self.updateActiveTransport()
        self.statusMessage = "Streaming to \(request.clientName)"
        print("[MirooEngine] Display session active and streaming to \(request.clientName)!")
    }

    /// Stops display session, releases encoder and capturer, and destroys virtual display cleanly.
    public func stopDisplaySession(reason: SessionEndReason = .userDisconnected) {
        print("[MirooEngine] Stopping display session (reason: \(reason.rawValue))...")

        inputController?.releaseAllButtons()

        capturer?.stopCaptureSync()
        capturer = nil

        encoder?.invalidate()
        encoder = nil

        displayManager?.destroy()
        displayManager = nil

        isClientConnected = false
        connectedClientName = nil
        activeTransport = "None"
        currentFPS = 0.0
        currentBitrateMbps = 0.0
        currentPipelineLatencyMs = 0.0
        statusMessage = "Miroo Running — Waiting for iPhone"
        print("[MirooEngine] Display session stopped cleanly. Returned to listening mode.")
    }

    /// Stops all pipeline components and frees hardware resources gracefully.
    public func stop() {
        guard isRunning else { return }
        print("[MirooEngine] Stopping streaming engine...")

        statusMessage = "Stopping..."
        stopTelemetryTimer()

        stopDisplaySession(reason: .shutdown)

        inputController = nil
        server?.stop()
        server = nil

        isRunning = false
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
