//
//  USBMuxClient.swift
//  Miroo
//
//  Phase 8B: Native USB Multiplexing Client for macOS.
//  Communicates with Apple's system usbmuxd daemon (/var/run/usbmuxd)
//  using Network.framework to detect attached iOS devices and establish
//  zero-latency direct USB TCP socket tunnels without Bonjour delays.
//

import Foundation
import Network

// MARK: - USBMux Protocol Definitions

public struct USBMuxHeader: Sendable, Equatable {
    public static let headerSize = 16
    public static let messagePlist: UInt32 = 8
    public static let currentVersion: UInt32 = 1

    public var length: UInt32
    public var version: UInt32
    public var message: UInt32
    public var tag: UInt32

    public init(length: UInt32, version: UInt32 = currentVersion, message: UInt32 = messagePlist, tag: UInt32 = 1) {
        self.length = length
        self.version = version
        self.message = message
        self.tag = tag
    }
}

public struct USBMuxDevice: Sendable, Equatable {
    public let deviceID: UInt32
    public let serialNumber: String
    public let connectionType: String

    public init(deviceID: UInt32, serialNumber: String, connectionType: String = "USB") {
        self.deviceID = deviceID
        self.serialNumber = serialNumber
        self.connectionType = connectionType
    }
}

public enum USBMuxPacket: Sendable {
    /// Converts a standard host port (e.g. 51065) to network byte order expected by usbmuxd plist
    public static func usbmuxdPortNumber(for port: UInt16) -> UInt32 {
        return ((UInt32(port) & 0xFF) << 8) | ((UInt32(port) >> 8) & 0xFF)
    }

    /// Reverses usbmuxd byte-swapped port back to native UInt16
    public static func nativePortNumber(from usbmuxPort: UInt32) -> UInt16 {
        let low = UInt16((usbmuxPort >> 8) & 0xFF)
        let high = UInt16((usbmuxPort & 0xFF) << 8)
        return high | low
    }

    /// Serializes a request dictionary into a 16-byte header + XML plist payload
    public static func serialize(messageType: String, tag: UInt32 = 1, additionalKeys: [String: Any] = [:]) -> Data? {
        var dict: [String: Any] = [
            "MessageType": messageType,
            "ClientVersionString": "Miroo-Mac",
            "ProgName": "Miroo"
        ]
        for (k, v) in additionalKeys {
            dict[k] = v
        }
        guard let plistData = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return nil
        }

        var data = Data()
        var len = UInt32(USBMuxHeader.headerSize + plistData.count)
        var ver: UInt32 = USBMuxHeader.currentVersion
        var msg: UInt32 = USBMuxHeader.messagePlist
        var t = tag
        data.append(Data(bytes: &len, count: 4))
        data.append(Data(bytes: &ver, count: 4))
        data.append(Data(bytes: &msg, count: 4))
        data.append(Data(bytes: &t, count: 4))
        data.append(plistData)
        return data
    }

    /// Parses a single packet from the buffer. Returns the parsed dictionary and consumed byte count, or nil if incomplete.
    public static func parse(from data: Data) -> (packet: [String: Any], bytesConsumed: Int)? {
        guard data.count >= USBMuxHeader.headerSize else { return nil }
        let totalLen = Int(data.withUnsafeBytes { $0.load(as: UInt32.self) })
        guard totalLen >= USBMuxHeader.headerSize, data.count >= totalLen else { return nil }

        let payloadData = data.subdata(in: USBMuxHeader.headerSize..<totalLen)
        guard let obj = try? PropertyListSerialization.propertyList(from: payloadData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return (obj, totalLen)
    }
}

// MARK: - USBMux Client

public final class USBMuxClient: @unchecked Sendable {
    public static let defaultSocketPath = "/var/run/usbmuxd"
    public static let targetDevicePort: UInt16 = 51065

    private let queue = DispatchQueue(label: "com.miroo.usbmux", qos: .userInteractive)
    private var monitorConnection: NWConnection?
    private var receiveBuffer = Data()
    private var isMonitoring = false

    public private(set) var attachedDevices: [UInt32: USBMuxDevice] = [:]

    public var onDeviceAttached: ((USBMuxDevice) -> Void)?
    public var onDeviceDetached: ((UInt32) -> Void)?

    public init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - Device Monitoring (Listen)

    public func startMonitoring() {
        queue.async { [weak self] in
            guard let self = self, !self.isMonitoring else { return }
            self.isMonitoring = true
            self.connectMonitor()
        }
    }

    public func stopMonitoring() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isMonitoring = false
            self.monitorConnection?.cancel()
            self.monitorConnection = nil
            self.receiveBuffer.removeAll()
            self.attachedDevices.removeAll()
        }
    }

    private func connectMonitor() {
        let conn = NWConnection(to: .unix(path: Self.defaultSocketPath), using: .tcp)
        self.monitorConnection = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn else { return }
            self.queue.async {
                if state == .ready {
                    self.sendListenRequest(on: conn)
                    self.readMonitorLoop(on: conn)
                } else if case .failed = state {
                    self.handleMonitorFailure()
                } else if case .cancelled = state {
                    // Closed intentionally or externally
                }
            }
        }
        conn.start(queue: queue)
    }

    private func sendListenRequest(on conn: NWConnection) {
        guard let data = USBMuxPacket.serialize(messageType: "Listen") else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("[USBMux] Failed to send Listen command: \(error.localizedDescription)")
                self?.handleMonitorFailure()
            }
        })
    }

    private func readMonitorLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] content, _, isComplete, error in
            guard let self = self, let conn = conn else { return }
            self.queue.async {
                if let data = content, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processMonitorBuffer()
                }

                if isComplete || error != nil {
                    if self.isMonitoring {
                        self.handleMonitorFailure()
                    }
                } else {
                    self.readMonitorLoop(on: conn)
                }
            }
        }
    }

    private func processMonitorBuffer() {
        while let (packet, consumed) = USBMuxPacket.parse(from: receiveBuffer) {
            receiveBuffer.removeSubrange(0..<consumed)
            handleMonitorMessage(packet)
        }
    }

    private func handleMonitorMessage(_ dict: [String: Any]) {
        guard let messageType = dict["MessageType"] as? String else { return }

        switch messageType {
        case "Attached":
            let rawID = dict["DeviceID"] as? UInt32 ?? (dict["DeviceID"] as? NSNumber)?.uint32Value ?? 0
            if let props = dict["Properties"] as? [String: Any] {
                let connType = props["ConnectionType"] as? String ?? "USB"
                let serial = props["SerialNumber"] as? String ?? ""
                if connType == "USB" && rawID > 0 {
                    let dev = USBMuxDevice(deviceID: rawID, serialNumber: serial, connectionType: connType)
                    attachedDevices[rawID] = dev
                    print("[USBMux] iOS Device Attached via USB: ID=\(rawID), Serial=\(serial)")
                    onDeviceAttached?(dev)
                }
            }

        case "Detached":
            let rawID = dict["DeviceID"] as? UInt32 ?? (dict["DeviceID"] as? NSNumber)?.uint32Value ?? 0
            if rawID > 0 {
                attachedDevices.removeValue(forKey: rawID)
                print("[USBMux] iOS Device Detached from USB: ID=\(rawID)")
                onDeviceDetached?(rawID)
            }

        case "Result":
            if let num = dict["Number"] as? Int, num != 0 {
                print("[USBMux] Monitor error result: \(num)")
            }

        default:
            break
        }
    }

    private func handleMonitorFailure() {
        monitorConnection?.cancel()
        monitorConnection = nil
        receiveBuffer.removeAll()

        guard isMonitoring else { return }
        print("[USBMux] Monitor disconnected. Reconnecting in 2.0s...")
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.isMonitoring else { return }
            self.connectMonitor()
        }
    }

    // MARK: - Direct Device Tunnel (Connect)

    /// Establishes a raw TCP tunnel through usbmuxd to the specified port on the iOS device.
    /// Upon success, the returned NWConnection is ready to send and receive Miroo stream frames directly.
    public func connectToDevice(
        deviceID: UInt32,
        port: UInt16 = targetDevicePort,
        timeoutSeconds: Double = 5.0,
        completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void
    ) {
        let conn = NWConnection(to: .unix(path: Self.defaultSocketPath), using: .tcp)
        var hasCompleted = false
        var timeoutWorkItem: DispatchWorkItem?

        let finish = { [weak conn] (result: Result<NWConnection, Error>) in
            self.queue.async {
                guard !hasCompleted else { return }
                hasCompleted = true
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil
                if case .failure = result {
                    conn?.cancel()
                }
                completion(result)
            }
        }

        let timeout = DispatchWorkItem {
            finish(.failure(NSError(domain: "USBMuxError", code: -1001, userInfo: [NSLocalizedDescriptionKey: "USBMux connect timed out after \(timeoutSeconds)s"])))
        }
        timeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn else { return }
            self.queue.async {
                guard !hasCompleted else { return }
                if state == .ready {
                    self.sendConnectHandshake(on: conn, deviceID: deviceID, port: port, completion: finish)
                } else if case .failed(let error) = state {
                    finish(.failure(error))
                }
            }
        }
        conn.start(queue: queue)
    }

    private func sendConnectHandshake(
        on conn: NWConnection,
        deviceID: UInt32,
        port: UInt16,
        completion: @escaping (Result<NWConnection, Error>) -> Void
    ) {
        let usbmuxPort = USBMuxPacket.usbmuxdPortNumber(for: port)
        guard let data = USBMuxPacket.serialize(
            messageType: "Connect",
            additionalKeys: [
                "DeviceID": Int(deviceID),
                "PortNumber": Int(usbmuxPort)
            ]
        ) else {
            completion(.failure(NSError(domain: "USBMuxError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize Connect packet"])))
            return
        }

        conn.send(content: data, completion: .contentProcessed { [weak self, weak conn] error in
            guard let _ = self, let conn = conn else { return }
            if let error = error {
                completion(.failure(error))
                return
            }

            // Receive response
            var responseBuffer = Data()
            func receiveResult() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, isComplete, err in
                    if let err = err {
                        completion(.failure(err))
                        return
                    }
                    if let content = content {
                        responseBuffer.append(content)
                        if let (packet, _) = USBMuxPacket.parse(from: responseBuffer) {
                            if let msgType = packet["MessageType"] as? String, msgType == "Result",
                               let number = packet["Number"] as? Int {
                                if number == 0 {
                                    // Successfully tunneled to iOS port over USB!
                                    completion(.success(conn))
                                } else {
                                    completion(.failure(NSError(
                                        domain: "USBMuxError",
                                        code: number,
                                        userInfo: [NSLocalizedDescriptionKey: "usbmuxd tunnel failed with code \(number) (port \(port) may not be listening)"]
                                    )))
                                }
                                return
                            }
                        }
                    }
                    if !isComplete {
                        receiveResult()
                    } else {
                        completion(.failure(NSError(domain: "USBMuxError", code: -2, userInfo: [NSLocalizedDescriptionKey: "usbmuxd closed connection prematurely"])))
                    }
                }
            }
            receiveResult()
        })
    }
}
