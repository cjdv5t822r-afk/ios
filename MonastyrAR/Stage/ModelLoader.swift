import Foundation
import GLTFKit2
import RealityKit
import simd
import StageCore

/// A GLB that is ready to stand on the stage: RealityKit entities for showing it and the parsed document for
/// animating it.
@MainActor
final class LoadedModel {

    /// A skinned mesh and the skin that drives it.
    struct SkinBinding {
        let entity: ModelEntity
        let skin: Int
        let meshNode: Int
    }

    /// Root of the converted scene. Its children are the glTF scene's root nodes, in file order.
    let root: Entity
    let document: GLBDocument

    /// The entity that stands for each glTF node (same index as `document.nodes`); nil for nodes outside the scene.
    let nodeEntities: [Entity?]
    let skinBindings: [SkinBinding]

    /// Rest-pose bounds in model units, or nil for a model without geometry.
    let bounds: GLBDocument.Bounds?

    /// True when a skinned mesh came out of the converter without its skeleton: the model shows, but in its bind
    /// pose, and no clip can move that mesh.
    let hasUnboundSkin: Bool

    init(
        root: Entity, document: GLBDocument, nodeEntities: [Entity?], skinBindings: [SkinBinding],
        bounds: GLBDocument.Bounds?, hasUnboundSkin: Bool
    ) {
        self.root = root
        self.document = document
        self.nodeEntities = nodeEntities
        self.skinBindings = skinBindings
        self.bounds = bounds
        self.hasUnboundSkin = hasUnboundSkin
    }
}

enum ModelLoadError: LocalizedError {
    case noScene
    /// The converted entity tree does not line up with the nodes of the file.
    case structureMismatch
    /// A skin that RealityKit cannot build a skeleton from, even after `GLBSkinNormalizer`.
    case unsupportedSkeleton(SkinProblem)

    var errorDescription: String? {
        switch self {
        case .noScene: return "The model has no scene"
        case .structureMismatch: return "The converted model does not match the file's node tree"
        case .unsupportedSkeleton(let problem): return "The model's skeleton cannot be used on iOS (\(problem))"
        }
    }
}

/// Turns a GLB file into a `LoadedModel`.
///
/// Meshes, materials, textures and skeletons come from GLTFKit2's RealityKit converter. Animations do not: the
/// converter's own animation path resamples clips and binds them by joint name, and its author calls it
/// preliminary. The stage parses nodes, skins and clips itself (`GLBDocument`) and writes joint transforms every
/// frame (`ClipPlayer`), so here the converted entities only have to be matched to the file's nodes.
@MainActor
enum ModelLoader {

    static func load(_ url: URL) async throws -> LoadedModel {
        // Parsing reads the whole file (up to 200 MB): off the main thread.
        let (document, asset) = try await Task.detached(priority: .userInitiated) { () throws -> (GLBDocument, GLTFAsset) in
            let original = try Data(contentsOf: url, options: .mappedIfSafe)
            // RealityKit's skeleton takes joints parents-first and by name, and the converter reads only float
            // weights; glTF promises none of that. A file that needs it is rewritten in memory (nil = it is fine
            // as it is, which is the usual case and that of the demo character).
            let rewritten = try GLBSkinNormalizer.normalized(original)
            let document = try GLBDocument(data: rewritten ?? original)
            // Checked here, before the converter sees the file: it stops the app on a skin it cannot build.
            if let problem = document.skinProblem() { throw ModelLoadError.unsupportedSkeleton(problem) }
            let asset: GLTFAsset
            if let rewritten {
                asset = try GLTFAsset(data: rewritten, options: [:])
            } else {
                asset = try GLTFAsset(url: url, options: [:])
            }
            return (document, asset)
        }.value

        // The same scene `GLBDocument` picked: the default one, else the first.
        guard let scene = asset.defaultScene ?? asset.scenes.first else { throw ModelLoadError.noScene }
        // Without the asset the converter builds no AnimationResources, which this app would not use.
        let root = GLTFRealityKitLoader.convert(scene: scene)

        // GLTFKit2 creates one entity per node and keeps the file's order of scene roots and of children, so the
        // two trees are walked side by side. Names are not used: they may be missing or repeated.
        var nodeEntities = [Entity?](repeating: nil, count: document.nodes.count)
        var pending: [(node: Int, entity: Entity)] = []
        let rootEntities = Array(root.children)
        guard rootEntities.count == document.sceneRoots.count else { throw ModelLoadError.structureMismatch }
        for (node, entity) in zip(document.sceneRoots, rootEntities) { pending.append((node, entity)) }
        while let (node, entity) = pending.popLast() {
            guard nodeEntities[node] == nil else { continue }
            nodeEntities[node] = entity
            let childNodes = document.nodes[node].children
            let childEntities = Array(entity.children)
            guard childEntities.count == childNodes.count else { throw ModelLoadError.structureMismatch }
            for (childNode, childEntity) in zip(childNodes, childEntities) { pending.append((childNode, childEntity)) }
        }

        let bounds = document.restBounds()
        // An animated limb leaves the box of the bind pose; without a margin RealityKit culls the mesh when that
        // box alone is off screen.
        let margin = max(bounds.map { max($0.size.x, max($0.size.y, $0.size.z)) } ?? 1, 0.01)

        var bindings: [LoadedModel.SkinBinding] = []
        var hasUnboundSkin = false
        for (index, node) in document.nodes.enumerated() {
            guard let entity = nodeEntities[index] as? ModelEntity, var model = entity.model else { continue }
            model.boundsMargin = margin
            entity.model = model
            guard let skin = node.skin else { continue }
            // A mesh whose skeleton did not make it through the converter stays in its bind pose. Writing joint
            // transforms to it would be wrong, so it gets no binding; the stage says that the model cannot move.
            if entity.jointNames.count == document.skins[skin].joints.count {
                bindings.append(LoadedModel.SkinBinding(entity: entity, skin: skin, meshNode: index))
            } else {
                hasUnboundSkin = true
            }
        }

        return LoadedModel(
            root: root, document: document, nodeEntities: nodeEntities, skinBindings: bindings,
            bounds: bounds, hasUnboundSkin: hasUnboundSkin
        )
    }
}

extension simd_float4x4 {
    /// The column-major matrix stored in the 16 floats at `m`.
    init(columnMajor m: UnsafePointer<Float>) {
        self.init(columns: (
            SIMD4(m[0], m[1], m[2], m[3]),
            SIMD4(m[4], m[5], m[6], m[7]),
            SIMD4(m[8], m[9], m[10], m[11]),
            SIMD4(m[12], m[13], m[14], m[15])
        ))
    }
}
