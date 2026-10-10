import Foundation

public enum InputKind: UInt8, Sendable {
    case down = 0, move = 1, up = 2, cancel = 3
    /// x,y = scroll deltas in points (positive y = finger moved down)
    case scroll = 4
    /// two-finger tap
    case secondaryClick = 5
    /// scroll gesture finished (finger lifted); lets the Mac end the scroll phase
    case scrollEnd = 6
}

/// One touch/gesture event. Positions are normalized 0...1 of the streamed viewport.
public struct InputEvent: Equatable, Sendable {
    public var seq: UInt32
    public var kind: InputKind
    public var x: Float, y: Float
    public init(seq: UInt32, kind: InputKind, x: Float, y: Float) { self.seq = seq; self.kind = kind; self.x = x; self.y = y }
}

/// Phone side: assigns sequence numbers and repeats the most recent events in every datagram, so a single
/// lost packet never loses a button-down/up. `.up`/`.cancel` are additionally re-sent a few times by the caller.
public final class InputSender {
    private var seq: UInt32 = 0
    private var recent: [InputEvent] = []
    private var packetSeq: UInt32 = 0
    public let redundancy: Int
    public init(redundancy: Int = 8) { self.redundancy = redundancy }

    public func add(_ kind: InputKind, x: Float, y: Float) {
        seq &+= 1
        recent.append(InputEvent(seq: seq, kind: kind, x: x, y: y))
        if recent.count > redundancy { recent.removeFirst(recent.count - redundancy) }
    }

    public var hasEvents: Bool { !recent.isEmpty }

    /// Datagram carrying the most recent events (oldest first).
    public func packet(nowUs32: UInt32) -> [UInt8] {
        packetSeq &+= 1
        var w = ByteWriter()
        PacketHeader(kind: .input, packetSeq: packetSeq, sendTimeUs: nowUs32).write(into: &w)
        w.u8(UInt8(recent.count))
        for e in recent { w.u32(e.seq); w.u8(e.kind.rawValue); w.f32(e.x); w.f32(e.y) }
        return w.bytes
    }
}

/// Mac side: de-duplicates events arriving in overlapping datagrams and returns only the new ones, in order.
public final class InputReceiver {
    private var last: UInt32 = 0
    private var started = false
    public init() {}

    public func ingest(_ body: UnsafeRawBufferPointer) -> [InputEvent] {
        var r = ByteReader(body)
        guard let n = r.u8() else { return [] }
        var out = [InputEvent]()
        for _ in 0..<Int(n) {
            guard let s = r.u32(), let k = r.u8(), let kind = InputKind(rawValue: k), let x = r.f32(), let y = r.f32() else { break }
            if !started { started = true; last = s &- 1 }
            if Int32(bitPattern: s &- last) > 0 {
                last = s
                out.append(InputEvent(seq: s, kind: kind, x: x, y: y))
            }
        }
        return out
    }
}
