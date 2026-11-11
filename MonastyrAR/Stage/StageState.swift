import Foundation
import Observation
import StageCore

/// Where a character's model is in its life.
enum ActorLoad: Equatable {
    case loading
    case ready
    case failed(String?)
}

/// What the AR view wants to tell the creator right now. The UI maps these to text.
enum ArHint: Equatable {
    /// Nothing to say.
    case none
    /// Session is still starting or the camera is not tracking yet.
    case starting
    /// Tracking works but no surface has been found: move the phone around.
    case findSurface
    /// A surface is known and a character is waiting to be placed: tap to place it.
    case tapToPlace
    case tooDark
    case tooFast
    case lowDetail
    case cameraBusy
}

/// One character on the stage. All of it is main-thread state; SwiftUI observes it and `StageController` copies it
/// into the scene every frame. Port of `Actor` in `stage/StageState.kt`.
///
/// Scene graph per character (built by `StageController`):
///
///     root            at `position` in world metres, never scaled or turned
///      ├─ pivot       heading (`yawDegrees` + the manifest's `rotationY`) and uniform scale = `baseScale` * `userScale`
///      │   └─ holder  lifted by -`modelMinY` so the lowest point of the rest pose is on the ground
///      │       └─ the loaded model
///      └─ shadow      contact shadow scaled to `footprintMeters`
@MainActor
@Observable
final class StageActor: Identifiable {
    let id: Int
    let pack: CharacterPack

    /// True for a character placed on a detected surface in AR, false for one on the Studio floor.
    let isInAR: Bool

    var load: ActorLoad = .loading

    /// Clips shown in the UI (manifest overrides and naming rules applied). Empty until the model is ready.
    private(set) var clips: [Clip] = []

    /// The clip the character rests in and returns to after a one-shot, if the model has one.
    private(set) var defaultClip: Clip?

    /// Clip currently shown (after a one-shot ends this goes back to `defaultClip`).
    private(set) var currentClip: Clip?

    /// Heading about +Y in world space, degrees; 0 faces +Z. The manifest's `rotationY` is added on top.
    var yawDegrees: Float = 0

    /// Pinch scale on top of `baseScale`. 1 = real size.
    private(set) var userScale: Float = 1

    /// Where the character stands: on the detected floor in AR, on the Studio floor (y = 0) in Studio.
    var position = SIMD3<Float>(0, 0, 0)

    /// Model units to metres: from the manifest, or guessed for a bare GLB in the wrong unit.
    private(set) var baseScale: Float = 1

    /// Rest-pose height in model units.
    private(set) var modelHeight: Float = 0

    /// Lowest point of the rest pose in model units (0 for a model authored with its origin at the feet).
    private(set) var modelMinY: Float = 0

    /// Rest-pose footprint (larger of width / depth) in model units.
    private(set) var modelFootprint: Float = 0

    private(set) var speed: Float = 1
    private(set) var paused = false

    /// The model is on the stage but a skinned mesh of it has no skeleton, so clips cannot move it.
    private(set) var animationUnavailable = false

    @ObservationIgnored private var player: ClipPlayer?

    init(id: Int, pack: CharacterPack, isInAR: Bool) {
        self.id = id
        self.pack = pack
        self.isInAR = isInAR
    }

    var name: String { pack.name }

    /// Height of the character as it stands on the stage, metres.
    var heightMeters: Float { modelHeight * baseScale * userScale }

    /// Uniform scale to put on the pivot.
    var pivotScale: Float { baseScale * userScale }

    /// Heading of the model itself, the manifest's correction included.
    var modelYawDegrees: Float { yawDegrees + pack.manifest.rotationY }

    /// Diameter for the contact shadow under the character, metres.
    var footprintMeters: Float {
        StageMath.footprintMeters(modelFootprint: modelFootprint, modelHeight: modelHeight, pivotScale: pivotScale)
    }

    /// Call once the model is in the scene: reads the clips and bounds, creates the animation driver and starts
    /// the default clip.
    func attachModel(_ model: LoadedModel) {
        detachModel()
        let size = model.bounds?.size ?? SIMD3<Float>(0, 0, 0)
        let minY = model.bounds?.min.y ?? 0
        modelHeight = size.y.isFinite && size.y > 0 ? size.y : 0
        modelMinY = minY.isFinite ? minY : 0
        let footprint = max(size.x, size.z)
        modelFootprint = footprint.isFinite && footprint > 0 ? footprint : 0
        baseScale = StageMath.baseScale(manifest: pack.manifest, modelHeight: modelHeight)
        animationUnavailable = model.hasUnboundSkin

        let uiClips = ClipRules.buildClips(manifest: pack.manifest, raw: model.document.rawClips())
        let idle = ClipRules.defaultClip(manifest: pack.manifest, clips: uiClips)
        let newPlayer = ClipPlayer(model: model, idleIndex: idle?.index)
        newPlayer.timeline.speed = speed
        newPlayer.timeline.paused = paused
        newPlayer.onOneShotEnded = { [weak self] _ in
            guard let self else { return }
            self.currentClip = self.defaultClip ?? self.currentClip
        }
        player = newPlayer
        clips = uiClips
        defaultClip = idle
        currentClip = nil
        if let first = idle ?? uiClips.first(where: { $0.loop }) { play(first) }
        load = .ready
    }

    /// Call when the model leaves the scene.
    func detachModel() {
        player?.release()
        player = nil
    }

    /// Advances the animation and writes the pose into the model. Called once per rendered frame.
    func updateAnimation(deltaTime: Float) {
        player?.update(deltaTime: deltaTime)
    }

    func play(_ clip: Clip) {
        guard let player else { return }
        player.play(clip.index, loop: clip.loop)
        currentClip = clip
    }

    /// Plays `clip` with the loop flag flipped (long-press on a clip button).
    func playToggledLoop(_ clip: Clip) {
        play(clip.togglingLoop())
    }

    func changeSpeed(_ value: Float) {
        speed = StageMath.clampSpeed(value)
        player?.timeline.speed = speed
    }

    func changePaused(_ value: Bool) {
        paused = value
        player?.timeline.paused = value
    }

    func changeUserScale(_ value: Float) {
        userScale = StageMath.clampUserScale(value)
    }

    /// Turns the character so its front (+Z) points at `target` (both in world space, height ignored).
    func face(target: SIMD3<Float>, from: SIMD3<Float>) {
        yawDegrees = StageMath.yawTowards(from: from, to: target)
    }
}

/// Everything on the stage: the characters, which one is selected and what the next tap should do.
/// Shared by AR and Studio; the list is cleared when the mode changes (models do not survive it).
/// Main thread only. Port of `StageState` in `stage/StageState.kt`.
@MainActor
@Observable
final class StageState {

    private(set) var actors: [StageActor] = []

    private(set) var selectedId: Int?

    var selected: StageActor? { actors.first { $0.id == selectedId } }

    /// When on, animation / speed / pause commands go to every character instead of the selected one.
    var applyToAll = false

    /// AR only: the pack the next tap on a surface will place. Nil means taps only select.
    var armedPack: CharacterPack?

    /// AR only: maintained by the AR stage, shown by the UI.
    var arHint: ArHint = .starting

    var canAddMore: Bool { actors.count < StageMath.maxActors }

    @ObservationIgnored private var nextId = 1

    /// Adds a character on a detected surface, facing the camera. Returns nil when the stage is full.
    /// - Parameters:
    ///   - hitPosition: where on the surface, world space
    ///   - cameraPosition: where the phone is, world space
    @discardableResult
    func addInAr(pack: CharacterPack, hitPosition: SIMD3<Float>, cameraPosition: SIMD3<Float>) -> StageActor? {
        guard canAddMore else { return nil }
        let actor = StageActor(id: nextId, pack: pack, isInAR: true)
        nextId += 1
        actor.position = hitPosition
        actor.face(target: cameraPosition, from: hitPosition)
        actors.append(actor)
        selectedId = actor.id
        armedPack = nil
        return actor
    }

    /// Adds a character on the Studio floor, next to the ones already there, facing the camera (+Z).
    @discardableResult
    func addInStudio(pack: CharacterPack) -> StageActor? {
        guard canAddMore else { return nil }
        let actor = StageActor(id: nextId, pack: pack, isInAR: false)
        nextId += 1
        actor.position = StageMath.studioSlot(occupied: actors.map(\.position))
        actors.append(actor)
        selectedId = actor.id
        return actor
    }

    func remove(_ actor: StageActor) {
        actor.detachModel()
        actors.removeAll { $0.id == actor.id }
        if selectedId == actor.id { selectedId = actors.last?.id }
    }

    /// Removes every character (mode switch, "clear stage").
    func clear() {
        actors.forEach { $0.detachModel() }
        actors.removeAll()
        selectedId = nil
    }

    func select(_ actor: StageActor?) {
        selectedId = actor?.id
    }

    /// Characters that animation commands apply to.
    func targets() -> [StageActor] {
        if applyToAll { return actors }
        return selected.map { [$0] } ?? []
    }

    /// Plays `clip` on the selected character. With `applyToAll` every other character plays its own clip of the
    /// same name, or failing that its first clip of the same category.
    func play(_ clip: Clip, toggleLoop: Bool = false) {
        let sel = selected
        for actor in targets() {
            let own: Clip
            if actor === sel {
                own = clip
            } else if let match = StageState.matching(clip, in: actor.clips) {
                own = match
            } else {
                continue
            }
            if toggleLoop { actor.playToggledLoop(own) } else { actor.play(own) }
        }
    }

    private static func matching(_ clip: Clip, in clips: [Clip]) -> Clip? {
        clips.first { $0.name == clip.name }
            ?? clips.first { $0.category == clip.category && $0.category != .other }
    }

    func changeSpeed(_ value: Float) {
        targets().forEach { $0.changeSpeed(value) }
    }

    func changePaused(_ value: Bool) {
        targets().forEach { $0.changePaused(value) }
    }
}
