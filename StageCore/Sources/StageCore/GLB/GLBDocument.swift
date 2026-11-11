import Foundation

public enum GLBError: Error, Equatable, Sendable {
    /// The data does not start with a GLB header.
    case notGLB
    case unsupportedVersion(UInt32)
    /// The container or one of its chunks is shorter than it says.
    case truncated
    case badJSON
    /// The file has no scene to show.
    case noScene
    /// More nodes or animations than a character can sensibly have; refused rather than trusted.
    case tooComplex
    /// A skin that `GLBSkinNormalizer` cannot bring into the form a skeleton-based renderer needs.
    case unsupportedSkin
}

/// Why a skin cannot be handed to a renderer that builds a skeleton from it (RealityKit's `MeshResource.Skeleton`
/// wants every parent joint before its children, and joints are told apart by name).
public enum SkinProblem: Error, Equatable, Sendable {
    case jointBeforeParent
    case unnamedJoint
    case duplicateJointName
}

/// The part of a binary glTF 2.0 file the stage needs to animate a character itself: the node tree, the skins and
/// the animation clips. Meshes, materials and textures are left to the renderer's own loader; this type only keeps
/// each mesh's bounds.
///
/// The file is treated as untrusted: every index and byte range is checked, and anything that does not check out is
/// skipped (a broken channel) or refused (a broken container), never read past.
public final class GLBDocument: @unchecked Sendable {

    public struct Node: Sendable {
        public let name: String?
        public let parent: Int?
        public let children: [Int]
        public let mesh: Int?
        public let skin: Int?
        /// Rest transform, split up. For a node authored as a matrix these come from decomposing it.
        public let translation: SIMD3<Float>
        public let rotation: SIMD4<Float>
        public let scale: SIMD3<Float>
        /// Rest transform relative to the parent, 16 floats, column-major.
        public let matrix: [Float]
    }

    public struct Skin: Sendable {
        public let name: String?
        /// Node index of every joint, in skin order (the order vertex joint indices refer to).
        public let joints: [Int]
        public let skeleton: Int?
        /// 16 floats per joint; identity where the file has none.
        public let inverseBindMatrices: [Float]
        /// For every joint the index (into `joints`) of its parent joint, or nil when its parent node is not a
        /// joint of this skin. The same rule GLTFKit2 uses to build the RealityKit skeleton.
        public let parentJoint: [Int?]
    }

    public enum Interpolation: Sendable {
        case linear, step, cubicSpline
    }

    /// Key frames of one animated property of one node.
    public struct Channel: Sendable {
        public let times: [Float]
        /// `components` floats per key (three times that for cubic splines: in-tangent, value, out-tangent).
        public let values: [Float]
        public let components: Int
        public let interpolation: Interpolation
    }

    /// Everything one clip does to one node.
    public struct Track: Sendable {
        public let node: Int
        public let translation: Channel?
        public let rotation: Channel?
        public let scale: Channel?
    }

    public struct Animation: Sendable {
        public let name: String?
        /// Time of the last key frame, seconds.
        public let duration: Float
        public let tracks: [Track]
    }

    public struct Bounds: Equatable, Sendable {
        public var min: SIMD3<Float>
        public var max: SIMD3<Float>

        public var size: SIMD3<Float> { max - min }
    }

    public let nodes: [Node]
    /// Root nodes of the scene that is shown (the default scene, else the first one).
    public let sceneRoots: [Int]
    public let skins: [Skin]
    public let animations: [Animation]

    /// Every node once, parents before children.
    public let evaluationOrder: [Int]

    /// Nodes some clip moves; the renderer only needs to update these (and the skins).
    public let animatedNodes: [Int]

    /// Bounds of every primitive of every mesh, in mesh space.
    let meshBounds: [[Bounds]]

    static let maxNodes = 20_000
    static let maxAnimations = 2_000
    static let maxSkins = 1_024
    /// Joints over all skins (a skin may list a node more than once, so the node limit does not bound this).
    static let maxJoints = 65_536
    /// Upper limit for decoded key-frame data over the whole file (floats).
    static let maxAnimationFloats = 48_000_000
    /// Upper limit for vertex data decoded to find bounds the file does not declare (floats, whole file).
    static let maxBoundsFloats = 24_000_000

    // MARK: loading

    public convenience init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw GLBError.truncated
        }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        let container = try GLBContainer(data: data)
        let json: GLTFJSON
        do {
            json = try JSONDecoder().decode(GLTFJSON.self, from: container.json)
        } catch {
            throw GLBError.badJSON
        }
        let jsonNodes = json.nodes ?? []
        let jsonAnimations = json.animations ?? []
        let jsonSkins = json.skins ?? []
        let jointTotal = jsonSkins.reduce(0) { $0 + ($1.joints?.count ?? 0) }
        guard jsonNodes.count <= GLBDocument.maxNodes, jsonAnimations.count <= GLBDocument.maxAnimations,
              jsonSkins.count <= GLBDocument.maxSkins, jointTotal <= GLBDocument.maxJoints
        else { throw GLBError.tooComplex }
        guard let scenes = json.scenes, !scenes.isEmpty else { throw GLBError.noScene }
        let sceneIndex = json.scene.flatMap { scenes.indices.contains($0) ? $0 : nil } ?? 0
        let nodeCount = jsonNodes.count

        // Parents: the first node that lists a child owns it; anything else in the file is ignored.
        var parent = [Int?](repeating: nil, count: nodeCount)
        var children = [[Int]](repeating: [], count: nodeCount)
        for (i, node) in jsonNodes.enumerated() {
            for child in node.children ?? [] where child >= 0 && child < nodeCount && child != i && parent[child] == nil {
                parent[child] = i
                children[i].append(child)
            }
        }

        // Parents-first order. A cycle has no root, so its nodes are cut loose and become roots of their own.
        var order: [Int] = []
        order.reserveCapacity(nodeCount)
        var visited = [Bool](repeating: false, count: nodeCount)
        func visit(from root: Int) {
            var stack = [root]
            visited[root] = true
            while let n = stack.popLast() {
                order.append(n)
                for c in children[n].reversed() where !visited[c] {
                    visited[c] = true
                    stack.append(c)
                }
            }
        }
        for i in 0..<nodeCount where parent[i] == nil { visit(from: i) }
        for i in 0..<nodeCount where !visited[i] {
            if let p = parent[i] { children[p].removeAll { $0 == i } }
            parent[i] = nil
            visit(from: i)
        }

        let reader = AccessorReader(json: json, bin: container.bin)

        nodes = jsonNodes.enumerated().map { i, n -> Node in
            let trs = GLBDocument.restTransform(of: n)
            return Node(
                name: n.name,
                parent: parent[i],
                children: children[i],
                mesh: n.mesh.flatMap { $0 >= 0 && $0 < (json.meshes?.count ?? 0) ? $0 : nil },
                skin: n.skin.flatMap { $0 >= 0 && $0 < (json.skins?.count ?? 0) ? $0 : nil },
                translation: trs.translation,
                rotation: trs.rotation,
                scale: trs.scale,
                matrix: trs.matrix
            )
        }
        sceneRoots = (scenes[sceneIndex].nodes ?? []).filter { $0 >= 0 && $0 < nodeCount }
        evaluationOrder = order

        skins = jsonSkins.map { skin -> Skin in
            let joints = (skin.joints ?? []).filter { $0 >= 0 && $0 < nodeCount }
            var ibm: [Float] = []
            if joints.count == (skin.joints ?? []).count, let accessor = skin.inverseBindMatrices,
               let values = reader.read(accessor, components: 16, limit: 16 * 65_536), values.count >= joints.count * 16 {
                ibm = Array(values.prefix(joints.count * 16))
            } else {
                ibm.reserveCapacity(joints.count * 16)
                for _ in joints { ibm.append(contentsOf: Mat4.identity) }
            }
            var indexOfNode: [Int: Int] = [:]
            for (j, node) in joints.enumerated() where indexOfNode[node] == nil { indexOfNode[node] = j }
            let parentJoint: [Int?] = joints.map { node in parent[node].flatMap { indexOfNode[$0] } }
            return Skin(
                name: skin.name,
                joints: joints,
                skeleton: skin.skeleton.flatMap { $0 >= 0 && $0 < nodeCount ? $0 : nil },
                inverseBindMatrices: ibm,
                parentJoint: parentJoint
            )
        }

        var budget = GLBDocument.maxAnimationFloats
        var touched = Set<Int>()
        animations = jsonAnimations.map { animation in
            GLBDocument.buildAnimation(animation, nodeCount: nodeCount, reader: reader, budget: &budget, touched: &touched)
        }
        animatedNodes = touched.sorted()

        var boundsBudget = GLBDocument.maxBoundsFloats
        meshBounds = (json.meshes ?? []).map { mesh -> [Bounds] in
            (mesh.primitives ?? []).compactMap { primitive -> Bounds? in
                guard let accessor = primitive.attributes?["POSITION"] else { return nil }
                return reader.bounds(ofPositions: accessor, budget: &boundsBudget)
            }
        }
    }

    private static func restTransform(of node: GLTFJSON.Node)
        -> (translation: SIMD3<Float>, rotation: SIMD4<Float>, scale: SIMD3<Float>, matrix: [Float])
    {
        if let m = node.matrix, m.count == 16, m.allSatisfy(\.isFinite) {
            let parts = Mat4.decompose(m)
            return (parts.translation, parts.rotation, parts.scale, m)
        }
        func vector3(_ values: [Float]?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            guard let v = values, v.count == 3, v.allSatisfy(\.isFinite) else { return fallback }
            return SIMD3(v[0], v[1], v[2])
        }
        let t = vector3(node.translation, SIMD3(0, 0, 0))
        let s = vector3(node.scale, SIMD3(1, 1, 1))
        var q = Mat4.identityRotation
        if let r = node.rotation, r.count == 4, r.allSatisfy(\.isFinite) {
            q = Mat4.normalized(SIMD4(r[0], r[1], r[2], r[3]))
        }
        return (t, q, s, Mat4.compose(translation: t, rotation: q, scale: s))
    }

    private static func buildAnimation(
        _ animation: GLTFJSON.Animation,
        nodeCount: Int,
        reader: AccessorReader,
        budget: inout Int,
        touched: inout Set<Int>
    ) -> Animation {
        struct Parts {
            var translation: Channel?
            var rotation: Channel?
            var scale: Channel?
        }
        var perNode: [Int: Parts] = [:]
        var nodeOrder: [Int] = []
        var duration: Float = 0
        let samplers = animation.samplers ?? []
        for channel in animation.channels ?? [] {
            guard let node = channel.target?.node, node >= 0, node < nodeCount,
                  let path = channel.target?.path,
                  let samplerIndex = channel.sampler, samplers.indices.contains(samplerIndex)
            else { continue }
            let components: Int
            switch path {
            case "translation", "scale": components = 3
            case "rotation": components = 4
            default: continue // morph target weights are not played
            }
            let sampler = samplers[samplerIndex]
            let interpolation: Interpolation
            switch sampler.interpolation ?? "LINEAR" {
            case "STEP": interpolation = .step
            case "CUBICSPLINE": interpolation = .cubicSpline
            default: interpolation = .linear
            }
            guard let input = sampler.input, let output = sampler.output,
                  let times = reader.read(input, components: 1, limit: budget)
            else { continue }
            // Decoded data is paid for whether or not the channel is kept, so a file cannot make the parser decode
            // the same huge accessor over and over for free.
            budget -= times.count
            guard !times.isEmpty, times.allSatisfy(\.isFinite),
                  let values = reader.read(output, components: components, limit: budget)
            else { continue }
            budget -= values.count
            let perKey = interpolation == .cubicSpline ? components * 3 : components
            guard values.count >= times.count * perKey else { continue }
            let built = Channel(
                times: times,
                values: values.count == times.count * perKey ? values : Array(values.prefix(times.count * perKey)),
                components: components,
                interpolation: interpolation
            )
            if perNode[node] == nil {
                perNode[node] = Parts()
                nodeOrder.append(node)
            }
            switch path {
            case "translation": perNode[node]?.translation = built
            case "rotation": perNode[node]?.rotation = built
            default: perNode[node]?.scale = built
            }
            duration = max(duration, times[times.count - 1])
            touched.insert(node)
        }
        let tracks = nodeOrder.map { node -> Track in
            let parts = perNode[node] ?? Parts()
            return Track(node: node, translation: parts.translation, rotation: parts.rotation, scale: parts.scale)
        }
        return Animation(name: animation.name, duration: duration > 0 ? duration : 0, tracks: tracks)
    }

    // MARK: clips

    /// The clips as the stage lists them: unnamed ones are called `clip_1`, `clip_2`... like on Android.
    public func rawClips() -> [RawClip] {
        animations.enumerated().map { i, animation in
            let trimmed = animation.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let duration = animation.duration.isFinite && animation.duration > 0 ? animation.duration : 0
            return RawClip(index: i, name: trimmed.isEmpty ? "clip_\(i + 1)" : (animation.name ?? ""), durationSeconds: duration)
        }
    }

    // MARK: skins

    /// The first reason a skinned mesh of this file cannot get a skeleton, or nil when every skin is fine.
    /// `GLBSkinNormalizer` rewrites a file so that this returns nil wherever that is possible.
    public func skinProblem() -> SkinProblem? {
        for node in nodes {
            guard node.mesh != nil, let skinIndex = node.skin else { continue }
            let skin = skins[skinIndex]
            for (joint, parent) in skin.parentJoint.enumerated() {
                if let parent, parent >= joint { return .jointBeforeParent }
            }
            var seen = Set<String>()
            for joint in skin.joints {
                guard let name = nodes[joint].name, !name.isEmpty else { return .unnamedJoint }
                if !seen.insert(name).inserted { return .duplicateJointName }
            }
        }
        return nil
    }

    // MARK: poses

    /// A pose is 16 floats per node: every node's transform relative to its parent.
    public var poseLength: Int { nodes.count * 16 }

    /// The rest pose: every node where the file put it.
    public func restPose() -> [Float] {
        var pose: [Float] = []
        pose.reserveCapacity(poseLength)
        for node in nodes { pose.append(contentsOf: node.matrix) }
        return pose
    }

    /// Writes clip `index` at `time` seconds into `pose`. Only the nodes the clip animates are touched, and for those
    /// the properties without a channel take their rest value: starting from the rest pose makes the result a pure
    /// function of (clip, time). Out-of-range clips and poses of the wrong size are ignored.
    public func apply(animation index: Int, time: Float, to pose: inout [Float]) {
        guard animations.indices.contains(index), pose.count == poseLength else { return }
        let t = time.isFinite ? time : 0
        pose.withUnsafeMutableBufferPointer { buffer in
            for track in animations[index].tracks {
                let node = nodes[track.node]
                var translation = node.translation
                var rotation = node.rotation
                var scale = node.scale
                if let c = track.translation {
                    let v = GLBDocument.sample(c, at: t)
                    translation = SIMD3(v.x, v.y, v.z)
                }
                if let c = track.rotation {
                    rotation = Mat4.normalized(GLBDocument.sample(c, at: t))
                }
                if let c = track.scale {
                    let v = GLBDocument.sample(c, at: t)
                    scale = SIMD3(v.x, v.y, v.z)
                }
                Mat4.compose(translation: translation, rotation: rotation, scale: scale, into: buffer.baseAddress! + track.node * 16)
            }
        }
    }

    /// Every node's transform relative to the scene, from a pose of transforms relative to the parents.
    public func globalMatrices(of pose: [Float]) -> [Float] {
        var globals = [Float](repeating: 0, count: poseLength)
        guard pose.count == poseLength else { return globals }
        pose.withUnsafeBufferPointer { local in
            globals.withUnsafeMutableBufferPointer { global in
                for i in evaluationOrder {
                    let out = global.baseAddress! + i * 16
                    let own = local.baseAddress! + i * 16
                    if let p = nodes[i].parent {
                        Mat4.multiply(UnsafePointer(global.baseAddress! + p * 16), own, into: out)
                    } else {
                        for k in 0..<16 { out[k] = own[k] }
                    }
                }
            }
        }
        return globals
    }

    /// The transforms a skeleton-based renderer wants for `skin`: every joint relative to its parent joint, and the
    /// skeleton's root joints relative to the node that carries the skinned mesh (16 floats per joint, skin order).
    ///
    /// glTF places skinned vertices by the joints' scene transforms and ignores the mesh node's own transform. A
    /// renderer that hangs the skeleton under the mesh entity gets the same picture when the root joints are
    /// expressed in the mesh node's frame, which is what this returns.
    public func jointLocalMatrices(globals: [Float], skin skinIndex: Int, meshNode: Int) -> [Float] {
        guard skins.indices.contains(skinIndex), nodes.indices.contains(meshNode), globals.count == poseLength else { return [] }
        let skin = skins[skinIndex]
        var out: [Float] = []
        out.reserveCapacity(skin.joints.count * 16)
        var inverseCache: [Int: [Float]?] = [:]
        func inverse(ofNode node: Int) -> [Float]? {
            if let cached = inverseCache[node] { return cached }
            let inv = Mat4.invertAffine(globals, at: node * 16)
            inverseCache[node] = inv
            return inv
        }
        for (j, node) in skin.joints.enumerated() {
            let own = Array(globals[(node * 16)..<(node * 16 + 16)])
            let frameNode = skin.parentJoint[j].map { skin.joints[$0] } ?? meshNode
            if let inv = inverse(ofNode: frameNode) {
                out.append(contentsOf: Mat4.multiply(inv, own))
            } else {
                out.append(contentsOf: own)
            }
        }
        return out
    }

    // MARK: bounds

    /// Bounding box of the model standing in its rest pose, in scene space; nil when nothing has a position.
    ///
    /// A skinned mesh is placed by its first joint (rest transform times inverse bind matrix), which is exact for the
    /// usual case of a rest pose that equals the bind pose.
    public func restBounds() -> Bounds? {
        let globals = globalMatrices(of: restPose())
        var result: Bounds?
        var stack = sceneRoots
        var seen = Set<Int>()
        while let i = stack.popLast() {
            if !seen.insert(i).inserted { continue }
            let node = nodes[i]
            stack.append(contentsOf: node.children)
            guard let mesh = node.mesh, meshBounds.indices.contains(mesh) else { continue }
            var placement = Array(globals[(i * 16)..<(i * 16 + 16)])
            if let s = node.skin, let joint = skins[s].joints.first {
                let jointGlobal = Array(globals[(joint * 16)..<(joint * 16 + 16)])
                placement = Mat4.multiply(jointGlobal, Array(skins[s].inverseBindMatrices.prefix(16)))
            }
            for box in meshBounds[mesh] {
                for corner in 0..<8 {
                    let p = SIMD3<Float>(
                        corner & 1 == 0 ? box.min.x : box.max.x,
                        corner & 2 == 0 ? box.min.y : box.max.y,
                        corner & 4 == 0 ? box.min.z : box.max.z
                    )
                    let w = Mat4.transformPoint(placement, p)
                    guard w.x.isFinite, w.y.isFinite, w.z.isFinite else { continue }
                    if var r = result {
                        r.min = SIMD3(Swift.min(r.min.x, w.x), Swift.min(r.min.y, w.y), Swift.min(r.min.z, w.z))
                        r.max = SIMD3(Swift.max(r.max.x, w.x), Swift.max(r.max.y, w.y), Swift.max(r.max.z, w.z))
                        result = r
                    } else {
                        result = Bounds(min: w, max: w)
                    }
                }
            }
        }
        return result
    }

    // MARK: sampling

    /// Value of a channel at `time`: held before the first and after the last key.
    static func sample(_ channel: Channel, at time: Float) -> SIMD4<Float> {
        let times = channel.times
        let n = times.count
        let comps = channel.components
        let cubic = channel.interpolation == .cubicSpline
        let stride = cubic ? comps * 3 : comps
        // Where the value of key `k` starts: the middle of the three entries of a cubic spline key.
        func value(_ k: Int, part: Int = 1) -> SIMD4<Float> {
            let o = k * stride + (cubic ? part * comps : 0)
            return channel.values.withUnsafeBufferPointer { v in
                SIMD4(v[o], v[o + 1], v[o + 2], comps == 4 ? v[o + 3] : 0)
            }
        }
        if n == 1 || time <= times[0] { return value(0) }
        if time >= times[n - 1] { return value(n - 1) }
        // Largest k with times[k] <= time.
        var low = 0
        var high = n - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if times[mid] <= time { low = mid } else { high = mid }
        }
        let k = low
        let span = times[k + 1] - times[k]
        if !(span > 0) { return value(k + 1) }
        let u = (time - times[k]) / span
        switch channel.interpolation {
        case .step:
            return value(k)
        case .linear:
            if comps == 4 { return Mat4.slerp(Mat4.normalized(value(k)), Mat4.normalized(value(k + 1)), u) }
            return value(k) + (value(k + 1) - value(k)) * u
        case .cubicSpline:
            let u2 = u * u
            let u3 = u2 * u
            let p0 = value(k)
            let m0 = value(k, part: 2) * span
            let p1 = value(k + 1)
            let m1 = value(k + 1, part: 0) * span
            let h00 = 2 * u3 - 3 * u2 + 1
            let h10 = u3 - 2 * u2 + u
            let h01 = -2 * u3 + 3 * u2
            let h11 = u3 - u2
            return p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11
        }
    }
}
