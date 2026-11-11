import Foundation

/// Numbers and small formulas of the stage that need no renderer: headings, model sizing, the Studio camera and
/// floor, speed steps and picking. Ports of the matching pieces of `StageState.kt`, `StudioStage.kt`,
/// `StageGestures.kt` and `StageScreen.kt`.
public enum StageMath {

    // MARK: limits

    public static let maxActors = 5
    public static let userScaleMin: Float = 0.05
    public static let userScaleMax: Float = 12
    public static let speedMin: Float = 0.25
    public static let speedMax: Float = 2

    /// "Tempo" steps through these and wraps around.
    public static let speedSteps: [Float] = [0.5, 1, 1.5, 2]

    /// Scale presets behind a long press on "1:1": a desk figurine, real size, a giant.
    public static let sizePresets: [Float] = [0.15, 1, 3]

    public static func clampUserScale(_ value: Float) -> Float {
        value.isFinite ? min(max(value, userScaleMin), userScaleMax) : 1
    }

    public static func clampSpeed(_ value: Float) -> Float {
        value.isFinite ? min(max(value, speedMin), speedMax) : 1
    }

    /// The step after `current` in `speedSteps`, wrapping to the slowest.
    public static func nextSpeed(after current: Float) -> Float {
        speedSteps.first { $0 > current + 0.01 } ?? speedSteps[0]
    }

    // MARK: headings

    /// Heading (degrees about +Y, 0 = +Z) that makes something at `from` look towards `to`. Height is ignored.
    public static func yawTowards(from: SIMD3<Float>, to: SIMD3<Float>) -> Float {
        atan2(to.x - from.x, to.z - from.z) * 180 / .pi
    }

    /// Into (-PI, PI]: a finger angle jumps by a full turn when it crosses the -x axis.
    public static func wrapRadians(_ angle: Float) -> Float {
        if angle > .pi { return angle - 2 * .pi }
        if angle <= -.pi { return angle + 2 * .pi }
        return angle
    }

    /// Into (-180, 180], so a heading does not grow without bound over many turns.
    public static func wrapDegrees(_ degrees: Float) -> Float {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { return wrapped - 360 }
        if wrapped <= -180 { return wrapped + 360 }
        return wrapped
    }

    // MARK: model sizing

    private static let autoMinHeight: Float = 0.25
    private static let autoMaxHeight: Float = 4
    private static let autoHeight: Float = 1.75

    /// Model units to metres: from the manifest, or guessed for a bare GLB in the wrong unit.
    /// - Parameter modelHeight: rest-pose height in model units (0 when unknown)
    public static func baseScale(manifest: CharacterManifest, modelHeight height: Float) -> Float {
        if let wanted = manifest.heightMeters, wanted > 0, height > 0 { return wanted / height }
        if manifest.scale > 0 && manifest.scale != 1 { return manifest.scale }
        // A bare GLB exported in centimetres (or as a miniature) would be invisible or building-sized.
        if height > 0 && (height > autoMaxHeight || height < autoMinHeight) { return autoHeight / height }
        return 1
    }

    /// Diameter for the contact shadow under a character, metres.
    public static func footprintMeters(modelFootprint: Float, modelHeight: Float, pivotScale: Float) -> Float {
        max(max(modelFootprint, modelHeight * 0.35) * 1.25 * pivotScale, 0.05)
    }

    // MARK: Studio

    /// The fixed Studio camera: a 28 mm lens far enough back that a 1.8 m character standing on the origin takes
    /// `subjectFill` of the frame height, with the rest split between head-room and floor.
    public enum StudioCamera {
        public static let focalLengthMm: Float = 28

        /// The vertical field of view comes from the focal length against a 24 mm sensor height.
        static let sensorHeightMm: Float = 24
        static let subjectHeight: Float = 1.8
        static let subjectFill: Float = 0.58

        /// Slightly above the subject's middle, so the camera looks down a touch and the floor reads as a floor.
        static let eyeLift: Float = 0.05
        static let frameAspect: Float = 9.0 / 16.0

        public static let tanHalfVerticalFov: Float = sensorHeightMm / (2 * focalLengthMm)
        public static let tanHalfHorizontalFov: Float = tanHalfVerticalFov * frameAspect
        public static let verticalFovDegrees: Float = 2 * atan(tanHalfVerticalFov) * 180 / .pi

        public static let target = SIMD3<Float>(0, subjectHeight / 2, 0)
        public static let eye = SIMD3<Float>(
            0,
            subjectHeight / 2 + eyeLift,
            subjectHeight / subjectFill / (2 * tanHalfVerticalFov)
        )
    }

    /// Where new Studio characters appear on the floor. The fixed Studio camera sees only about 0.87 m to either
    /// side of the origin, so a full stage is three in front and two a step behind, in the gaps between them.
    public static let studioSlots: [SIMD3<Float>] = [
        SIMD3(0, 0, 0),
        SIMD3(-0.55, 0, 0),
        SIMD3(0.55, 0, 0),
        SIMD3(-0.3, 0, -1),
        SIMD3(0.3, 0, -1),
    ]
    private static let studioSlotRadius: Float = 0.3

    /// The first slot no character in `occupied` stands on; when every slot is taken they are reused in order.
    public static func studioSlot(occupied: [SIMD3<Float>]) -> SIMD3<Float> {
        let free = studioSlots.first { slot in
            !occupied.contains { abs($0.x - slot.x) < studioSlotRadius && abs($0.z - slot.z) < studioSlotRadius }
        }
        return free ?? studioSlots[occupied.count % studioSlots.count]
    }

    /// Studio only: the floor (y = 0) a one-finger drag moves the selected character over.
    ///
    /// The drag is mapped linearly from finger travel, not by casting the finger onto the floor: the camera looks
    /// almost level, so floor points near the horizon are many metres apart and a character grabbed by its body
    /// would shoot across the stage. Sideways travel moves it sideways by the same distance on screen; travel down
    /// the screen brings it towards the camera.
    public enum StudioFloor {
        static let backLimitZ: Float = -3
        static let frontLimitZ: Float = 1.5
        static let minCameraDistance: Float = 0.5

        /// Depth is foreshortened on screen, so finger travel counts double when it moves a character in depth.
        static let depthGain: Float = 2

        /// How many metres one unit of view height covers at floor depth `z`. `viewHeight` and the finger travel
        /// passed to `dragged` must use the same unit (points on iOS).
        public static func metresPerUnit(z: Float, viewHeight: Float) -> Float {
            if !(viewHeight > 0) { return 0 }
            let distance = max(StudioCamera.eye.z - z, minCameraDistance)
            return 2 * distance * StudioCamera.tanHalfVerticalFov / viewHeight
        }

        /// The floor position of a character that stood at (`startX`, `startZ`) after the finger travelled
        /// (`dx`, `dy`). The scale is fixed at the depth the drag began at, so the motion stays even.
        public static func dragged(startX: Float, startZ: Float, dx: Float, dy: Float, viewHeight: Float) -> SIMD3<Float> {
            let scale = metresPerUnit(z: startZ, viewHeight: viewHeight)
            return clamp(x: startX + dx * scale, z: startZ + dy * scale * depthGain)
        }

        /// Keeps a floor position on the stage: between the back and the front limit, and sideways inside what the
        /// fixed camera sees at that depth, so a character can never be dragged out of the picture.
        public static func clamp(x: Float, z: Float) -> SIMD3<Float> {
            let depth = min(max(z, backLimitZ), frontLimitZ)
            let halfWidth = (StudioCamera.eye.z - depth) * StudioCamera.tanHalfHorizontalFov
            return SIMD3(min(max(x, -halfWidth), halfWidth), 0, depth)
        }
    }

    // MARK: picking

    /// Distance along a ray to the upright box a character occupies, or nil when the ray misses it.
    ///
    /// The box stands on `base` (the character's ground point), is `height` tall and `width` wide and deep, and is
    /// turned by `yawDegrees` about +Y. `direction` need not be normalised; the result is in multiples of it.
    public static func rayHitDistance(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        base: SIMD3<Float>,
        yawDegrees: Float,
        width: Float,
        height: Float
    ) -> Float? {
        guard width > 0, height > 0 else { return nil }
        // Into the box's own frame: undo the translation, then the yaw.
        let a = -yawDegrees * .pi / 180
        let c = cos(a)
        let s = sin(a)
        func toLocal(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z) }
        let o = toLocal(origin - base)
        let d = toLocal(direction)
        let lo = SIMD3<Float>(-width / 2, 0, -width / 2)
        let hi = SIMD3<Float>(width / 2, height, width / 2)
        var tNear = -Float.infinity
        var tFar = Float.infinity
        for axis in 0..<3 {
            if abs(d[axis]) < 1e-9 {
                if o[axis] < lo[axis] || o[axis] > hi[axis] { return nil }
                continue
            }
            var t0 = (lo[axis] - o[axis]) / d[axis]
            var t1 = (hi[axis] - o[axis]) / d[axis]
            if t0 > t1 { swap(&t0, &t1) }
            tNear = max(tNear, t0)
            tFar = min(tFar, t1)
            if tNear > tFar { return nil }
        }
        if tFar < 0 { return nil }
        return max(tNear, 0)
    }
}
