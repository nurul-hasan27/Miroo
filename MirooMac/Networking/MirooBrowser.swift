//
//  MirooBrowser.swift
//  MirooNetworking
//
//  Phase 4 & 13: Bonjour service browser discovering Miroo endpoints (_miroo._tcp) on the local network.
//  Maps raw Bonjour services to stable MirooDevice models, handles deduplication, capability detection,
//  and device disappearance.
//

import Foundation
import Network

public struct DiscoveredService: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let endpoint: NWEndpoint
    public let txtRecord: [String: String]

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    public static func == (lhs: DiscoveredService, rhs: DiscoveredService) -> Bool {
        lhs.name == rhs.name
    }
}

public final class MirooBrowser: @unchecked Sendable {
    public let serviceType = "_miroo._tcp"
    public let domain = "local."

    private let queue = DispatchQueue(label: "com.miroo.browser", qos: .userInitiated)
    private var browser: NWBrowser?

    // Legacy Service Observation (Backwards Compatibility)
    public var onServicesUpdated: (([DiscoveredService]) -> Void)?
    private(set) public var discoveredServices: [DiscoveredService] = []

    // Phase 13: Device Model Observation
    public var onDevicesUpdated: (([MirooDevice]) -> Void)?
    private(set) public var discoveredDevices: [MirooDevice] = []

    // Direct / USB Registered Devices
    private var directDevices: [String: MirooDevice] = [:]
    private var endpointsByDeviceID: [String: NWEndpoint] = [:]

    public init() {}

    public func endpoint(for deviceID: String) -> NWEndpoint? {
        queue.sync {
            endpointsByDeviceID[deviceID]
        }
    }

    deinit {
        stop()
    }

    public var discoveredPhones: [MirooDevice] {
        queue.sync {
            discoveredDevices.filter { $0.deviceType == .iphone }
        }
    }

    public var discoveredMacs: [MirooDevice] {
        queue.sync {
            discoveredDevices.filter { $0.deviceType == .mac }
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.internalStop()

            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.includePeerToPeer = true

            let descriptor = NWBrowser.Descriptor.bonjour(type: self.serviceType, domain: self.domain)
            let browser = NWBrowser(for: descriptor, using: params)

            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[Miroo Browser] Browsing for '\(self.serviceType)' on local network...")
                case .failed(let error):
                    print("[Miroo Browser] Error: \(error.localizedDescription)")
                case .cancelled:
                    print("[Miroo Browser] Stopped.")
                default:
                    break
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, changes in
                guard let self = self else { return }
                self.queue.async {
                    var services: [DiscoveredService] = []
                    var devicesMap: [String: MirooDevice] = self.directDevices

                    for result in results {
                        var name = "Miroo Endpoint"
                        var txtDict: [String: String] = [:]

                        if case .service(let sName, _, _, _) = result.endpoint {
                            name = sName
                        }

                        if case .bonjour(let txtRecord) = result.metadata {
                            for key in ["version", "codec", "width", "height", "fps", "type", "id", "model", "name", "usb", "state", "os"] {
                                if let val = txtRecord[key] {
                                    txtDict[key] = val
                                }
                            }
                        }

                        services.append(DiscoveredService(name: name, endpoint: result.endpoint, txtRecord: txtDict))

                        // Device mapping & identity extraction
                        let devID = txtDict["id"] ?? name
                        if devID == DeviceIdentity.currentID {
                            continue
                        }
                        let rawType = txtDict["type"]?.lowercased()
                        let devType: MirooDeviceType
                        if rawType == "iphone" || rawType == "ios" {
                            devType = .iphone
                        } else if rawType == "mac" || rawType == "macos" {
                            devType = .mac
                        } else {
                            // Heuristic fallback for legacy announcements
                            devType = name.localizedCaseInsensitiveContains("iPhone") ? .iphone : .mac
                        }

                        let dispName = txtDict["name"] ?? name
                        let model = txtDict["model"] ?? (devType == .iphone ? "iPhone" : "Mac")
                        let osVer = txtDict["os"]
                        let isUsb = (txtDict["usb"] == "1")
                        let avail = MirooDeviceAvailability(rawValue: txtDict["state"] ?? "") ?? .available

                        var dev = devicesMap[devID] ?? MirooDevice(
                            id: devID,
                            deviceType: devType,
                            displayName: dispName,
                            modelName: model,
                            osVersion: osVer,
                            isUSBAvailable: isUsb,
                            isWiFiAvailable: true,
                            availability: avail,
                            lastSeen: Date(),
                            endpointDescription: "\(result.endpoint)"
                        )

                        // Update metadata dynamically
                        dev.displayName = dispName
                        dev.modelName = model
                        if let os = osVer { dev.osVersion = os }
                        dev.isWiFiAvailable = true
                        if isUsb { dev.isUSBAvailable = true }
                        dev.availability = avail
                        dev.lastSeen = Date()
                        dev.endpointDescription = "\(result.endpoint)"

                        devicesMap[devID] = dev
                        self.endpointsByDeviceID[devID] = result.endpoint
                    }

                    let sortedDevices = Array(devicesMap.values).sorted { $0.displayName < $1.displayName }
                    self.discoveredServices = services
                    self.discoveredDevices = sortedDevices

                    self.onServicesUpdated?(services)
                    self.onDevicesUpdated?(sortedDevices)
                }
            }

            browser.start(queue: self.queue)
            self.browser = browser
        }
    }

    /// Registers or updates a device directly (e.g. from USB multiplexing or manual pairing).
    public func upsertDirectDevice(_ device: MirooDevice) {
        queue.sync {
            self.directDevices[device.id] = device

            var map: [String: MirooDevice] = [:]
            for d in self.discoveredDevices {
                map[d.id] = d
            }
            map[device.id] = device
            let sorted = Array(map.values).sorted { $0.displayName < $1.displayName }
            self.discoveredDevices = sorted
            self.onDevicesUpdated?(sorted)
        }
    }

    /// Manually or programmatically inserts/merges a discovered device.
    public func upsertDiscoveredDevice(_ device: MirooDevice) {
        queue.sync {
            guard device.id != DeviceIdentity.currentID else { return }
            var map: [String: MirooDevice] = [:]
            for d in self.discoveredDevices {
                map[d.id] = d
            }
            if var existing = map[device.id] {
                if device.isUSBAvailable { existing.isUSBAvailable = true }
                if device.isWiFiAvailable { existing.isWiFiAvailable = true }
                existing.displayName = device.displayName
                existing.modelName = device.modelName
                if let os = device.osVersion { existing.osVersion = os }
                existing.availability = device.availability
                existing.lastSeen = Date()
                if let ep = device.endpointDescription { existing.endpointDescription = ep }
                map[device.id] = existing
            } else {
                map[device.id] = device
            }
            let sorted = Array(map.values).sorted { $0.displayName < $1.displayName }
            self.discoveredDevices = sorted
            self.onDevicesUpdated?(sorted)
        }
    }

    /// Removes a direct device (e.g. when USB cable is detached).
    public func removeDirectDevice(id: String) {
        queue.sync {
            self.directDevices.removeValue(forKey: id)
            var map: [String: MirooDevice] = [:]
            for d in self.discoveredDevices {
                map[d.id] = d
            }
            if var existing = map[id] {
                existing.isUSBAvailable = false
                if !existing.isWiFiAvailable {
                    map.removeValue(forKey: id)
                } else {
                    map[id] = existing
                }
            }
            let sorted = Array(map.values).sorted { $0.displayName < $1.displayName }
            self.discoveredDevices = sorted
            self.onDevicesUpdated?(sorted)
        }
    }

    /// Removes a discovered device (e.g. when Bonjour endpoint disappears or explicitly cleared).
    public func removeDiscoveredDevice(id: String) {
        queue.sync {
            self.directDevices.removeValue(forKey: id)
            self.endpointsByDeviceID.removeValue(forKey: id)
            self.discoveredDevices.removeAll { $0.id == id }
            self.onDevicesUpdated?(self.discoveredDevices)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.internalStop()
        }
    }

    private func internalStop() {
        browser?.cancel()
        browser = nil
        discoveredServices.removeAll()
        discoveredDevices.removeAll()
        directDevices.removeAll()
        endpointsByDeviceID.removeAll()
    }
}
