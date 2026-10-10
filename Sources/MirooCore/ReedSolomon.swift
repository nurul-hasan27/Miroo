import Foundation

/// Systematic Reed-Solomon erasure code over GF(256) built from a Cauchy matrix.
/// Any `k` of the `k + m` chunks recover the original data. Requires `k + m <= 256`.
public enum ReedSolomon {
    /// Cauchy coefficient for parity row `p` and data column `j`.
    /// x_p = p, y_j = 255 - j. For p <= 255 - k these never collide (y_j >= 256 - k), so parity rows can be
    /// generated lazily, one at a time, without knowing the final parity count (incremental redundancy).
    @inline(__always)
    static func coef(parity p: Int, data j: Int, m: Int) -> UInt8 {
        GF256.inv(UInt8(p) ^ UInt8(255 - j))
    }

    /// One parity chunk (row `p`, any `p <= 255 - k`) for the given data chunks.
    public static func parityChunk(data: [[UInt8]], row p: Int) -> [UInt8] {
        let k = data.count, size = data[0].count
        precondition(p + k <= 255)
        var out = [UInt8](repeating: 0, count: size)
        out.withUnsafeMutableBufferPointer { dst in
            for j in 0..<k {
                data[j].withUnsafeBufferPointer { src in
                    GF256.mulAdd(dst: dst.baseAddress!, src: src.baseAddress!, count: size, coef: coef(parity: p, data: j, m: 0))
                }
            }
        }
        return out
    }

    /// Computes `m` parity chunks for `k` equally sized data chunks.
    public static func encode(data: [[UInt8]], m: Int) -> [[UInt8]] {
        let k = data.count
        precondition(k > 0 && k + m <= 256)
        let size = data[0].count
        var parity = [[UInt8]](repeating: [UInt8](repeating: 0, count: size), count: m)
        for p in 0..<m {
            parity[p].withUnsafeMutableBufferPointer { dst in
                for j in 0..<k {
                    data[j].withUnsafeBufferPointer { src in
                        GF256.mulAdd(dst: dst.baseAddress!, src: src.baseAddress!, count: size,
                                     coef: coef(parity: p, data: j, m: m))
                    }
                }
            }
        }
        return parity
    }

    /// Recovers missing data chunks. `chunks[i]` for `i < k` are data, for `i >= k` parity (`i - k`).
    /// Returns the full `k` data chunks, or nil when not enough chunks are present.
    public static func decode(k: Int, m: Int, size: Int, chunks: [Int: [UInt8]]) -> [[UInt8]]? {
        var out = [[UInt8]?](repeating: nil, count: k)
        var missing = [Int]()
        for j in 0..<k {
            if let c = chunks[j] { out[j] = c } else { missing.append(j) }
        }
        if missing.isEmpty { return out.map { $0! } }
        let parityIdx = chunks.keys.filter { $0 >= k }.map { $0 - k }.sorted()   // parity row numbers (may exceed original m)
        guard parityIdx.count >= missing.count else { return nil }
        let e = missing.count
        let rows = Array(parityIdx.prefix(e))

        // RHS_r = parity_r  XOR  sum_{j present} C[r][j] * d_j
        var rhs = [[UInt8]]()
        for r in rows {
            var v = chunks[k + r]!
            if v.count < size { v += [UInt8](repeating: 0, count: size - v.count) }
            v.withUnsafeMutableBufferPointer { dst in
                for j in 0..<k where chunks[j] != nil {
                    var src = chunks[j]!
                    if src.count < size { src += [UInt8](repeating: 0, count: size - src.count) }
                    src.withUnsafeBufferPointer { s in
                        GF256.mulAdd(dst: dst.baseAddress!, src: s.baseAddress!, count: size,
                                     coef: coef(parity: r, data: j, m: m))
                    }
                }
            }
            rhs.append(v)
        }

        // Solve A x = rhs with A[r][c] = C[rows[r]][missing[c]]  (e x e Cauchy => invertible)
        var a = [[UInt8]](repeating: [UInt8](repeating: 0, count: e), count: e)
        for r in 0..<e { for c in 0..<e { a[r][c] = coef(parity: rows[r], data: missing[c], m: m) } }
        guard let inv = invert(a) else { return nil }
        for c in 0..<e {
            var x = [UInt8](repeating: 0, count: size)
            x.withUnsafeMutableBufferPointer { dst in
                for r in 0..<e {
                    rhs[r].withUnsafeBufferPointer { s in
                        GF256.mulAdd(dst: dst.baseAddress!, src: s.baseAddress!, count: size, coef: inv[c][r])
                    }
                }
            }
            out[missing[c]] = x
        }
        return out.map { $0! }
    }

    static func invert(_ m: [[UInt8]]) -> [[UInt8]]? {
        let n = m.count
        var a = m
        var inv = (0..<n).map { i in (0..<n).map { UInt8($0 == i ? 1 : 0) } }
        for col in 0..<n {
            guard let pivot = (col..<n).first(where: { a[$0][col] != 0 }) else { return nil }
            a.swapAt(col, pivot); inv.swapAt(col, pivot)
            let pinv = GF256.inv(a[col][col])
            for c in 0..<n { a[col][c] = GF256.mul(a[col][c], pinv); inv[col][c] = GF256.mul(inv[col][c], pinv) }
            for r in 0..<n where r != col && a[r][col] != 0 {
                let f = a[r][col]
                for c in 0..<n {
                    a[r][c] ^= GF256.mul(f, a[col][c])
                    inv[r][c] ^= GF256.mul(f, inv[col][c])
                }
            }
        }
        return inv
    }
}
