import Foundation
import Network

public enum LinkService {
    public static let type = "_miroolink._tcp"
}

/// Phone side: advertises the device and accepts one Mac at a time.
public final class LinkAdvertiser: @unchecked Sendable {
    private var listener: NWListener?
    private let queue: DispatchQueue
    public var onConnection: ((NWConnection) -> Void)?
    public var onReady: ((NWEndpoint.Port) -> Void)?

    public init(queue: DispatchQueue) { self.queue = queue }

    public func start(name: String, deviceId: String) throws {
        let l = try NWListener(using: ControlChannel.parameters())
        l.service = NWListener.Service(name: name, type: LinkService.type, domain: nil, txtRecord: NWTXTRecord(["id": deviceId]))
        l.newConnectionHandler = { [weak self] c in self?.onConnection?(c) }
        l.stateUpdateHandler = { [weak self] s in
            if case .ready = s, let p = self?.listener?.port { self?.onReady?(p) }
        }
        listener = l
        l.start(queue: queue)
    }
    public func stop() { listener?.cancel(); listener = nil }
}

/// Mac side: finds phones.
public final class LinkBrowser: @unchecked Sendable {
    public struct Found: Equatable { public var name: String; public var id: String; public var endpoint: NWEndpoint }
    private var browser: NWBrowser?
    private let queue: DispatchQueue
    public var onChange: (([Found]) -> Void)?

    public init(queue: DispatchQueue) { self.queue = queue }

    public func start() {
        let p = NWParameters()
        p.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LinkService.type, domain: nil), using: p)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Found] = results.compactMap { r in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var id = name
                if case let .bonjour(txt) = r.metadata, let v = txt["id"] { id = v }
                return Found(name: name, id: id, endpoint: r.endpoint)
            }
            self?.onChange?(found)
        }
        browser = b
        b.start(queue: queue)
    }
    public func stop() { browser?.cancel(); browser = nil }
}
