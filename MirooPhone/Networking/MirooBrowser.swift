//
//  MirooBrowser.swift
//  Miroo
//
//  Phase 4: Bonjour service browser discovering Miroo Mac instances (_miroo._tcp) on the local network.
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

    public var onServicesUpdated: (([DiscoveredService]) -> Void)?
    private(set) public var discoveredServices: [DiscoveredService] = []

    public init() {}

    deinit {
        stop()
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
                    for result in results {
                        var name = "Miroo Mac"
                        var txtDict: [String: String] = [:]

                        if case .service(let sName, _, _, _) = result.endpoint {
                            name = sName
                        }

                        if case .bonjour(let txtRecord) = result.metadata {
                            for key in ["version", "codec", "width", "height", "fps"] {
                                if let val = txtRecord[key] {
                                    txtDict[key] = val
                                }
                            }
                        }

                        services.append(DiscoveredService(name: name, endpoint: result.endpoint, txtRecord: txtDict))
                    }

                    self.discoveredServices = services
                    self.onServicesUpdated?(services)
                }
            }

            browser.start(queue: self.queue)
            self.browser = browser
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
    }
}
