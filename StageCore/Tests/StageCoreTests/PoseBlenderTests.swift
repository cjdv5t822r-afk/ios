import XCTest
@testable import StageCore

/// Port of `PoseBlenderTest.kt`.
final class PoseBlenderTests: XCTestCase {

    private let blender = PoseBlender()

    private func blend(_ a: [Float], _ b: [Float], _ t: Float) -> [Float] {
        var out = [Float](repeating: 0, count: 16)
        blender.blend(a, 0, b, 0, t, into: &out, 0)
        return out
    }

    func testEndpointsAreExact() {
        let a = trsY(10, tx: 1)
        let b = trsY(80, sx: 2, tz: -3)
        XCTAssertEqual(blend(a, b, 0), a)
        XCTAssertEqual(blend(a, b, 1), b)
        XCTAssertEqual(blend(a, a, 0.37), a)
    }

    func testRotationTakesTheShortArc() {
        assertMatrix(blend(trsY(0), trsY(90), 0.5), trsY(45), accuracy: 1e-5)
        // 170 deg and -170 deg are 20 deg apart; halfway is 180 deg, not 0.
        assertMatrix(blend(trsY(170), trsY(-170), 0.5), trsY(180), accuracy: 1e-5)
    }

    func testTranslationAndScaleAreLinear() {
        let m = blend(trsY(0), trsY(0, sx: 3, sy: 2, sz: 5, tx: 4, ty: -2), 0.25)
        assertMatrix(m, trsY(0, sx: 1.5, sy: 1.25, sz: 2, tx: 1, ty: -0.5), accuracy: 1e-5)
    }

    func testResultStaysOrthonormalForArbitraryRotations() {
        // Rotation about X by 90 deg blended with rotation about Y by 90 deg.
        let rx: [Float] = [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1]
        let m = blend(rx, trsY(90), 0.3)
        for col in 0..<3 {
            let o = col * 4
            XCTAssertEqual((m[o] * m[o] + m[o + 1] * m[o + 1] + m[o + 2] * m[o + 2]).squareRoot(), 1, accuracy: 1e-5)
        }
        XCTAssertEqual(m[0] * m[4] + m[1] * m[5] + m[2] * m[6], 0, accuracy: 1e-5)
        XCTAssertEqual(m[0] * m[8] + m[1] * m[9] + m[2] * m[10], 0, accuracy: 1e-5)
        XCTAssertEqual(m[4] * m[8] + m[5] * m[9] + m[6] * m[10], 0, accuracy: 1e-5)
    }

    func testMirroredMatrixSurvivesARoundTrip() {
        // Blending a matrix with a slightly different copy must not flip or collapse the mirror.
        let m = blend(trsY(30, sx: -1, tx: 2), trsY(30, sx: -1, tx: 4), 0.5)
        assertMatrix(m, trsY(30, sx: -1, tx: 3), accuracy: 1e-5)
    }

    func testWorksInPlaceAndAtOffsets() {
        var pack = [Float](repeating: 0, count: 48)
        pack.replaceSubrange(16..<32, with: trsY(0))
        pack.replaceSubrange(32..<48, with: trsY(90))
        let source = pack
        blender.blend(source, 16, source, 32, 0.5, into: &pack, 16)
        assertMatrix(Array(pack[16..<32]), trsY(45), accuracy: 1e-5)
        XCTAssertEqual(Array(pack[32..<48]), trsY(90))
    }

    func testOutputMayBeTheSameMemoryAsAnInput() {
        var a = trsY(0)
        let b = trsY(90)
        a.withUnsafeMutableBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                blender.blend(UnsafePointer(pa.baseAddress!), pb.baseAddress!, 0.5, pa.baseAddress!)
            }
        }
        assertMatrix(a, trsY(45), accuracy: 1e-5)
    }

    func testWholePoseBlend() {
        let from = trsY(0) + trsY(10, tx: 2)
        var pose = trsY(90) + trsY(10, tx: 4)
        blender.blendPose(from: from, into: &pose, t: 0.5)
        assertMatrix(Array(pose[0..<16]), trsY(45), accuracy: 1e-5)
        assertMatrix(Array(pose[16..<32]), trsY(10, tx: 3), accuracy: 1e-5)
    }

    func testCollapsedScaleDoesNotProduceNaN() {
        var zero = [Float](repeating: 0, count: 16)
        zero[15] = 1
        let m = blend(zero, trsY(45), 0.5)
        XCTAssertFalse(m.contains { $0.isNaN })
    }
}

/// Column-major TRS matrix: rotation of `degrees` about +Y, per-axis scale, translation.
func trsY(
    _ degrees: Float, sx: Float = 1, sy: Float = 1, sz: Float = 1, tx: Float = 0, ty: Float = 0, tz: Float = 0
) -> [Float] {
    let a = Double(degrees) * .pi / 180
    let c = Float(cos(a))
    let s = Float(sin(a))
    return [
        c * sx, 0, -s * sx, 0,
        0, sy, 0, 0,
        s * sz, 0, c * sz, 0,
        tx, ty, tz, 1,
    ]
}

func assertMatrix(
    _ actual: [Float], _ expected: [Float], accuracy: Float, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (i, pair) in zip(actual, expected).enumerated() {
        XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "element \(i)", file: file, line: line)
    }
}
