//
//  MirooConnection.swift
//  Miroo
//
//  Phase 4: High-level Network.framework connection wrapper handling framing,
//  packet reassembly, state transitions, and asynchronous send/receive.
//

import Foundation
import Network

public enum MirooConnectionState: String, CustomStringConvertible, Sendable {
    case connecting
    case connected
    case streaming
    case disconnecting
    case disconnected

    public var description: String { rawValue.capitalized }
}

public final class MirooConnection: @unchecked Sendable {
    public let id = UUID()
    public let connection: NWConnection
    public let queue: DispatchQueue

    private let accumulator = MessageAccumulator()
    private(set) public var state: MirooConnectionState = .connecting {
        didSet {
            if oldValue != state {
                onStateChanged?(state)
            }
        }
    }

    public var onMessageReceived: ((MirooMessage) -> Void)?
    public var onStateChanged: ((MirooConnectionState) -> Void)?
    public var onDisconnected: ((Error?) -> Void)?

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Convenience initializer to connect to an NWEndpoint (client-side)
    public convenience init(to endpoint: NWEndpoint, queue: DispatchQueue) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableFastOpen = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo

        let conn = NWConnection(to: endpoint, using: params)
        self.init(connection: conn, queue: queue)
    }

    public func start() {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.connection.stateUpdateHandler = { [weak self] nwState in
                guard let self = self else { return }
                self.queue.async {
                    self.handleNWStateUpdate(nwState)
                }
            }

            self.connection.start(queue: self.queue)
            self.receiveNextChunk()
        }
    }

    public func transitionToStreaming() {
        queue.async { [weak self] in
            guard let self = self, self.state == .connected else { return }
            self.state = .streaming
        }
    }

    public func transitionToConnected() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.state = .connected
        }
    }

    // MARK: - Sending

    /// Sends a high-level MirooMessage asynchronously.
    public func send(message: MirooMessage, completion: (@Sendable (Error?) -> Void)? = nil) {
        let data = message.serialize()
        send(data: data, completion: completion)
    }

    /// Sends raw pre-serialized bytes asynchronously with .contentProcessed backpressure tracking.
    public func send(data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                if let error = error {
                    print("[Miroo Connection] Send error: \(error.localizedDescription)")
                    self?.handleError(error)
                }
                completion?(error)
            }
        )
    }

    // MARK: - Receiving

    private func receiveNextChunk() {
        guard state != .disconnected && state != .disconnecting else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            self.queue.async {
                if let data = content, !data.isEmpty {
                    let messages = self.accumulator.append(data)
                    for message in messages {
                        self.onMessageReceived?(message)
                    }
                }

                if isComplete {
                    self.handleDisconnect(error: nil)
                    return
                }

                if let error = error {
                    self.handleDisconnect(error: error)
                    return
                }

                // Continue listening for incoming chunks
                self.receiveNextChunk()
            }
        }
    }

    // MARK: - Lifecycle & State

    private func handleNWStateUpdate(_ nwState: NWConnection.State) {
        switch nwState {
        case .setup:
            state = .connecting
        case .waiting(let error):
            print("[Miroo Connection] Waiting: \(error.localizedDescription)")
        case .preparing:
            state = .connecting
        case .ready:
            if state == .connecting {
                state = .connected
            }
        case .failed(let error):
            handleDisconnect(error: error)
        case .cancelled:
            state = .disconnected
        @unknown default:
            break
        }
    }

    private func handleError(_ error: Error) {
        handleDisconnect(error: error)
    }

    public func disconnect() {
        queue.async { [weak self] in
            guard let self = self, self.state != .disconnected else { return }
            self.state = .disconnecting
            self.connection.cancel()
            self.state = .disconnected
            self.accumulator.reset()
            self.onDisconnected?(nil)
        }
    }

    private func handleDisconnect(error: Error?) {
        guard state != .disconnected else { return }
        state = .disconnected
        accumulator.reset()
        connection.cancel()
        onDisconnected?(error)
    }
}
