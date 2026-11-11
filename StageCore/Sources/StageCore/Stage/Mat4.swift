import Foundation

/// Minimal 4x4 matrix helpers on flat, column-major `Float` storage (the layout glTF, Filament and simd share).
/// Quaternions are `SIMD4<Float>` in (x, y, z, w) order, as in glTF.
public enum Mat4 {

    static let eps: Float = 1e-8

    public static let identity: [Float] = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ]

    public static let identityRotation = SIMD4<Float>(0, 0, 0, 1)

    // MARK: decompose / compose

    /// Splits the upper 3x3 of the matrix at `m` into a unit quaternion and a per-axis scale.
    /// A mirrored basis (negative determinant) is folded into the X scale; a collapsed axis gives the identity rotation.
    public static func rotationAndScale(_ m: UnsafePointer<Float>) -> (rotation: SIMD4<Float>, scale: SIMD3<Float>) {
        var c0x = m[0], c0y = m[1], c0z = m[2]
        var c1x = m[4], c1y = m[5], c1z = m[6]
        var c2x = m[8], c2y = m[9], c2z = m[10]
        var sx = (c0x * c0x + c0y * c0y + c0z * c0z).squareRoot()
        let sy = (c1x * c1x + c1y * c1y + c1z * c1z).squareRoot()
        let sz = (c2x * c2x + c2y * c2y + c2z * c2z).squareRoot()
        // A mirrored basis is not a rotation; fold the mirror into the X scale.
        let det = c0x * (c1y * c2z - c1z * c2y) - c0y * (c1x * c2z - c1z * c2x) + c0z * (c1x * c2y - c1y * c2x)
        if det < 0 { sx = -sx }
        let scale = SIMD3<Float>(sx, sy, sz)
        if abs(sx) < eps || sy < eps || sz < eps {
            // Collapsed axis: there is no orientation to recover.
            return (identityRotation, scale)
        }
        c0x /= sx; c0y /= sx; c0z /= sx
        c1x /= sy; c1y /= sy; c1z /= sy
        c2x /= sz; c2y /= sz; c2z /= sz
        // Rotation matrix R[row][col] with columns c0, c1, c2.
        var q = SIMD4<Float>(0, 0, 0, 1)
        let trace = c0x + c1y + c2z
        if trace > 0 {
            let k = (trace + 1).squareRoot() * 2
            q.w = 0.25 * k
            q.x = (c1z - c2y) / k
            q.y = (c2x - c0z) / k
            q.z = (c0y - c1x) / k
        } else if c0x > c1y && c0x > c2z {
            let k = (1 + c0x - c1y - c2z).squareRoot() * 2
            q.w = (c1z - c2y) / k
            q.x = 0.25 * k
            q.y = (c1x + c0y) / k
            q.z = (c2x + c0z) / k
        } else if c1y > c2z {
            let k = (1 + c1y - c0x - c2z).squareRoot() * 2
            q.w = (c2x - c0z) / k
            q.x = (c1x + c0y) / k
            q.y = 0.25 * k
            q.z = (c2y + c1z) / k
        } else {
            let k = (1 + c2z - c0x - c1y).squareRoot() * 2
            q.w = (c0y - c1x) / k
            q.x = (c2x + c0z) / k
            q.y = (c2y + c1z) / k
            q.z = 0.25 * k
        }
        return (q, scale)
    }

    /// Translation, rotation and scale of the matrix that starts at `offset` in `m`.
    public static func decompose(_ m: [Float], at offset: Int = 0)
        -> (translation: SIMD3<Float>, rotation: SIMD4<Float>, scale: SIMD3<Float>)
    {
        precondition(offset >= 0 && offset + 16 <= m.count)
        let rs = m.withUnsafeBufferPointer { rotationAndScale($0.baseAddress! + offset) }
        return (SIMD3(m[offset + 12], m[offset + 13], m[offset + 14]), rs.rotation, rs.scale)
    }

    /// Spherical interpolation along the shortest arc. The result is normalised.
    public static func slerp(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        var bb = b
        var dot = a.x * bb.x + a.y * bb.y + a.z * bb.z + a.w * bb.w
        if dot < 0 {
            dot = -dot
            bb = -bb
        }
        let wa: Float
        let wb: Float
        if dot > 0.9995 {
            // Nearly identical: linear interpolation is exact enough and avoids dividing by ~0.
            wa = 1 - t
            wb = t
        } else {
            let theta = acos(dot)
            let sinTheta = sin(theta)
            wa = sin((1 - t) * theta) / sinTheta
            wb = sin(t * theta) / sinTheta
        }
        return normalized(a * wa + bb * wb)
    }

    /// Unit quaternion in the direction of `q`, or the identity rotation when `q` has no length.
    public static func normalized(_ q: SIMD4<Float>) -> SIMD4<Float> {
        let len = (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).squareRoot()
        if !(len >= eps) { return identityRotation }
        return q / len
    }

    /// Writes the TRS matrix into the 16 floats at `out`.
    public static func compose(
        translation t: SIMD3<Float>, rotation q: SIMD4<Float>, scale s: SIMD3<Float>, into out: UnsafeMutablePointer<Float>
    ) {
        let x = q.x, y = q.y, z = q.z, w = q.w
        let xx = x * x, yy = y * y, zz = z * z
        let xy = x * y, xz = x * z, yz = y * z
        let wx = w * x, wy = w * y, wz = w * z
        out[0] = (1 - 2 * (yy + zz)) * s.x
        out[1] = (2 * (xy + wz)) * s.x
        out[2] = (2 * (xz - wy)) * s.x
        out[3] = 0
        out[4] = (2 * (xy - wz)) * s.y
        out[5] = (1 - 2 * (xx + zz)) * s.y
        out[6] = (2 * (yz + wx)) * s.y
        out[7] = 0
        out[8] = (2 * (xz + wy)) * s.z
        out[9] = (2 * (yz - wx)) * s.z
        out[10] = (1 - 2 * (xx + yy)) * s.z
        out[11] = 0
        out[12] = t.x
        out[13] = t.y
        out[14] = t.z
        out[15] = 1
    }

    public static func compose(translation t: SIMD3<Float>, rotation q: SIMD4<Float>, scale s: SIMD3<Float>) -> [Float] {
        var out = [Float](repeating: 0, count: 16)
        out.withUnsafeMutableBufferPointer { compose(translation: t, rotation: q, scale: s, into: $0.baseAddress!) }
        return out
    }

    // MARK: products

    /// `out = a * b` (apply `b` first, then `a`). `out` must not overlap `a` or `b`.
    public static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        for c in 0..<4 {
            let b0 = b[c * 4], b1 = b[c * 4 + 1], b2 = b[c * 4 + 2], b3 = b[c * 4 + 3]
            for r in 0..<4 {
                out[c * 4 + r] = a[r] * b0 + a[4 + r] * b1 + a[8 + r] * b2 + a[12 + r] * b3
            }
        }
    }

    public static func multiply(_ a: [Float], _ b: [Float]) -> [Float] {
        precondition(a.count >= 16 && b.count >= 16)
        var out = [Float](repeating: 0, count: 16)
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                out.withUnsafeMutableBufferPointer { po in
                    multiply(pa.baseAddress!, pb.baseAddress!, into: po.baseAddress!)
                }
            }
        }
        return out
    }

    /// The point `p` transformed by the matrix that starts at `offset` in `m` (w = 1, no perspective divide).
    public static func transformPoint(_ m: [Float], _ p: SIMD3<Float>, at offset: Int = 0) -> SIMD3<Float> {
        SIMD3(
            m[offset] * p.x + m[offset + 4] * p.y + m[offset + 8] * p.z + m[offset + 12],
            m[offset + 1] * p.x + m[offset + 5] * p.y + m[offset + 9] * p.z + m[offset + 13],
            m[offset + 2] * p.x + m[offset + 6] * p.y + m[offset + 10] * p.z + m[offset + 14]
        )
    }

    /// Inverse of an affine matrix (last row 0, 0, 0, 1), or nil when its 3x3 part cannot be inverted.
    public static func invertAffine(_ m: [Float], at offset: Int = 0) -> [Float]? {
        precondition(offset >= 0 && offset + 16 <= m.count)
        let a = m[offset], b = m[offset + 4], c = m[offset + 8]
        let d = m[offset + 1], e = m[offset + 5], f = m[offset + 9]
        let g = m[offset + 2], h = m[offset + 6], i = m[offset + 10]
        let tx = m[offset + 12], ty = m[offset + 13], tz = m[offset + 14]
        let co0 = e * i - f * h
        let co1 = f * g - d * i
        let co2 = d * h - e * g
        let det = a * co0 + b * co1 + c * co2
        if !det.isFinite || abs(det) < 1e-20 { return nil }
        let inv = 1 / det
        // Rows of the inverse 3x3 (adjugate / det).
        let r00 = co0 * inv, r01 = (c * h - b * i) * inv, r02 = (b * f - c * e) * inv
        let r10 = co1 * inv, r11 = (a * i - c * g) * inv, r12 = (c * d - a * f) * inv
        let r20 = co2 * inv, r21 = (b * g - a * h) * inv, r22 = (a * e - b * d) * inv
        return [
            r00, r10, r20, 0,
            r01, r11, r21, 0,
            r02, r12, r22, 0,
            -(r00 * tx + r01 * ty + r02 * tz),
            -(r10 * tx + r11 * ty + r12 * tz),
            -(r20 * tx + r21 * ty + r22 * tz),
            1,
        ]
    }
}
