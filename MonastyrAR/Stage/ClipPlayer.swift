import Foundation
import RealityKit
import simd
import StageCore

/// Plays the skeletal animation clips of one loaded model: one clip at a time, cross-faded, with speed and pause.
/// Port of `stage/ClipPlayer.kt`.
///
/// RealityKit's own animation playback is not used. Every frame the pose is computed here: start from the rest
/// pose, apply the clip at its current time, and during a cross-fade do that for both clips and mix them per node.
/// That makes the pose a pure function of (clip, time), exactly as on Android: a clip that animates only some
/// bones never leaves the others stuck where the previous clip left them.
///
/// What differs from Android is only where the pose is written. Filament takes node transforms and derives the
/// bone matrices itself; RealityKit wants `jointTransforms` on each skinned `ModelEntity` (joint relative to its
/// parent joint), so the node pose is converted to that form, and the node entities get their transforms as well so
/// that anything rigidly attached to a bone follows.
///
/// Main thread only. Create it once the model is loaded and call `release` when the model leaves the stage.
@MainActor
final class ClipPlayer {

    let timeline: ClipTimeline

    /// Called when a one-shot clip reached its end (with its clip index).
    var onOneShotEnded: ((Int) -> Void)?

    private let model: LoadedModel
    private let rest: [Float]
    private var poseA: [Float]
    private var poseB: [Float]
    private let blender = PoseBlender()
    private var released = false

    /// - Parameter idleIndex: clip to return to after a one-shot; nil to hold the last frame
    init(model: LoadedModel, idleIndex: Int?) {
        self.model = model
        let clips = model.document.rawClips()
        timeline = ClipTimeline(
            durations: clips.map(\.durationSeconds),
            idleIndex: idleIndex.flatMap { clips.indices.contains($0) ? $0 : nil }
        )
        rest = model.document.restPose()
        poseA = rest
        poseB = rest
        // The converter leaves the skeleton in its bind pose and knows nothing of the nodes above the root joint.
        // Writing the rest pose once puts the model where the file says, clip or no clip.
        write(rest)
    }

    /// Starts a clip from its beginning, cross-fading from the current pose.
    func play(_ index: Int, loop: Bool) {
        if released { return }
        timeline.play(index, loop: loop)
    }

    /// Stops driving the model. Safe to call more than once.
    func release() {
        released = true
        onOneShotEnded = nil
    }

    /// Advances the timeline by `deltaTime` seconds and writes the resulting pose.
    func update(deltaTime: Float) {
        if released { return }
        let ended = timeline.advance(deltaTime)
        applyPose()
        if ended >= 0 { onOneShotEnded?(ended) }
    }

    private func applyPose() {
        let current = timeline.current
        if current < 0 { return } // nothing played yet: the model stays in its rest pose
        let document = model.document
        ClipPlayer.copy(rest, into: &poseB)
        document.apply(animation: current, time: timeline.time, to: &poseB)
        if timeline.isFading {
            ClipPlayer.copy(rest, into: &poseA)
            document.apply(animation: timeline.previous, time: timeline.previousTime, to: &poseA)
            // Ease the mix so the hand-over has no visible start or stop.
            let f = timeline.fade
            blender.blendPose(from: poseA, into: &poseB, t: f * f * (3 - 2 * f))
        }
        write(poseB)
    }

    /// Hands a node pose (16 floats per glTF node, relative to the parent) to RealityKit.
    private func write(_ pose: [Float]) {
        let document = model.document
        guard pose.count == document.poseLength else { return }

        // Nodes a clip moves: their entities follow, so rigid meshes under an animated node stay attached.
        pose.withUnsafeBufferPointer { buffer in
            for node in document.animatedNodes {
                guard let entity = model.nodeEntities[node] else { continue }
                entity.transform = Transform(matrix: simd_float4x4(columnMajor: buffer.baseAddress! + node * 16))
            }
        }

        if model.skinBindings.isEmpty { return }
        let globals = document.globalMatrices(of: pose)
        for binding in model.skinBindings {
            let joints = document.jointLocalMatrices(globals: globals, skin: binding.skin, meshNode: binding.meshNode)
            let count = joints.count / 16
            guard count == binding.entity.jointNames.count else { continue }
            var transforms: [Transform] = []
            transforms.reserveCapacity(count)
            joints.withUnsafeBufferPointer { buffer in
                for j in 0..<count {
                    transforms.append(Transform(matrix: simd_float4x4(columnMajor: buffer.baseAddress! + j * 16)))
                }
            }
            binding.entity.jointTransforms = transforms
        }
    }

    /// Copies without replacing the destination's storage, so no pose array is reallocated per frame.
    private static func copy(_ source: [Float], into destination: inout [Float]) {
        guard source.count == destination.count else {
            destination = source
            return
        }
        source.withUnsafeBufferPointer { src in
            destination.withUnsafeMutableBufferPointer { dst in
                for i in 0..<src.count { dst[i] = src[i] }
            }
        }
    }
}
