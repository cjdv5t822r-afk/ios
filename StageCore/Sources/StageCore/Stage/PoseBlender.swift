import Foundation

/// Blends local node transforms (column-major 4x4, translation / rotation / scale, no shear) the way an
/// animation cross-fade needs: translation and scale are interpolated linearly, rotation along the shortest arc.
/// Port of `stage/PoseBlend.kt`; the maths is the same, line for line.
///
/// A pose is a flat `[Float]` holding 16 floats per node.
public struct PoseBlender {

    public init() {}

    /// Writes `mix(a, b, t)` into `out`. `t = 0` gives `a`, `t = 1` gives `b`. Each pointer addresses 16 floats.
    /// `out` may be the same memory as `a` or `b`: both inputs are read completely before anything is written.
    public func blend(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ t: Float, _ out: UnsafeMutablePointer<Float>) {
        if t <= 0 || PoseBlender.sameMatrix(a, b) {
            PoseBlender.copy(a, out)
            return
        }
        if t >= 1 {
            PoseBlender.copy(b, out)
            return
        }
        let da = Mat4.rotationAndScale(a)
        let db = Mat4.rotationAndScale(b)
        let tx = a[12] + (b[12] - a[12]) * t
        let ty = a[13] + (b[13] - a[13]) * t
        let tz = a[14] + (b[14] - a[14]) * t
        let q = Mat4.slerp(da.rotation, db.rotation, t)
        let s = da.scale + (db.scale - da.scale) * t
        Mat4.compose(translation: SIMD3(tx, ty, tz), rotation: q, scale: s, into: out)
    }

    /// Array form of `blend`: each offset points at the first of 16 floats. `out` may be the same array as `a` or `b`.
    public func blend(_ a: [Float], _ aOff: Int, _ b: [Float], _ bOff: Int, _ t: Float, into out: inout [Float], _ outOff: Int) {
        precondition(aOff >= 0 && aOff + 16 <= a.count && bOff >= 0 && bOff + 16 <= b.count)
        precondition(outOff >= 0 && outOff + 16 <= out.count)
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                out.withUnsafeMutableBufferPointer { po in
                    blend(pa.baseAddress! + aOff, pb.baseAddress! + bOff, t, po.baseAddress! + outOff)
                }
            }
        }
    }

    /// Blends two whole poses: `pose[i] = mix(from[i], pose[i], t)` for every matrix. The cross-fade's hot path.
    public func blendPose(from a: [Float], into pose: inout [Float], t: Float) {
        let count = min(a.count, pose.count) / 16
        guard count > 0 else { return }
        a.withUnsafeBufferPointer { pa in
            pose.withUnsafeMutableBufferPointer { pp in
                for i in 0..<count {
                    let o = i * 16
                    blend(pa.baseAddress! + o, UnsafePointer(pp.baseAddress! + o), t, pp.baseAddress! + o)
                }
            }
        }
    }

    private static func sameMatrix(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>) -> Bool {
        for i in 0..<16 where a[i] != b[i] { return false }
        return true
    }

    private static func copy(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<Float>) {
        if UnsafePointer(dst) == src { return }
        for i in 0..<16 { dst[i] = src[i] }
    }
}
