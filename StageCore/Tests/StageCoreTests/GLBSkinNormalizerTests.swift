import XCTest
@testable import StageCore

final class GLBSkinNormalizerTests: XCTestCase {

    /// The two-joint model of `GLBDocumentTests`, with the things a skeleton-based renderer cannot take switched
    /// on one by one.
    ///
    ///     node 0 "Root" (0, 1, 0) ── node 1 (0, 1, 0)        node 2 "Body": mesh 0, skin 0
    ///
    /// - Parameters:
    ///   - childFirst: the skin lists the child joint (node 1) before its parent (node 0)
    ///   - named: node 1 has a name
    ///   - integerWeights: WEIGHTS_0 is UNSIGNED_BYTE instead of FLOAT
    ///   - flagged: the integer weights carry `normalized: true`, as the specification asks
    private func skinnedGLB(childFirst: Bool, named: Bool = true, integerWeights: Bool = false, flagged: Bool = true) -> Data {
        var bin = BinaryBuilder()
        let rootInverse = translation(0, -1, 0)
        let tipInverse = translation(0, -2, 0)
        let ibm = bin.floats(childFirst ? tipInverse + rootInverse : rootInverse + tipInverse)
        let positions = bin.floats([-0.5, 0, -0.5, 0.5, 2, 0.5])
        // Vertex 0 hangs on the root only, vertex 1 half on the tip and half on the root.
        let root: UInt8 = childFirst ? 1 : 0
        let tip: UInt8 = childFirst ? 0 : 1
        let joints = bin.bytes([root, tip, 0, 0, tip, root, 0, 0])
        let weights = integerWeights
            ? bin.bytes([255, 0, 0, 0, 128, 127, 0, 0])
            : bin.floats([1, 0, 0, 0, 128.0 / 255.0, 127.0 / 255.0, 0, 0])

        func view(_ range: Range<Int>) -> [String: Any] { ["buffer": 0, "byteOffset": range.lowerBound, "byteLength": range.count] }
        var tipNode: [String: Any] = ["translation": [0, 1, 0]]
        if named { tipNode["name"] = "Tip" }
        let rootNode: [String: Any] = ["name": "Root", "translation": [0, 1, 0], "children": [1]]
        let bodyNode: [String: Any] = ["name": "Body", "mesh": 0, "skin": 0]
        var weightAccessor: [String: Any] = ["bufferView": 3, "componentType": integerWeights ? 5121 : 5126, "count": 2, "type": "VEC4"]
        if integerWeights && flagged { weightAccessor["normalized"] = true }
        let accessors: [[String: Any]] = [
            ["bufferView": 0, "componentType": 5126, "count": 2, "type": "MAT4"],
            ["bufferView": 1, "componentType": 5126, "count": 2, "type": "VEC3"],
            ["bufferView": 2, "componentType": 5121, "count": 2, "type": "VEC4"],
            weightAccessor,
        ]
        let attributes: [String: Any] = ["POSITION": 1, "JOINTS_0": 2, "WEIGHTS_0": 3]
        let primitive: [String: Any] = ["attributes": attributes]
        let mesh: [String: Any] = ["primitives": [primitive]]
        let skin: [String: Any] = ["joints": childFirst ? [1, 0] : [0, 1], "inverseBindMatrices": 0]
        let scene: [String: Any] = ["nodes": [0, 2]]
        let buffer: [String: Any] = ["byteLength": bin.data.count]
        var json: [String: Any] = [:]
        json["asset"] = ["version": "2.0", "generator": "test"]
        json["scene"] = 0
        json["scenes"] = [scene]
        json["nodes"] = [rootNode, tipNode, bodyNode]
        json["meshes"] = [mesh]
        json["skins"] = [skin]
        json["accessors"] = accessors
        json["bufferViews"] = [view(ibm), view(positions), view(joints), view(weights)]
        json["buffers"] = [buffer]
        return makeGLB(json: json, bin: bin.data)
    }

    /// The values of a vertex attribute of the first primitive, read the way the app's parser reads accessors.
    private func attribute(_ name: String, in data: Data) throws -> [Float] {
        let container = try GLBContainer(data: data)
        let json = try JSONDecoder().decode(GLTFJSON.self, from: container.json)
        let accessor = try XCTUnwrap(json.meshes?.first?.primitives?.first?.attributes?[name])
        return try XCTUnwrap(AccessorReader(json: json, bin: container.bin).read(accessor, components: 4))
    }

    func testAFileThatIsAlreadyFineIsLeftAlone() throws {
        XCTAssertNil(try GLBSkinNormalizer.normalized(skinnedGLB(childFirst: false)))
        XCTAssertNil(try GLBDocument(data: skinnedGLB(childFirst: false)).skinProblem())
    }

    func testProblemsAreNamed() throws {
        XCTAssertEqual(try GLBDocument(data: skinnedGLB(childFirst: true)).skinProblem(), .jointBeforeParent)
        XCTAssertEqual(try GLBDocument(data: skinnedGLB(childFirst: false, named: false)).skinProblem(), .unnamedJoint)
    }

    func testJointsArePutParentsFirst() throws {
        let original = skinnedGLB(childFirst: true)
        let fixed = try XCTUnwrap(try GLBSkinNormalizer.normalized(original))
        let doc = try GLBDocument(data: fixed)
        XCTAssertNil(doc.skinProblem())
        XCTAssertEqual(doc.skins[0].joints, [0, 1])
        XCTAssertEqual(doc.skins[0].parentJoint, [nil, 0])
        // The inverse bind matrices moved with their joints.
        XCTAssertEqual(doc.skins[0].inverseBindMatrices, translation(0, -1, 0) + translation(0, -2, 0))
        // Every vertex still names the same joints: what was index 1 (the root) is index 0 now, and the other way round.
        XCTAssertEqual(try attribute("JOINTS_0", in: original), [1, 0, 0, 0, 0, 1, 0, 0])
        XCTAssertEqual(try attribute("JOINTS_0", in: fixed), [0, 1, 1, 1, 1, 0, 1, 1])
        XCTAssertEqual(try attribute("WEIGHTS_0", in: fixed), try attribute("WEIGHTS_0", in: original))
        // Nothing else changed: same nodes, same picture.
        let before = try GLBDocument(data: original)
        XCTAssertEqual(doc.nodes.map(\.matrix), before.nodes.map(\.matrix))
        XCTAssertEqual(doc.restBounds(), before.restBounds())
        XCTAssertEqual(doc.sceneRoots, before.sceneRoots)
    }

    func testTheResultNeedsNoSecondPass() throws {
        let fixed = try XCTUnwrap(try GLBSkinNormalizer.normalized(skinnedGLB(childFirst: true, named: false, integerWeights: true)))
        XCTAssertNil(try GLBSkinNormalizer.normalized(fixed))
    }

    func testUnnamedJointsGetNames() throws {
        let fixed = try XCTUnwrap(try GLBSkinNormalizer.normalized(skinnedGLB(childFirst: false, named: false)))
        let doc = try GLBDocument(data: fixed)
        XCTAssertNil(doc.skinProblem())
        XCTAssertEqual(doc.nodes.map(\.name), ["Root", "joint_1", "Body"])
        // Only names changed, so no data was appended and the joints stay as they were.
        XCTAssertEqual(doc.skins[0].joints, [0, 1])
    }

    func testIntegerWeightsBecomeFloats() throws {
        let expected: [Float] = [1, 0, 0, 0, 128.0 / 255.0, 127.0 / 255.0, 0, 0]
        for flagged in [true, false] {
            let fixed = try XCTUnwrap(try GLBSkinNormalizer.normalized(skinnedGLB(childFirst: false, integerWeights: true, flagged: flagged)))
            let container = try GLBContainer(data: fixed)
            let json = try JSONDecoder().decode(GLTFJSON.self, from: container.json)
            let accessor = try XCTUnwrap(json.meshes?.first?.primitives?.first?.attributes?["WEIGHTS_0"])
            XCTAssertEqual(json.accessors?[accessor].componentType, 5126, "flagged: \(flagged)")
            let weights = try attribute("WEIGHTS_0", in: fixed)
            XCTAssertEqual(weights.count, expected.count)
            for (actual, wanted) in zip(weights, expected) {
                XCTAssertEqual(actual, wanted, accuracy: 1e-6, "flagged: \(flagged)")
            }
            // The joint numbers were fine and are untouched.
            XCTAssertEqual(try attribute("JOINTS_0", in: fixed), [0, 1, 0, 0, 1, 0, 0, 0])
        }
    }

    func testEverythingAtOnce() throws {
        let fixed = try XCTUnwrap(try GLBSkinNormalizer.normalized(skinnedGLB(childFirst: true, named: false, integerWeights: true)))
        let doc = try GLBDocument(data: fixed)
        XCTAssertNil(doc.skinProblem())
        XCTAssertEqual(doc.skins[0].joints, [0, 1])
        XCTAssertEqual(doc.nodes[1].name, "joint_1")
        XCTAssertEqual(try attribute("JOINTS_0", in: fixed), [0, 1, 1, 1, 1, 0, 1, 1])
        XCTAssertEqual(try attribute("WEIGHTS_0", in: fixed)[0], 1)
    }

    func testFilesWithoutSkinsAndBrokenFiles() throws {
        let plain: [String: Any] = ["scenes": [["nodes": [0]]], "nodes": [["name": "Only"]]]
        XCTAssertNil(try GLBSkinNormalizer.normalized(makeGLB(json: plain, bin: Data())))
        XCTAssertThrowsError(try GLBSkinNormalizer.normalized(Data("not a model".utf8))) { XCTAssertEqual($0 as? GLBError, .notGLB) }
    }

    func testTheDemoCharacterNeedsNoChange() throws {
        let url = repositoryRoot().appendingPathComponent("content/characters/stage_dummy/model.glb")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("content/ is not next to the package") }
        XCTAssertNil(try GLBSkinNormalizer.normalized(data))
        XCTAssertNil(try GLBDocument(data: data).skinProblem())
    }
}
