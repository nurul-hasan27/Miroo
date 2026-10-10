import Foundation

/// GF(2^8) arithmetic with primitive polynomial 0x11D.
public enum GF256 {
    public static let expTable: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 512)
        var x = 1
        for i in 0..<255 {
            t[i] = UInt8(x)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { t[i] = t[i - 255] }
        return t
    }()

    public static let logTable: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 256)
        for i in 0..<255 { t[Int(expTable[i])] = UInt8(i) }
        return t
    }()

    /// 256x256 multiplication table; row = coefficient.
    public static let mulTable: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 65536)
        for a in 1..<256 {
            for b in 1..<256 {
                t[a << 8 | b] = expTable[Int(logTable[a]) + Int(logTable[b])]
            }
        }
        return t
    }()

    @inline(__always)
    public static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 { mulTable[Int(a) << 8 | Int(b)] }

    public static func inv(_ a: UInt8) -> UInt8 {
        precondition(a != 0, "GF256 inverse of zero")
        return expTable[255 - Int(logTable[Int(a)])]
    }

    /// dst[i] ^= coef * src[i]
    public static func mulAdd(dst: UnsafeMutablePointer<UInt8>, src: UnsafePointer<UInt8>, count: Int, coef: UInt8) {
        if coef == 0 { return }
        if coef == 1 {
            for i in 0..<count { dst[i] ^= src[i] }
            return
        }
        mulTable.withUnsafeBufferPointer { tbl in
            let row = tbl.baseAddress! + Int(coef) << 8
            for i in 0..<count { dst[i] ^= row[Int(src[i])] }
        }
    }
}
