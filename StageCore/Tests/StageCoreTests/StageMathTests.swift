import XCTest
@testable import StageCore

final class StageMathTests: XCTestCase {

    func testYawTowards() {
        let origin = SIMD3<Float>(0, 0, 0)
        XCTAssertEqual(StageMath.yawTowards(from: origin, to: SIMD3(0, 0, 1)), 0, accuracy: 1e-4)
        XCTAssertEqual(StageMath.yawTowards(from: origin, to: SIMD3(1, 5, 0)), 90, accuracy: 1e-4)
        XCTAssertEqual(StageMath.yawTowards(from: origin, to: SIMD3(-1, 0, 0)), -90, accuracy: 1e-4)
        XCTAssertEqual(abs(StageMath.yawTowards(from: origin, to: SIMD3(0, 0, -1))), 180, accuracy: 1e-4)
        XCTAssertEqual(StageMath.yawTowards(from: SIMD3(2, 0, 2), to: SIMD3(3, 0, 3)), 45, accuracy: 1e-4)
    }

    func testWrapping() {
        XCTAssertEqual(StageMath.wrapDegrees(190), -170, accuracy: 1e-4)
        XCTAssertEqual(StageMath.wrapDegrees(-190), 170, accuracy: 1e-4)
        XCTAssertEqual(StageMath.wrapDegrees(180), 180, accuracy: 1e-4)
        XCTAssertEqual(StageMath.wrapDegrees(-180), 180, accuracy: 1e-4)
        XCTAssertEqual(StageMath.wrapDegrees(725), 5, accuracy: 1e-3)
        XCTAssertEqual(StageMath.wrapRadians(Float.pi + 0.1), -Float.pi + 0.1, accuracy: 1e-5)
        XCTAssertEqual(StageMath.wrapRadians(-Float.pi - 0.1), Float.pi - 0.1, accuracy: 1e-5)
        XCTAssertEqual(StageMath.wrapRadians(0.5), 0.5)
    }

    func testBaseScale() {
        let plain = CharacterManifest(id: "x")
        XCTAssertEqual(StageMath.baseScale(manifest: plain, modelHeight: 1.8), 1)
        // A bare GLB in centimetres, or a miniature, is brought to a person's height.
        XCTAssertEqual(StageMath.baseScale(manifest: plain, modelHeight: 180), 1.75 / 180, accuracy: 1e-6)
        XCTAssertEqual(StageMath.baseScale(manifest: plain, modelHeight: 0.1), 17.5, accuracy: 1e-4)
        XCTAssertEqual(StageMath.baseScale(manifest: plain, modelHeight: 0), 1)
        // The manifest wins: height first, then an explicit scale.
        XCTAssertEqual(StageMath.baseScale(manifest: CharacterManifest(id: "x", scale: 3, heightMeters: 2), modelHeight: 4), 0.5)
        XCTAssertEqual(StageMath.baseScale(manifest: CharacterManifest(id: "x", scale: 0.01), modelHeight: 180), 0.01)
        XCTAssertEqual(StageMath.baseScale(manifest: CharacterManifest(id: "x", heightMeters: 2), modelHeight: 0), 1)
    }

    func testFootprint() {
        XCTAssertEqual(StageMath.footprintMeters(modelFootprint: 0.59, modelHeight: 1.83, pivotScale: 1), 1.83 * 0.35 * 1.25, accuracy: 1e-4)
        XCTAssertEqual(StageMath.footprintMeters(modelFootprint: 2, modelHeight: 1, pivotScale: 0.5), 1.25, accuracy: 1e-4)
        XCTAssertEqual(StageMath.footprintMeters(modelFootprint: 0, modelHeight: 0, pivotScale: 1), 0.05)
    }

    func testSpeedSteps() {
        XCTAssertEqual(StageMath.nextSpeed(after: 0.5), 1)
        XCTAssertEqual(StageMath.nextSpeed(after: 1), 1.5)
        XCTAssertEqual(StageMath.nextSpeed(after: 1.5), 2)
        XCTAssertEqual(StageMath.nextSpeed(after: 2), 0.5)
        XCTAssertEqual(StageMath.nextSpeed(after: 0.25), 0.5)
        XCTAssertEqual(StageMath.clampSpeed(9), 2)
        XCTAssertEqual(StageMath.clampSpeed(0), 0.25)
        XCTAssertEqual(StageMath.clampUserScale(100), 12)
        XCTAssertEqual(StageMath.clampUserScale(.nan), 1)
    }

    func testStudioCameraFramesAPerson() {
        // 28 mm against a 24 mm sensor: tan(half vertical fov) = 12 / 28.
        XCTAssertEqual(StageMath.StudioCamera.tanHalfVerticalFov, 12.0 / 28.0, accuracy: 1e-6)
        XCTAssertEqual(StageMath.StudioCamera.verticalFovDegrees, 46.397, accuracy: 0.01)
        // 1.8 m fills 58 % of the frame height at the origin.
        let visibleHeight = 2 * StageMath.StudioCamera.eye.z * StageMath.StudioCamera.tanHalfVerticalFov
        XCTAssertEqual(1.8 / visibleHeight, 0.58, accuracy: 1e-4)
        XCTAssertEqual(StageMath.StudioCamera.eye.z, 3.6207, accuracy: 1e-3)
    }

    func testStudioSlotsFillFrontRowFirst() {
        XCTAssertEqual(StageMath.studioSlot(occupied: []), SIMD3(0, 0, 0))
        XCTAssertEqual(StageMath.studioSlot(occupied: [SIMD3(0, 0, 0)]), SIMD3(-0.55, 0, 0))
        // A character dragged away frees its slot.
        XCTAssertEqual(StageMath.studioSlot(occupied: [SIMD3(0.8, 0, 1)]), SIMD3(0, 0, 0))
        XCTAssertEqual(StageMath.studioSlot(occupied: StageMath.studioSlots), StageMath.studioSlots[0])
    }

    func testStudioDragIsLinearAndStaysInFrame() {
        let viewHeight: Float = 700
        let scale = StageMath.StudioFloor.metresPerUnit(z: 0, viewHeight: viewHeight)
        XCTAssertEqual(scale, 2 * StageMath.StudioCamera.eye.z * StageMath.StudioCamera.tanHalfVerticalFov / viewHeight, accuracy: 1e-7)
        let moved = StageMath.StudioFloor.dragged(startX: 0, startZ: 0, dx: 50, dy: 20, viewHeight: viewHeight)
        XCTAssertEqual(moved.x, 50 * scale, accuracy: 1e-5)
        XCTAssertEqual(moved.z, 20 * scale * 2, accuracy: 1e-5)
        XCTAssertEqual(moved.y, 0)
        // Dragged far out, the character stops at the edge of what the camera sees and at the depth limits.
        let far = StageMath.StudioFloor.dragged(startX: 0, startZ: 0, dx: 100_000, dy: -100_000, viewHeight: viewHeight)
        XCTAssertEqual(far.z, -3)
        XCTAssertEqual(far.x, (StageMath.StudioCamera.eye.z + 3) * StageMath.StudioCamera.tanHalfHorizontalFov, accuracy: 1e-4)
        XCTAssertEqual(StageMath.StudioFloor.clamp(x: 0, z: 99).z, 1.5)
        XCTAssertEqual(StageMath.StudioFloor.metresPerUnit(z: 0, viewHeight: 0), 0)
    }

    func testPickingRay() throws {
        let base = SIMD3<Float>(1, 0, -2)
        // Straight at the middle of the box from the front.
        let hit = StageMath.rayHitDistance(
            origin: SIMD3(1, 1, 3), direction: SIMD3(0, 0, -1), base: base, yawDegrees: 0, width: 0.6, height: 1.8
        )
        XCTAssertEqual(try XCTUnwrap(hit), 4.7, accuracy: 1e-4)
        // Over its head, beside it, and pointing away.
        XCTAssertNil(StageMath.rayHitDistance(origin: SIMD3(1, 2.5, 3), direction: SIMD3(0, 0, -1), base: base, yawDegrees: 0, width: 0.6, height: 1.8))
        XCTAssertNil(StageMath.rayHitDistance(origin: SIMD3(2, 1, 3), direction: SIMD3(0, 0, -1), base: base, yawDegrees: 0, width: 0.6, height: 1.8))
        XCTAssertNil(StageMath.rayHitDistance(origin: SIMD3(1, 1, 3), direction: SIMD3(0, 0, 1), base: base, yawDegrees: 0, width: 0.6, height: 1.8))
        // A box turned by 45 degrees is wider across its diagonal: a ray 0.4 m off-centre now hits.
        XCTAssertNil(StageMath.rayHitDistance(origin: SIMD3(1.4, 1, 3), direction: SIMD3(0, 0, -1), base: base, yawDegrees: 0, width: 0.6, height: 1.8))
        XCTAssertNotNil(StageMath.rayHitDistance(origin: SIMD3(1.4, 1, 3), direction: SIMD3(0, 0, -1), base: base, yawDegrees: 45, width: 0.6, height: 1.8))
        // From inside the box the distance is zero.
        XCTAssertEqual(StageMath.rayHitDistance(origin: SIMD3(1, 1, -2), direction: SIMD3(0, 1, 0), base: base, yawDegrees: 0, width: 0.6, height: 1.8), 0)
    }
}
