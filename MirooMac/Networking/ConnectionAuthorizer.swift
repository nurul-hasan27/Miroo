//
//  ConnectionAuthorizer.swift
//  MirooNetworking
//
//  Phase 13: Connection Authorization, Pairing Store, and Request Timeout Management.
//

import Foundation

public enum AuthorizationDecision: Equatable, Sendable {
    case approved
    case promptUser
    case rejected(reason: ConnectionRejectionReason, message: String)
}

public struct PendingConnectionRequest: Identifiable, Sendable {
    public var id: String { payload.sessionID }
    public let payload: ConnectionRequestPayload
    public let receivedAt: Date
    public let transportType: String

    public init(payload: ConnectionRequestPayload, receivedAt: Date = Date(), transportType: String = "Wi-Fi") {
        self.payload = payload
        self.receivedAt = receivedAt
        self.transportType = transportType
    }
}

public final class ConnectionAuthorizer: @unchecked Sendable {
    public static let shared = ConnectionAuthorizer()
    public static let trustedDevicesKey = "com.miroo.auth.trustedDevices"
    public static let autoAcceptKey = "com.miroo.auth.autoAcceptTrusted"
    public static let defaultTimeoutSeconds: TimeInterval = 30.0

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var pendingRequests: [String: PendingConnectionRequest] = [:]
    private var timeoutTimers: [String: DispatchSourceTimer] = [:]
    private let timerQueue = DispatchQueue(label: "com.miroo.authorizer.timer", qos: .userInitiated)

    public var onRequestNeedsPrompt: ((PendingConnectionRequest) -> Void)?
    public var onRequestTimeout: ((String) -> Void)?
    public var onRequestCancelled: ((String) -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Trust / Pairing Management

    public var autoAcceptTrustedDevices: Bool {
        get {
            if defaults.object(forKey: Self.autoAcceptKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.autoAcceptKey)
        }
        set {
            defaults.set(newValue, forKey: Self.autoAcceptKey)
        }
    }

    public var trustedDeviceIDs: [String] {
        get {
            defaults.stringArray(forKey: Self.trustedDevicesKey) ?? []
        }
        set {
            defaults.set(newValue, forKey: Self.trustedDevicesKey)
        }
    }

    public func isTrusted(clientID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return trustedDeviceIDs.contains(clientID)
    }

    public func trustDevice(clientID: String) {
        lock.lock()
        defer { lock.unlock() }
        var list = trustedDeviceIDs
        if !list.contains(clientID) {
            list.append(clientID)
            trustedDeviceIDs = list
        }
    }

    public func untrustDevice(clientID: String) {
        lock.lock()
        defer { lock.unlock() }
        var list = trustedDeviceIDs
        list.removeAll { $0 == clientID }
        trustedDeviceIDs = list
    }

    public func clearAllTrustedDevices() {
        lock.lock()
        defer { lock.unlock() }
        trustedDeviceIDs = []
    }

    // MARK: - Request Ingestion & Evaluation

    public func processRequest(
        _ request: ConnectionRequestPayload,
        isCurrentlyStreaming: Bool,
        transport: String = "Wi-Fi"
    ) -> AuthorizationDecision {
        lock.lock()
        defer { lock.unlock() }

        // 1. Host Busy Check
        if isCurrentlyStreaming {
            return .rejected(reason: .busy, message: "Mac is currently streaming to another device.")
        }

        // 2. Protocol Version Compatibility
        if request.protocolVersion != MirooHeader.currentVersion {
            return .rejected(reason: .versionMismatch, message: "Protocol version mismatch: Host is v\(MirooHeader.currentVersion), Client is v\(request.protocolVersion).")
        }

        // 3. Trusted Auto-Accept Check
        if autoAcceptTrustedDevices && trustedDeviceIDs.contains(request.clientID) {
            return .approved
        }

        // 4. Register Pending Request & Start Timeout Timer
        cancelTimeoutTimer(for: request.sessionID)
        let pending = PendingConnectionRequest(payload: request, receivedAt: Date(), transportType: transport)
        pendingRequests[request.sessionID] = pending
        scheduleTimeoutTimer(for: request.sessionID)

        return .promptUser
    }

    public func approve(sessionID: String, rememberDevice: Bool = false) -> ConnectionRequestPayload? {
        lock.lock()
        defer { lock.unlock() }

        cancelTimeoutTimer(for: sessionID)
        guard let pending = pendingRequests.removeValue(forKey: sessionID) else {
            return nil
        }

        if rememberDevice {
            var list = trustedDeviceIDs
            if !list.contains(pending.payload.clientID) {
                list.append(pending.payload.clientID)
                trustedDeviceIDs = list
            }
        }

        return pending.payload
    }

    public func reject(sessionID: String) -> (payload: ConnectionRequestPayload, reason: ConnectionRejectionReason)? {
        lock.lock()
        defer { lock.unlock() }

        cancelTimeoutTimer(for: sessionID)
        guard let pending = pendingRequests.removeValue(forKey: sessionID) else {
            return nil
        }
        return (pending.payload, .userRejected)
    }

    public func cancel(sessionID: String) {
        lock.lock()
        defer { lock.unlock() }

        cancelTimeoutTimer(for: sessionID)
        pendingRequests.removeValue(forKey: sessionID)
        onRequestCancelled?(sessionID)
    }

    public func getPendingRequest(sessionID: String) -> PendingConnectionRequest? {
        lock.lock()
        defer { lock.unlock() }
        return pendingRequests[sessionID]
    }

    // MARK: - Private Timeout Management

    private func scheduleTimeoutTimer(for sessionID: String) {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + Self.defaultTimeoutSeconds)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let hasPending = self.pendingRequests.removeValue(forKey: sessionID) != nil
            self.timeoutTimers.removeValue(forKey: sessionID)
            self.lock.unlock()

            if hasPending {
                self.onRequestTimeout?(sessionID)
            }
        }
        timer.resume()
        timeoutTimers[sessionID] = timer
    }

    private func cancelTimeoutTimer(for sessionID: String) {
        if let timer = timeoutTimers.removeValue(forKey: sessionID) {
            timer.cancel()
        }
    }
}
