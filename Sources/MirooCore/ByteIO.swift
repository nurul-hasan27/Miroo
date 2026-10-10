import Foundation

public struct ByteWriter {
    public private(set) var bytes = [UInt8]()
    public init(capacity: Int = 64) { bytes.reserveCapacity(capacity) }
    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    public mutating func u32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func u64(_ v: UInt64) { for s in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8((v >> UInt64(s)) & 0xFF)) } }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func raw<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
}

public struct ByteReader {
    let bytes: UnsafeRawBufferPointer
    public private(set) var pos = 0
    public init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }
    public var remaining: Int { bytes.count - pos }
    public mutating func u8() -> UInt8? { guard remaining >= 1 else { return nil }; defer { pos += 1 }; return bytes[pos] }
    public mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { pos += 2 }
        return UInt16(bytes[pos]) | UInt16(bytes[pos + 1]) << 8
    }
    public mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { pos += 4 }
        return UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
    }
    public mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }
    public mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[pos + i]) << UInt64(8 * i) }
        pos += 8
        return v
    }
    public mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
    public mutating func raw(_ n: Int) -> [UInt8]? {
        guard n >= 0, remaining >= n else { return nil }
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }
}
