import Foundation

/// Rewrites the skins of a GLB into the form a skeleton-based renderer needs, without changing how the model looks
/// or moves.
///
/// glTF lets a skin list its joints in any order, lets joints go unnamed and lets vertex weights be normalised
/// integers. RealityKit's skeleton wants every parent joint before its children and tells joints apart by name,
/// and the converter the app uses only reads float weights. Files that already comply (the usual exporter output,
/// and the demo character `stage_dummy`) are left exactly as they are: `normalized` returns nil for them.
///
/// What changes in a file that needs it:
///  - `skin.joints` is put in parents-first order, the inverse bind matrices follow, and every `JOINTS_n` vertex
///    attribute of the meshes using that skin is renumbered;
///  - unnamed joints get a name (`joint_<node>`), repeated names within a skin get the node number appended;
///  - integer `WEIGHTS_n` attributes are rewritten as floats.
/// New data is appended to the binary chunk; nothing existing is moved, so every other accessor stays valid.
public enum GLBSkinNormalizer {

    /// Most floats decoded for vertex attributes over the whole file (four per vertex and attribute).
    private static let maxAttributeFloats = 16_000_000

    /// - Returns: the rewritten file, or nil when `data` needs no change
    /// - Throws: `GLBError` for a file that is not a readable GLB, and `.unsupportedSkin` for a skin this cannot fix
    public static func normalized(_ data: Data) throws -> Data? {
        let container = try GLBContainer(data: data)
        let typed: GLTFJSON
        do {
            typed = try JSONDecoder().decode(GLTFJSON.self, from: container.json)
        } catch {
            throw GLBError.badJSON
        }
        let typedNodes = typed.nodes ?? []
        let typedSkins = typed.skins ?? []
        let typedAccessors = typed.accessors ?? []
        if typedSkins.isEmpty { return nil }
        let jointTotal = typedSkins.reduce(0) { $0 + ($1.joints?.count ?? 0) }
        guard typedNodes.count <= GLBDocument.maxNodes, typedSkins.count <= GLBDocument.maxSkins,
              jointTotal <= GLBDocument.maxJoints
        else { throw GLBError.tooComplex }

        // The same JSON once more as plain dictionaries: only what has to change is touched, the rest is written
        // back as it came, extensions and extras included.
        guard var root = (try? JSONSerialization.jsonObject(with: container.json)) as? [String: Any] else {
            throw GLBError.badJSON
        }
        var nodesJSON = root["nodes"] as? [[String: Any]] ?? []
        var skinsJSON = root["skins"] as? [[String: Any]] ?? []
        var meshesJSON = root["meshes"] as? [[String: Any]] ?? []
        var accessorsJSON = root["accessors"] as? [[String: Any]] ?? []
        var viewsJSON = root["bufferViews"] as? [[String: Any]] ?? []
        var buffersJSON = root["buffers"] as? [[String: Any]] ?? []
        guard nodesJSON.count == typedNodes.count, skinsJSON.count == typedSkins.count else { throw GLBError.badJSON }

        let reader = AccessorReader(json: typed, bin: container.bin)
        let nodeCount = typedNodes.count
        let binBase = (container.bin.count + 3) & ~3
        var appended = Data()
        var changed = false
        var attributeBudget = maxAttributeFloats

        func addAccessor(_ bytes: [UInt8], componentType: Int, type: String, count: Int) -> Int {
            let offset = binBase + appended.count
            appended.append(contentsOf: bytes)
            while appended.count % 4 != 0 { appended.append(0) }
            viewsJSON.append(["buffer": 0, "byteOffset": offset, "byteLength": bytes.count])
            accessorsJSON.append([
                "bufferView": viewsJSON.count - 1, "componentType": componentType, "count": count, "type": type,
            ])
            return accessorsJSON.count - 1
        }

        // Parents as `GLBDocument` sees them: the first node that lists a child owns it.
        var parent = [Int?](repeating: nil, count: nodeCount)
        for (i, node) in typedNodes.enumerated() {
            for child in node.children ?? [] where child >= 0 && child < nodeCount && child != i && parent[child] == nil {
                parent[child] = i
            }
        }

        // 1. Joint order and joint names, skin by skin.
        var renumbering: [Int: [Int]] = [:] // skin -> new joint index for every old joint index
        for (skinIndex, skin) in typedSkins.enumerated() {
            let joints = skin.joints ?? []
            guard !joints.isEmpty else { continue }
            // Joints that do not exist cannot be repaired: dropping them would shift every vertex's joint numbers.
            guard joints.allSatisfy({ $0 >= 0 && $0 < nodeCount }) else { throw GLBError.unsupportedSkin }
            // The same joint twice is left alone; `GLBDocument.skinProblem()` reports it.
            guard Set(joints).count == joints.count else { continue }
            let count = joints.count
            var indexOfNode: [Int: Int] = [:]
            for (j, node) in joints.enumerated() { indexOfNode[node] = j }
            let parentJoint: [Int?] = joints.map { node in parent[node].flatMap { indexOfNode[$0] } }

            // A skin that already lists every parent before its children keeps its order, whatever that order is
            // (exporters usually write joints depth-first). The same test as `GLBDocument.skinProblem()`.
            let misordered = parentJoint.enumerated().contains { joint, parentIndex in (parentIndex ?? -1) >= joint }

            // Depth of every joint below its skeleton root, each chain walked once.
            var depth = [Int](repeating: -1, count: count)
            for start in 0..<count where depth[start] < 0 {
                var chain: [Int] = []
                var onChain = Set<Int>()
                var at: Int? = start
                while let a = at, depth[a] < 0, onChain.insert(a).inserted {
                    chain.append(a)
                    at = parentJoint[a]
                }
                // nil: reached a root. A known depth: carry on from it. Still unknown: the chain bit its own tail.
                var d = at.map { depth[$0] >= 0 ? depth[$0] + 1 : count + 1 } ?? 0
                for a in chain.reversed() {
                    depth[a] = min(d, count + 1)
                    d += 1
                }
            }
            // Old joint indices in their new order: shallower first, file order among equals.
            let order = (0..<count).sorted { a, b in depth[a] != depth[b] ? depth[a] < depth[b] : a < b }
            if misordered, order != Array(0..<count) {
                var newIndexOfOld = [Int](repeating: 0, count: count)
                for (new, old) in order.enumerated() { newIndexOfOld[old] = new }
                renumbering[skinIndex] = newIndexOfOld
                skinsJSON[skinIndex]["joints"] = order.map { joints[$0] }
                if let accessor = skin.inverseBindMatrices {
                    guard let matrices = reader.read(accessor, components: 16, limit: 16 * GLBDocument.maxJoints),
                          matrices.count >= count * 16
                    else { throw GLBError.unsupportedSkin }
                    var reordered: [Float] = []
                    reordered.reserveCapacity(count * 16)
                    for old in order { reordered.append(contentsOf: matrices[(old * 16)..<(old * 16 + 16)]) }
                    skinsJSON[skinIndex]["inverseBindMatrices"] = addAccessor(
                        bytes(ofFloats: reordered), componentType: 5126, type: "MAT4", count: count
                    )
                }
                changed = true
            }

            var used = Set<String>()
            for node in joints {
                let current = nodesJSON[node]["name"] as? String ?? ""
                var name = current.isEmpty ? "joint_\(node)" : current
                if used.contains(name) { name = "\(name)_\(node)" }
                while used.contains(name) { name += "_" }
                used.insert(name)
                if name != current {
                    nodesJSON[node]["name"] = name
                    changed = true
                }
            }
        }

        // 2. Vertex attributes of every mesh that hangs on a skin.
        var skinOfMesh: [Int: Int] = [:]
        var renumbered: [String: Int] = [:] // "<accessor>#<skin>" -> new JOINTS accessor
        var floatWeights: [Int: Int] = [:] // WEIGHTS accessor -> its float copy
        for node in typedNodes {
            guard let skinIndex = node.skin, typedSkins.indices.contains(skinIndex),
                  let meshIndex = node.mesh, meshesJSON.indices.contains(meshIndex)
            else { continue }
            let map = renumbering[skinIndex]
            if let earlier = skinOfMesh[meshIndex] {
                // One mesh under two skins is fine unless they would need different joint numbers in it.
                if earlier != skinIndex, map != nil || renumbering[earlier] != nil { throw GLBError.unsupportedSkin }
                continue
            }
            skinOfMesh[meshIndex] = skinIndex
            guard var primitives = meshesJSON[meshIndex]["primitives"] as? [[String: Any]] else { continue }
            for p in primitives.indices {
                guard var attributes = primitives[p]["attributes"] as? [String: Any] else { continue }
                for (key, value) in attributes {
                    guard let accessor = value as? Int, typedAccessors.indices.contains(accessor) else { continue }
                    if key.hasPrefix("JOINTS_"), let map {
                        let cacheKey = "\(accessor)#\(skinIndex)"
                        if let done = renumbered[cacheKey] {
                            attributes[key] = done
                        } else {
                            guard let values = reader.read(accessor, components: 4, limit: attributeBudget) else {
                                throw GLBError.unsupportedSkin
                            }
                            attributeBudget -= values.count
                            var out: [UInt8] = []
                            out.reserveCapacity(values.count * 2)
                            for value in values {
                                let old = value.isFinite && value >= 0 && value < 65_536 ? Int(value) : 0
                                let new = UInt16(clamping: old < map.count ? map[old] : old)
                                out.append(UInt8(new & 0xFF))
                                out.append(UInt8(new >> 8))
                            }
                            let created = addAccessor(out, componentType: 5123, type: "VEC4", count: values.count / 4)
                            renumbered[cacheKey] = created
                            attributes[key] = created
                        }
                        changed = true
                    } else if key.hasPrefix("WEIGHTS_"), typedAccessors[accessor].componentType != 5126 {
                        if let done = floatWeights[accessor] {
                            attributes[key] = done
                        } else {
                            guard let values = reader.read(accessor, components: 4, limit: attributeBudget) else {
                                throw GLBError.unsupportedSkin
                            }
                            attributeBudget -= values.count
                            // Integer weights are meant as fractions of the type's range; files that forget to
                            // say so are read that way all the same.
                            var divisor: Float = 1
                            if typedAccessors[accessor].normalized != true {
                                switch typedAccessors[accessor].componentType ?? 0 {
                                case 5121: divisor = 255
                                case 5123: divisor = 65_535
                                default: divisor = 1
                                }
                            }
                            let floats = divisor == 1 ? values : values.map { $0 / divisor }
                            let created = addAccessor(bytes(ofFloats: floats), componentType: 5126, type: "VEC4", count: values.count / 4)
                            floatWeights[accessor] = created
                            attributes[key] = created
                        }
                        changed = true
                    }
                }
                primitives[p]["attributes"] = attributes
            }
            meshesJSON[meshIndex]["primitives"] = primitives
        }

        if !changed { return nil }

        var bin = Data(container.bin)
        if !appended.isEmpty {
            // The new data goes into the file's own buffer, which must be the GLB's binary chunk.
            guard !buffersJSON.isEmpty, buffersJSON[0]["uri"] == nil else { throw GLBError.unsupportedSkin }
            bin.append(contentsOf: [UInt8](repeating: 0, count: binBase - bin.count))
            bin.append(appended)
            buffersJSON[0]["byteLength"] = bin.count
            root["buffers"] = buffersJSON
            root["bufferViews"] = viewsJSON
            root["accessors"] = accessorsJSON
        }
        root["nodes"] = nodesJSON
        root["skins"] = skinsJSON
        root["meshes"] = meshesJSON

        // Slashes are written as they are: the parser under the model converter copies strings without undoing
        // escapes, so "image\/png" or an escaped data URI would not mean the same to it.
        guard JSONSerialization.isValidJSONObject(root),
              let json = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
        else { throw GLBError.badJSON }
        return GLBContainer.assemble(json: json, bin: bin)
    }

    private static func bytes(ofFloats values: [Float]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(values.count * 4)
        for value in values {
            let bits = value.bitPattern
            out.append(UInt8(bits & 0xFF))
            out.append(UInt8((bits >> 8) & 0xFF))
            out.append(UInt8((bits >> 16) & 0xFF))
            out.append(UInt8((bits >> 24) & 0xFF))
        }
        return out
    }
}
