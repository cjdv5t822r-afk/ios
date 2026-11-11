import ARKit
import AVKit
import Combine
import RealityKit
import simd
import StageCore
import UIKit

/// Whether AR can be offered on this device at all. ARKit answers at once, so unlike on Android there is nothing
/// to wait for.
enum ArSupport {
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
}

/// The entities of one character. See `StageActor` for the graph.
@MainActor
private final class ActorNodes {
    let root: Entity
    let pivot: Entity
    let holder: Entity
    var shadow: ModelEntity?
    var model: LoadedModel?
    var loadTask: Task<Void, Never>?

    init() {
        root = Entity()
        pivot = Entity()
        holder = Entity()
        root.addChild(pivot)
        pivot.addChild(holder)
    }
}

/// What a gesture in progress was started with.
private struct GestureTrack {
    var twistAngle: CGFloat = 0
    var pinchActorId: Int?
    var pinchStartScale: Float = 1
    var dragActorId: Int?
    var dragStartFinger = CGPoint.zero
    var dragStartPosition = SIMD3<Float>(0, 0, 0)
    /// AR: from the floor point under the finger to the character, so a grabbed character does not jump.
    var dragOffset = SIMD3<Float>(0, 0, 0)
}

/// Owns the 3D view of one stage, AR or Studio, and keeps it in step with `StageState`.
///
/// The Android app declares its scene in Compose; RealityKit has no such layer for `ARView`, so this class does the
/// same work by hand once per frame: characters that appeared in the state get entities, ones that left lose them,
/// and position, heading, scale, shadow and animation are copied over. Gestures and the AR session live here too.
/// It draws only the 3D view; every control is SwiftUI on top.
///
/// One controller serves one mode for its whole life: switching between AR and Studio builds a new one.
@MainActor
final class StageController: NSObject, ARSessionDelegate, UIGestureRecognizerDelegate {

    let mode: StageMode
    let arView: ARView

    private let state: StageState
    private let capture: CaptureController
    private let onArUnavailable: () -> Void
    private let onShutter: () -> Void
    private var settings: AppSettings

    /// Fixed at the world origin; every entity of the stage hangs under it in plain world coordinates.
    private let stageRoot: AnchorEntity
    private var props: StageProps?
    private var actorNodes: [Int: ActorNodes] = [:]
    private var updateSubscription: (any Cancellable)?
    private var track = GestureTrack()
    private var running = false

    // AR only
    private var planeEntities: [UUID: ModelEntity] = [:]
    private var reticle: ModelEntity?
    private var trackingState: ARCamera.TrackingState = .notAvailable
    private var cameraBusy = false
    private var depthApplied = false
    private var unavailableReported = false

    init(
        mode: StageMode,
        state: StageState,
        capture: CaptureController,
        settings: AppSettings,
        onArUnavailable: @escaping () -> Void,
        onShutter: @escaping () -> Void
    ) {
        self.mode = mode
        self.state = state
        self.capture = capture
        self.settings = settings
        self.onArUnavailable = onArUnavailable
        self.onShutter = onShutter
        // The session is configured by hand in `runSession`, with exactly the options this app wants.
        arView = ARView(frame: .zero, cameraMode: mode == .ar ? .ar : .nonAR, automaticallyConfigureSession: false)
        stageRoot = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        super.init()
    }

    // MARK: life cycle

    func start() {
        guard !running else { return }
        running = true
        arView.scene.addAnchor(stageRoot)
        installGestures()
        installHardwareShutter()
        capture.attach(to: arView)
        UIApplication.shared.isIdleTimerDisabled = true

        switch mode {
        case .studio:
            setUpStudio()
        case .ar:
            arView.session.delegate = self
            depthApplied = settings.depthOcclusion
            runSession()
        }

        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.frame(deltaTime: Float(event.deltaTime))
        }

        Task { [weak self] in
            // Shadows and the reticle appear once their textures exist; the stage works without them until then.
            let props = try? await StageProps.make()
            self?.props = props
        }
    }

    func stop() {
        guard running else { return }
        running = false
        updateSubscription?.cancel()
        updateSubscription = nil
        capture.detach(from: arView)
        for nodes in actorNodes.values { nodes.loadTask?.cancel() }
        actorNodes.removeAll()
        // Nothing of this scene survives it: its characters belonged to this view. Only its own ones: by now the
        // state may already hold characters of the mode that follows.
        for actor in ownActors { state.remove(actor) }
        if mode == .ar {
            arView.session.delegate = nil
            arView.session.pause()
            state.arHint = .starting
        }
        stageRoot.removeFromParent()
        // The idle timer stays off: on a mode switch the next scene has already started (and switched it off) by
        // the time this one stops, and the app is a viewfinder for as long as it is on screen.
    }

    /// Takes the latest settings. Cheap: called on every SwiftUI update.
    func apply(settings newValue: AppSettings) {
        let old = settings
        settings = newValue
        if mode == .studio, old.studioColorArgb != newValue.studioColorArgb {
            applyStudioBackground()
        }
    }

    // MARK: Studio

    private func setUpStudio() {
        applyStudioBackground()
        // Nothing may soften or tint a chroma-key backdrop.
        arView.renderOptions.insert([.disableMotionBlur, .disableDepthOfField, .disableCameraGrain])

        let camera = PerspectiveCamera()
        camera.camera = PerspectiveCameraComponent(
            near: 0.05,
            far: 100,
            fieldOfViewInDegrees: StageMath.StudioCamera.verticalFovDegrees,
            fieldOfViewOrientation: .vertical
        )
        camera.look(at: StageMath.StudioCamera.target, from: StageMath.StudioCamera.eye, relativeTo: nil)
        stageRoot.addChild(camera)

        // A key light from the front left, on top of the view's own image-based light.
        let light = DirectionalLight()
        light.light.intensity = 1200
        light.look(at: SIMD3<Float>(0, 0.9, 0), from: SIMD3<Float>(-1.5, 3.5, 3), relativeTo: nil)
        stageRoot.addChild(light)
    }

    private func applyStudioBackground() {
        let argb = settings.studioColorArgb
        let color = UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: 1
        )
        arView.environment.background = .color(color)
    }

    // MARK: AR session

    private func runSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .automatic
        if depthApplied {
            // Real objects hide the characters: by the reconstructed room on LiDAR devices, by people elsewhere.
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                configuration.sceneReconstruction = .mesh
                arView.environment.sceneUnderstanding.options.insert(.occlusion)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                configuration.frameSemantics.insert(.personSegmentationWithDepth)
            }
        } else {
            arView.environment.sceneUnderstanding.options.remove(.occlusion)
        }
        arView.session.run(configuration)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        trackingState = camera.trackingState
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors { updatePlane(anchor) }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors { updatePlane(anchor) }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            planeEntities.removeValue(forKey: anchor.identifier)?.removeFromParent()
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        cameraBusy = true
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        cameraBusy = false
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        guard let arError = error as? ARError else { return }
        switch arError.code {
        case .unsupportedConfiguration, .cameraUnauthorized:
            // No session will come: the screen falls back to Studio and says why.
            if !unavailableReported {
                unavailableReported = true
                onArUnavailable()
            }
        case .sensorUnavailable, .sensorFailed:
            cameraBusy = true
        default:
            break
        }
    }

    /// Keeps one flat tile per detected horizontal surface, sized and turned like the surface.
    private func updatePlane(_ anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return }
        let entity: ModelEntity
        if let existing = planeEntities[plane.identifier] {
            entity = existing
        } else {
            guard let created = props?.makePlane() else { return }
            entity = created
            planeEntities[plane.identifier] = entity
            stageRoot.addChild(entity)
        }
        let extent = plane.planeExtent
        var local = Transform()
        local.translation = SIMD3(plane.center.x, plane.center.y + StageProps.planeLift, plane.center.z)
        local.rotation = simd_quatf(angle: extent.rotationOnYAxis, axis: SIMD3<Float>(0, 1, 0))
        local.scale = SIMD3(max(extent.width, 0.01), 1, max(extent.height, 0.01))
        entity.transform = Transform(matrix: plane.transform * local.matrix)
    }

    private var hasFloor: Bool {
        arView.session.currentFrame?.anchors.contains { ($0 as? ARPlaneAnchor)?.alignment == .horizontal } ?? false
    }

    private func currentHint() -> ArHint {
        switch trackingState {
        case .normal:
            break
        case .notAvailable:
            return cameraBusy ? .cameraBusy : .starting
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                return .tooFast
            case .insufficientFeatures:
                // ARKit has no "too dark" reason of its own; a dim frame with too little detail is that case.
                let lumens = arView.session.currentFrame?.lightEstimate?.ambientIntensity ?? 1000
                return lumens < 120 ? .tooDark : .lowDetail
            case .initializing, .relocalizing:
                return cameraBusy ? .cameraBusy : .starting
            @unknown default:
                return .starting
            }
        }
        if !hasFloor { return .findSurface }
        if state.armedPack != nil { return .tapToPlace }
        return .none
    }

    /// A place a character can stand on under a point of the view: on a detected horizontal surface that lies below
    /// the phone (so a ceiling does not count). The one rule shared by the reticle, the placing tap and the drag.
    private func floorHit(at point: CGPoint) -> SIMD3<Float>? {
        let cameraY = arView.cameraTransform.translation.y
        for result in arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal) {
            guard let plane = result.anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { continue }
            let position = SIMD3<Float>(result.worldTransform.columns.3.x, result.worldTransform.columns.3.y, result.worldTransform.columns.3.z)
            if position.y < cameraY { return position }
        }
        return nil
    }

    // MARK: per frame

    /// The characters of this scene. Around a mode switch the state can briefly hold characters of the other
    /// mode too (the next scene's starter is added before this one is torn down); those are not this view's.
    private var ownActors: [StageActor] {
        let inAR = mode == .ar
        return state.actors.filter { $0.isInAR == inAR }
    }

    private func frame(deltaTime: Float) {
        guard running else { return }
        syncActors()
        for actor in ownActors {
            guard let nodes = actorNodes[actor.id] else { continue }
            apply(actor, to: nodes)
            actor.updateAnimation(deltaTime: deltaTime)
        }
        if mode == .ar { updateArHelpers() }
    }

    /// Gives every character in the state its entities and takes away those of characters that left.
    private func syncActors() {
        let actors = ownActors
        let alive = Set(actors.map(\.id))
        for (id, nodes) in actorNodes where !alive.contains(id) {
            nodes.loadTask?.cancel()
            nodes.root.removeFromParent()
            actorNodes.removeValue(forKey: id)
        }
        for actor in actors where actorNodes[actor.id] == nil {
            let nodes = ActorNodes()
            actorNodes[actor.id] = nodes
            stageRoot.addChild(nodes.root)
            actor.load = .loading
            let url = actor.pack.modelURL
            nodes.loadTask = Task { [weak self, weak actor, weak nodes] in
                do {
                    let model = try await ModelLoader.load(url)
                    // The character may have been removed, or the scene torn down, while the file was read.
                    guard !Task.isCancelled, let self, let actor, let nodes, self.actorNodes[actor.id] === nodes else { return }
                    nodes.model = model
                    // Sized and placed first, shown after: `apply` runs before the next frame is drawn.
                    actor.attachModel(model)
                    self.apply(actor, to: nodes)
                    nodes.holder.addChild(model.root)
                } catch {
                    if !Task.isCancelled { actor?.load = .failed(error.localizedDescription) }
                }
            }
        }
    }

    private func apply(_ actor: StageActor, to nodes: ActorNodes) {
        nodes.root.position = actor.position
        nodes.pivot.orientation = simd_quatf(angle: actor.modelYawDegrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        nodes.pivot.scale = SIMD3<Float>(repeating: actor.pivotScale)
        nodes.holder.position = SIMD3<Float>(0, -actor.modelMinY, 0)

        let wantsShadow = settings.groundShadow && actor.load == .ready
        if wantsShadow, nodes.shadow == nil, let shadow = props?.makeShadow() {
            nodes.shadow = shadow
            nodes.root.addChild(shadow)
        } else if !wantsShadow, let shadow = nodes.shadow {
            shadow.removeFromParent()
            nodes.shadow = nil
        }
        if let shadow = nodes.shadow {
            // A sibling of the pivot, so pinching resizes it through the footprint only and its lift stays put.
            let footprint = actor.footprintMeters
            shadow.position = SIMD3<Float>(0, StageProps.shadowLift, 0)
            shadow.scale = SIMD3<Float>(footprint, 1, footprint)
        }
    }

    private func updateArHelpers() {
        let hint = currentHint()
        if state.arHint != hint { state.arHint = hint }

        // Switching occlusion restarts the camera pipeline and loses tracking for a moment, so a change made while
        // a recording runs waits until it has ended.
        if !capture.isRecording, settings.depthOcclusion != depthApplied {
            depthApplied = settings.depthOcclusion
            runSession()
        }

        let helpersVisible = !capture.hideHelpers
        let planesVisible = settings.showPlanes && helpersVisible
        for entity in planeEntities.values where entity.isEnabled != planesVisible {
            entity.isEnabled = planesVisible
        }

        // Not before the camera tracks and the view has a size: the reticle would sit at the world origin.
        var reticlePosition: SIMD3<Float>?
        if state.armedPack != nil, state.canAddMore, helpersVisible, case .normal = trackingState, arView.bounds.width > 0 {
            reticlePosition = floorHit(at: CGPoint(x: arView.bounds.midX, y: arView.bounds.midY))
        }
        if let position = reticlePosition {
            if reticle == nil, let created = props?.makeReticle() {
                reticle = created
                stageRoot.addChild(created)
            }
            reticle?.position = SIMD3(position.x, position.y + StageProps.reticleLift, position.z)
            reticle?.isEnabled = true
        } else {
            reticle?.isEnabled = false
        }
    }

    // MARK: gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let twist = UIRotationGestureRecognizer(target: self, action: #selector(handleTwist(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        for recognizer in [tap, pan, twist, pinch] {
            recognizer.delegate = self
            arView.addGestureRecognizer(recognizer)
        }
    }

    /// A twist and a pinch are one two-finger gesture to the creator: both run at once.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let twoFinger: (UIGestureRecognizer) -> Bool = { $0 is UIRotationGestureRecognizer || $0 is UIPinchGestureRecognizer }
        return twoFinger(gestureRecognizer) && twoFinger(otherGestureRecognizer)
    }

    /// The character under a point of the view, nearest first; nil over empty space.
    private func actor(at point: CGPoint) -> StageActor? {
        guard let ray = arView.ray(through: point) else { return nil }
        var best: (actor: StageActor, distance: Float)?
        for actor in ownActors {
            // A character still loading has no size yet; a person-sized box stands in for it.
            let ready = actor.load == .ready && actor.heightMeters > 0
            let height = ready ? actor.heightMeters : 1.7
            let width = ready ? max(actor.modelFootprint * actor.pivotScale, 0.2) : 0.5
            guard let distance = StageMath.rayHitDistance(
                origin: ray.origin, direction: ray.direction, base: actor.position,
                yawDegrees: actor.modelYawDegrees, width: width, height: height
            ) else { continue }
            if best == nil || distance < best!.distance { best = (actor, distance) }
        }
        return best?.actor
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        // Nothing changes while a photo is being taken: the frame about to be copied must be the one that was framed.
        guard recognizer.state == .ended, !capture.isTakingPhoto else { return }
        let point = recognizer.location(in: arView)
        if let hit = actor(at: point) {
            state.select(hit)
            return
        }
        // Empty space: in AR this is where the armed character goes.
        guard mode == .ar, let pack = state.armedPack, state.canAddMore, let position = floorHit(at: point) else { return }
        state.addInAr(pack: pack, hitPosition: position, cameraPosition: arView.cameraTransform.translation)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: arView)
        switch recognizer.state {
        case .began:
            track.dragActorId = nil
            guard !capture.isTakingPhoto, let actor = state.selected else { return }
            if mode == .ar {
                // In AR the character itself has to be grabbed; a drag over empty floor does nothing.
                guard self.actor(at: point)?.id == actor.id else { return }
                track.dragOffset = floorHit(at: point).map { actor.position - $0 } ?? SIMD3<Float>(0, 0, 0)
                track.dragOffset.y = 0
            }
            // Travel is measured from where the finger went down, so a drag that starts anywhere never makes the
            // character jump.
            track.dragActorId = actor.id
            track.dragStartFinger = point
            track.dragStartPosition = actor.position
        case .changed:
            guard !capture.isTakingPhoto, let actor = state.selected, actor.id == track.dragActorId else { return }
            switch mode {
            case .studio:
                actor.position = StageMath.StudioFloor.dragged(
                    startX: track.dragStartPosition.x,
                    startZ: track.dragStartPosition.z,
                    dx: Float(point.x - track.dragStartFinger.x),
                    dy: Float(point.y - track.dragStartFinger.y),
                    viewHeight: Float(arView.bounds.height)
                )
            case .ar:
                // Only onto a detected floor: where there is none under the finger the character stays.
                if let hit = floorHit(at: point) { actor.position = hit + track.dragOffset }
            }
        default:
            track.dragActorId = nil
        }
    }

    @objc private func handleTwist(_ recognizer: UIRotationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            track.twistAngle = recognizer.rotation
        case .changed:
            let delta = recognizer.rotation - track.twistAngle
            track.twistAngle = recognizer.rotation
            guard !capture.isTakingPhoto, let actor = state.selected else { return }
            // The recogniser's angle grows when the fingers turn clockwise on screen. Seen from above the floor
            // that is a negative turn about +Y.
            actor.yawDegrees = StageMath.wrapDegrees(actor.yawDegrees - Float(delta) * 180 / .pi)
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            track.pinchActorId = state.selected?.id
            track.pinchStartScale = state.selected?.userScale ?? 1
        case .changed:
            guard !capture.isTakingPhoto, let actor = state.selected, actor.id == track.pinchActorId else { return }
            // The recogniser's scale is the finger spread relative to where the pinch began.
            actor.changeUserScale(track.pinchStartScale * Float(recognizer.scale))
        default:
            track.pinchActorId = nil
        }
    }

    // MARK: hardware shutter

    /// The volume keys as the record button, as in a camera app: a phone on a tripod is hard to tap without
    /// shaking it. iOS hands these keys only to apps it considers to be capturing with the camera, so this may do
    /// nothing in Studio mode; the on-screen button is always there.
    private func installHardwareShutter() {
        let interaction = AVCaptureEventInteraction { [weak self] event in
            if event.phase == .ended { self?.onShutter() }
        }
        arView.addInteraction(interaction)
    }
}
