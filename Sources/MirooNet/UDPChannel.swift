import Foundation
import Network
import MirooCore

/// One UDP flow (client side `NWConnection`, or one remote of a listener).
public final class UDPChannel: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue
    public var onDatagram: ((UnsafeRawBufferPointer, UInt64) -> Void)?
    public var onState: ((NWConnection.State) -> Void)?
    private var started = false

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection; self.queue = queue
    }

    public static func parameters() -> NWParameters {
        let p = NWParameters.udp
        p.serviceClass = .interactiveVideo
        p.includePeerToPeer = true
        p.allowLocalEndpointReuse = true
        return p
    }

    public static func connect(host: NWEndpoint.Host, port: NWEndpoint.Port, interface: NWInterface?, queue: DispatchQueue) -> UDPChannel {
        let p = parameters()
        if let i = interface { p.requiredInterface = i }
        return UDPChannel(connection: NWConnection(host: host, port: port, using: p), queue: queue)
    }

    public func start() {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] s in self?.onState?(s) }
        connection.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let now = LinkClock.nowUs()
                data.withUnsafeBytes { self.onDatagram?($0, now) }
            }
            if error == nil || self.connection.state == .ready { 
                if case .cancelled = self.connection.state { return }
                if case .failed = self.connection.state { return }
                self.receiveLoop()
            }
        }
    }

    public func send(_ bytes: [UInt8]) {
        connection.send(content: bytes, completion: .idempotent)
    }

    public func cancel() { connection.cancel() }
}

/// Accepts UDP flows (phone side). Each new remote address yields a channel.
public final class UDPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    public var onFlow: ((UDPChannel) -> Void)?
    public var onReady: ((NWEndpoint.Port) -> Void)?

    public init(queue: DispatchQueue, port: NWEndpoint.Port = .any) throws {
        self.queue = queue
        listener = try NWListener(using: UDPChannel.parameters(), on: port)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let ch = UDPChannel(connection: conn, queue: self.queue)
            ch.start()
            self.onFlow?(ch)
        }
        listener.stateUpdateHandler = { [weak self] st in
            if case .ready = st, let p = self?.listener.port { self?.onReady?(p) }
        }
    }
    public func start() { listener.start(queue: queue) }
    public func cancel() { listener.cancel() }
    public var port: NWEndpoint.Port? { listener.port }
}
