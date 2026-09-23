//
//  ConnectionLifecycle.swift
//  Miroo
//
//  Phase 10: Production Connection Lifecycle State Machine, Transport Selection,
//  and Reconnection Coordinator.
//

import Foundation
import Network
import os.lock

// MARK: - Connection Lifecycle State

public enum ConnectionLifecycleState: Equatable, Sendable, CustomStringConvertible {
    case idle
    case searching
    case connecting(target: String, transport: VideoTransportType)
    case connected(host: String, transport: VideoTransportType)
    case reconnecting(reason: String, attempt: Int)
    case disconnected(reason: String?)
    case error(message: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    public var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }

    public var isSearching: Bool {
        if case .searching = self { return true }
        return false
    }

    public var activeHost: String? {
        switch self {
        case .connecting(let target, _): return target
        case .connected(let host, _): return host
        default: return nil
        }
    }

    public var activeTransport: VideoTransportType? {
        switch self {
        case .connecting(_, let transport): return transport
        case .connected(_, let transport): return transport
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .idle:
            return "Idle"
        case .searching:
            return "Searching for Mac..."
        case .connecting(let target, let transport):
            return "Connecting to \(target) (\(transport.rawValue))..."
        case .connected(let host, let transport):
            return "Connected to \(host) (\(transport.rawValue))"
        case .reconnecting(let reason, let attempt):
            return "Reconnecting (\(reason), attempt \(attempt))..."
        case .disconnected(let reason):
            return "Disconnected\(reason.map { ": \($0)" } ?? "")"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .idle:
            return "Ready to connect"
        case .searching:
            return "Looking for your Mac..."
        case .connecting(let target, _):
            return "Connecting to \(target)..."
        case .connected(let host, let transport):
            return "\(host) · \(transport.rawValue)"
        case .reconnecting(let reason, _):
            return "Connection interrupted (\(reason)). Reconnecting..."
        case .disconnected:
            return "Disconnected"
        case .error(let msg):
            return msg
        }
    }
}

// MARK: - Discovered Host

public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let endpoint: NWEndpoint
    public var isUSB: Bool
    public var lastSeen: Date
    public var txtRecord: [String: String]

    public init(
        name: String,
        endpoint: NWEndpoint,
        isUSB: Bool = false,
        lastSeen: Date = Date(),
        txtRecord: [String: String] = [:]
    ) {
        self.name = name
        self.endpoint = endpoint
        self.isUSB = isUSB
        self.lastSeen = lastSeen
        self.txtRecord = txtRecord
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(isUSB)
    }

    public static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
        lhs.name == rhs.name && lhs.isUSB == rhs.isUSB
    }
}

// MARK: - Reconnection Policy

public struct ReconnectPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var initialDelaySeconds: Double
    public var maxDelaySeconds: Double
    public var backoffMultiplier: Double

    public init(
        maxAttempts: Int = 10,
        initialDelaySeconds: Double = 0.5,
        maxDelaySeconds: Double = 5.0,
        backoffMultiplier: Double = 1.5
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelaySeconds = initialDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.backoffMultiplier = backoffMultiplier
    }

    public func delay(forAttempt attempt: Int) -> Double {
        guard attempt > 1 else { return initialDelaySeconds }
        let calculated = initialDelaySeconds * pow(backoffMultiplier, Double(attempt - 1))
        return min(maxDelaySeconds, calculated)
    }

    public func canRetry(attempt: Int) -> Bool {
        return attempt <= maxAttempts
    }
}

// MARK: - Transport Selector

public enum TransportSelector: Sendable {
    /// Determines the optimal transport based on strict Miroo priority:
    /// 1. USB (if cable attached and active)
    /// 2. UDP (Wi-Fi low latency default)
    /// 3. TCP (reliable fallback)
    public static func resolveTransport(
        isUSBActive: Bool,
        preferUDP: Bool = true,
        udpFailed: Bool = false
    ) -> VideoTransportType {
        if isUSBActive {
            return .usb
        }
        if preferUDP && !udpFailed {
            return .udp
        }
        return .tcp
    }
}

// MARK: - Connection State Machine

public final class ConnectionStateMachine: @unchecked Sendable {
    private var _state: ConnectionLifecycleState = .idle
    private var lock = os_unfair_lock_s()

    public var onStateTransition: ((_ oldState: ConnectionLifecycleState, _ newState: ConnectionLifecycleState) -> Void)?

    public init(initialState: ConnectionLifecycleState = .idle) {
        self._state = initialState
    }

    public var currentState: ConnectionLifecycleState {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _state
    }

    /// Attempts a thread-safe state transition according to the lifecycle state rules.
    /// Returns true if transition was accepted, false if invalid.
    @discardableResult
    public func transition(to newState: ConnectionLifecycleState) -> Bool {
        os_unfair_lock_lock(&lock)
        let oldState = _state

        guard isValidTransition(from: oldState, to: newState) else {
            os_unfair_lock_unlock(&lock)
            return false
        }

        _state = newState
        os_unfair_lock_unlock(&lock)

        onStateTransition?(oldState, newState)
        return true
    }

    /// State transition validity matrix
    private func isValidTransition(from: ConnectionLifecycleState, to: ConnectionLifecycleState) -> Bool {
        if from == to { return true }

        switch from {
        case .idle:
            switch to {
            case .searching, .connecting, .disconnected, .error: return true
            default: return false
            }

        case .searching:
            switch to {
            case .connecting, .idle, .disconnected, .error: return true
            default: return false
            }

        case .connecting:
            switch to {
            case .connected, .reconnecting, .disconnected, .error, .searching: return true
            default: return false
            }

        case .connected:
            switch to {
            case .connected, .connecting, .reconnecting, .disconnected, .error, .searching: return true
            default: return false
            }

        case .reconnecting:
            switch to {
            case .connecting, .connected, .reconnecting, .disconnected, .error, .searching: return true
            default: return false
            }

        case .disconnected:
            switch to {
            case .searching, .connecting, .reconnecting, .idle, .error: return true
            default: return false
            }

        case .error:
            switch to {
            case .searching, .connecting, .idle, .disconnected: return true
            default: return false
            }
        }
    }
}
