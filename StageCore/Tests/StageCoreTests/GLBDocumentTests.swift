import XCTest
@testable import StageCore

final class GLBDocumentTests: XCTestCase {

    // MARK: a hand-built file

    /// Two joints stacked one metre apart, a skinned mesh, and clips that use every interpolation mode.
    ///
    ///     node 0 "Root" (0, 1, 0) ── node 1 "Tip" (0, 1, 0)
    ///     node 2 "Body": mesh 0, skin 0 (joints 0, 1)
    private func sampleGLB(breakRotationAccessor: Bool = false) -> Data {
        var bin = BinaryBuilder()
        let ibm = bin.floats(translation(0, -1, 0) + translation(0, -2, 0))
        let positions = bin.floats([-0.5, 0, -0.5, 0.5, 2, 0.5])
        let times2 = bin.floats([0, 1])
        let s = Float(0.5).squareRoot()
        let rotations = bin.floats([0, 0, 0, 1, 0, 0, s, s])
        let times3 = bin.floats([0, 0.5, 1])
        let translations = bin.floats([0, 1, 0, 0, 2, 0, 0, 3, 0])
        // Cubic spline keys: in-tangent, value, out-tangent. Flat tangents from scale 1 to scale 3.
        let scales = bin.floats([0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 3, 3, 3, 0, 0, 0])
        let shortRotations = bin.shorts([0, 0, 0, 32767, 0, 0, 23170, 23170])

        func view(_ range: Range<Int>) -> [String: Any] { ["buffer": 0, "byteOffset": range.lowerBound, "byteLength": range.count] }
        func accessor(_ view: Int, _ type: String, _ count: Int, componentType: Int = 5126, normalized: Bool = false) -> [String: Any] {
            var a: [String: Any] = ["bufferView": view, "componentType": componentType, "count": count, "type": type]
            if normalized { a["normalized"] = true }
            return a
        }
        let nodes: [[String: Any]] = [
            ["name": "Root", "translation": [0, 1, 0], "children": [1]],
            ["name": "Tip", "translation": [0, 1, 0]],
            ["name": "Body", "mesh": 0, "skin": 0],
        ]
        func channel(_ sampler: Int, _ node: Int, _ path: String) -> [String: Any] {
            let target: [String: Any] = ["node": node, "path": path]
            return ["sampler": sampler, "target": target]
        }
        func sampler(_ input: Int, _ output: Int, _ interpolation: String? = nil) -> [String: Any] {
            var s: [String: Any] = ["input": input, "output": output]
            if let interpolation { s["interpolation"] = interpolation }
            return s
        }
        let bend: [String: Any] = [
            "name": "Bend",
            "channels": [
                channel(0, 1, "rotation"), channel(1, 0, "translation"), channel(2, 1, "scale"),
                channel(0, 1, "weights"), channel(0, 99, "rotation"),
            ],
            "samplers": [sampler(2, 3, "LINEAR"), sampler(4, 5, "STEP"), sampler(2, 6, "CUBICSPLINE")],
        ]
        let unnamed: [String: Any] = ["channels": [[String: Any]](), "samplers": [[String: Any]]()]
        let packed: [String: Any] = [
            "name": "Packed",
            "channels": [channel(0, 1, "rotation")],
            "samplers": [sampler(2, 7)],
        ]
        let accessors: [[String: Any]] = [
            accessor(0, "MAT4", 2),
            accessor(1, "VEC3", 2),
            accessor(2, "SCALAR", 2),
            accessor(3, "VEC4", breakRotationAccessor ? 2_000_000 : 2),
            accessor(4, "SCALAR", 3),
            accessor(5, "VEC3", 3),
            accessor(6, "VEC3", 6),
            accessor(7, "VEC4", 2, componentType: 5122, normalized: true),
        ]
        let views: [[String: Any]] = [
            view(ibm), view(positions), view(times2), view(rotations), view(times3), view(translations),
            view(scales), view(shortRotations),
        ]
        let primitive: [String: Any] = ["attributes": ["POSITION": 1]]
        let mesh: [String: Any] = ["primitives": [primitive]]
        let skin: [String: Any] = ["joints": [0, 1], "skeleton": 0, "inverseBindMatrices": 0]
        let scene: [String: Any] = ["nodes": [0, 2]]
        let buffer: [String: Any] = ["byteLength": bin.data.count]
        var json: [String: Any] = [:]
        json["asset"] = ["version": "2.0"]
        json["scene"] = 0
        json["scenes"] = [scene]
        json["nodes"] = nodes
        json["meshes"] = [mesh]
        json["skins"] = [skin]
        json["animations"] = [bend, unnamed, packed]
        json["accessors"] = accessors
        json["bufferViews"] = views
        json["buffers"] = [buffer]
        return makeGLB(json: json, bin: bin.data)
    }

    func testStructure() throws {
        let doc = try GLBDocument(data: sampleGLB())
        XCTAssertEqual(doc.nodes.count, 3)
        XCTAssertEqual(doc.sceneRoots, [0, 2])
        XCTAssertEqual(doc.nodes[1].parent, 0)
        XCTAssertNil(doc.nodes[0].parent)
        XCTAssertEqual(doc.nodes[0].children, [1])
        XCTAssertEqual(doc.nodes[2].mesh, 0)
        XCTAssertEqual(doc.nodes[2].skin, 0)
        XCTAssertEqual(doc.skins.count, 1)
        XCTAssertEqual(doc.skins[0].joints, [0, 1])
        XCTAssertEqual(doc.skins[0].parentJoint, [nil, 0])
        XCTAssertEqual(doc.skins[0].inverseBindMatrices, translation(0, -1, 0) + translation(0, -2, 0))
        XCTAssertEqual(doc.animatedNodes, [0, 1])
        // Parents come before their children.
        let position = Dictionary(uniqueKeysWithValues: doc.evaluationOrder.enumerated().map { ($1, $0) })
        XCTAssertEqual(doc.evaluationOrder.sorted(), [0, 1, 2])
        XCTAssertLessThan(try XCTUnwrap(position[0]), try XCTUnwrap(position[1]))
    }

    func testClipList() throws {
        let doc = try GLBDocument(data: sampleGLB())
        XCTAssertEqual(doc.rawClips(), [
            RawClip(index: 0, name: "Bend", durationSeconds: 1),
            RawClip(index: 1, name: "clip_2", durationSeconds: 0),
            RawClip(index: 2, name: "Packed", durationSeconds: 1),
        ])
        // The weights channel and the channel aimed at a node that does not exist are dropped.
        XCTAssertEqual(doc.animations[0].tracks.map(\.node), [1, 0])
    }

    func testSamplingEveryInterpolationMode() throws {
        let doc = try GLBDocument(data: sampleGLB())
        var pose = doc.restPose()
        doc.apply(animation: 0, time: 0.5, to: &pose)
        // LINEAR rotation: halfway to 90 degrees about Z. CUBICSPLINE scale with flat tangents: halfway from 1 to 3.
        assertMatrix(Array(pose[16..<32]), trsZ(45, scale: 2, ty: 1), accuracy: 1e-5)
        // STEP translation: exactly on the second key.
        assertMatrix(Array(pose[0..<16]), translation(0, 2, 0), accuracy: 1e-6)
        // The node no clip touches keeps its rest transform.
        XCTAssertEqual(Array(pose[32..<48]), Mat4.identity)

        doc.apply(animation: 0, time: 0.49, to: &pose)
        assertMatrix(Array(pose[0..<16]), translation(0, 1, 0), accuracy: 1e-6)

        // Before the first and after the last key the ends are held.
        doc.apply(animation: 0, time: -3, to: &pose)
        assertMatrix(Array(pose[16..<32]), translation(0, 1, 0), accuracy: 1e-6)
        doc.apply(animation: 0, time: 30, to: &pose)
        assertMatrix(Array(pose[16..<32]), trsZ(90, scale: 3, ty: 1), accuracy: 1e-5)
        assertMatrix(Array(pose[0..<16]), translation(0, 3, 0), accuracy: 1e-6)
    }

    func testNormalisedIntegerRotations() throws {
        let doc = try GLBDocument(data: sampleGLB())
        var pose = doc.restPose()
        doc.apply(animation: 2, time: 1, to: &pose)
        assertMatrix(Array(pose[16..<32]), trsZ(90, scale: 1, ty: 1), accuracy: 1e-3)
    }

    func testAClipOnlyChangesItsOwnNodes() throws {
        let doc = try GLBDocument(data: sampleGLB())
        var pose = doc.restPose()
        doc.apply(animation: 2, time: 1, to: &pose)
        XCTAssertEqual(Array(pose[0..<16]), translation(0, 1, 0))
        // Out-of-range clips and poses of the wrong size are left alone.
        let before = pose
        doc.apply(animation: 9, time: 0, to: &pose)
        XCTAssertEqual(pose, before)
        var short = [Float](repeating: 7, count: 5)
        doc.apply(animation: 0, time: 0, to: &short)
        XCTAssertEqual(short, [7, 7, 7, 7, 7])
    }

    func testGlobalsAndJointTransforms() throws {
        let doc = try GLBDocument(data: sampleGLB())
        let globals = doc.globalMatrices(of: doc.restPose())
        assertMatrix(Array(globals[0..<16]), translation(0, 1, 0), accuracy: 1e-6)
        assertMatrix(Array(globals[16..<32]), translation(0, 2, 0), accuracy: 1e-6)
        // Root joint relative to the mesh node, child joint relative to its parent joint.
        let joints = doc.jointLocalMatrices(globals: globals, skin: 0, meshNode: 2)
        XCTAssertEqual(joints.count, 32)
        assertMatrix(Array(joints[0..<16]), translation(0, 1, 0), accuracy: 1e-6)
        assertMatrix(Array(joints[16..<32]), translation(0, 1, 0), accuracy: 1e-6)
        XCTAssertEqual(doc.jointLocalMatrices(globals: globals, skin: 5, meshNode: 2), [])
    }

    func testRestBounds() throws {
        let doc = try GLBDocument(data: sampleGLB())
        // No min / max in the file: the box comes from the vertex data, placed by the first joint.
        let bounds = try XCTUnwrap(doc.restBounds())
        XCTAssertEqual(bounds.min, SIMD3(-0.5, 0, -0.5))
        XCTAssertEqual(bounds.max, SIMD3(0.5, 2, 0.5))
        XCTAssertEqual(bounds.size.y, 2)
    }

    // MARK: files that lie

    func testRefusesWhatIsNotAGLB() {
        XCTAssertThrowsError(try GLBDocument(data: Data())) { XCTAssertEqual($0 as? GLBError, .notGLB) }
        XCTAssertThrowsError(try GLBDocument(data: Data("PK\u{3}\u{4}rest of a zip file".utf8))) { XCTAssertEqual($0 as? GLBError, .notGLB) }
        var wrongVersion = sampleGLB()
        wrongVersion[4] = 1
        XCTAssertThrowsError(try GLBDocument(data: wrongVersion)) { XCTAssertEqual($0 as? GLBError, .unsupportedVersion(1)) }
        let full = sampleGLB()
        XCTAssertThrowsError(try GLBDocument(data: full.prefix(full.count - 40))) { XCTAssertEqual($0 as? GLBError, .truncated) }
        XCTAssertThrowsError(try GLBDocument(data: makeGLB(jsonText: "{ not json", bin: Data()))) { XCTAssertEqual($0 as? GLBError, .badJSON) }
        XCTAssertThrowsError(try GLBDocument(data: makeGLB(json: ["asset": ["version": "2.0"]], bin: Data()))) {
            XCTAssertEqual($0 as? GLBError, .noScene)
        }
    }

    func testAnAccessorThatReachesOutsideItsBufferIsSkipped() throws {
        let doc = try GLBDocument(data: sampleGLB(breakRotationAccessor: true))
        // The rotation channel of "Bend" is gone; the other two still play.
        let track = try XCTUnwrap(doc.animations[0].tracks.first { $0.node == 1 })
        XCTAssertNil(track.rotation)
        XCTAssertNotNil(track.scale)
        XCTAssertEqual(doc.animations[0].duration, 1)
    }

    func testWorksOnASliceOfALargerBuffer() throws {
        // A Data slice does not start at index 0; offsets must be taken from its start.
        let padded = Data([1, 2, 3, 4, 5, 6, 7]) + sampleGLB()
        let doc = try GLBDocument(data: padded.dropFirst(7))
        XCTAssertEqual(doc.rawClips().count, 3)
        XCTAssertNotNil(doc.restBounds())
    }

    func testCyclesInTheNodeTreeDoNotHang() throws {
        let json: [String: Any] = [
            "scenes": [["nodes": [0]]],
            "nodes": [["children": [1]], ["children": [0, 1, 7, -1]]],
        ]
        let doc = try GLBDocument(data: makeGLB(json: json, bin: Data()))
        XCTAssertEqual(doc.evaluationOrder.sorted(), [0, 1])
        XCTAssertEqual(doc.globalMatrices(of: doc.restPose()).count, 32)
        XCTAssertNil(doc.restBounds())
    }

    // MARK: the shipped demo character

    private func demoDocument() throws -> GLBDocument {
        let url = repositoryRoot().appendingPathComponent("content/characters/stage_dummy/model.glb")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("content/ is not next to the package") }
        return try GLBDocument(contentsOf: url)
    }

    func testDemoCharacterStructure() throws {
        let doc = try demoDocument()
        XCTAssertEqual(doc.nodes.count, 19)
        XCTAssertEqual(doc.sceneRoots, [0, 18])
        XCTAssertEqual(doc.skins.count, 1)
        XCTAssertEqual(doc.skins[0].joints, Array(0...17))
        XCTAssertNil(doc.skins[0].parentJoint[0])
        XCTAssertEqual(doc.skins[0].parentJoint[1], 0)
        XCTAssertEqual(doc.nodes[18].skin, 0)
        XCTAssertEqual(doc.nodes[1].name, "Hips")
    }

    func testDemoCharacterClips() throws {
        let doc = try demoDocument()
        let clips = doc.rawClips()
        XCTAssertEqual(clips.map(\.name), ["Idle", "Walk", "Run", "Attack_Slash", "Attack_Spin", "Dance", "Wave", "Jump", "Cheer"])
        let expected: [Float] = [3, 1, 0.66, 1.1, 1.3, 4, 2.2, 1.2, 2]
        for (clip, duration) in zip(clips, expected) {
            XCTAssertEqual(clip.durationSeconds, duration, accuracy: 1e-3, clip.name)
        }
        // Every clip drives all 18 joints.
        XCTAssertTrue(doc.animations.allSatisfy { $0.tracks.count == 18 })
    }

    func testDemoCharacterStandsOnTheGround() throws {
        let doc = try demoDocument()
        let bounds = try XCTUnwrap(doc.restBounds())
        XCTAssertEqual(bounds.size.y, 1.83, accuracy: 1e-3)
        XCTAssertEqual(bounds.min.y, 0, accuracy: 1e-4)
        XCTAssertEqual(bounds.size.x, 0.59, accuracy: 1e-3)
        XCTAssertEqual(bounds.size.z, 0.585, accuracy: 1e-3)
    }

    func testDemoCharacterPosesAreFiniteAndRestIsUntouched() throws {
        let doc = try demoDocument()
        let rest = doc.restPose()
        for (index, clip) in doc.rawClips().enumerated() {
            for step in 0...8 {
                var pose = rest
                doc.apply(animation: index, time: clip.durationSeconds * Float(step) / 8, to: &pose)
                XCTAssertTrue(pose.allSatisfy(\.isFinite), "\(clip.name) step \(step)")
                let joints = doc.jointLocalMatrices(globals: doc.globalMatrices(of: pose), skin: 0, meshNode: 18)
                XCTAssertEqual(joints.count, 18 * 16)
                XCTAssertTrue(joints.allSatisfy(\.isFinite), "\(clip.name) step \(step)")
            }
        }
        // In the rest pose every child joint sits where its node does.
        let joints = doc.jointLocalMatrices(globals: doc.globalMatrices(of: rest), skin: 0, meshNode: 18)
        for j in 1..<18 {
            assertMatrix(Array(joints[(j * 16)..<(j * 16 + 16)]), doc.nodes[j].matrix, accuracy: 1e-5)
        }
    }

    func testDemoManifestAndModelAgree() throws {
        let doc = try demoDocument()
        let url = repositoryRoot().appendingPathComponent("content/characters/stage_dummy/character.json")
        let manifest = try XCTUnwrap(CharacterManifest.parse(try String(contentsOf: url, encoding: .utf8), fallbackId: "stage_dummy"))
        let clips = ClipRules.buildClips(manifest: manifest, raw: doc.rawClips())
        XCTAssertEqual(clips.count, 9)
        XCTAssertEqual(clips.map(\.label), ["Stanie", "Chód", "Bieg", "Cios", "Młynek", "Taniec", "Machanie", "Skok", "Wiwat"])
        XCTAssertEqual(ClipRules.defaultClip(manifest: manifest, clips: clips)?.name, "Idle")
        XCTAssertEqual(clips.filter(\.loop).map(\.name), ["Idle", "Walk", "Run", "Dance", "Cheer"])
        let height = try XCTUnwrap(doc.restBounds()).size.y
        XCTAssertEqual(StageMath.baseScale(manifest: manifest, modelHeight: height), 1)
    }
}

// MARK: - helpers

func translation(_ x: Float, _ y: Float, _ z: Float) -> [Float] {
    [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]
}

/// Rotation of `degrees` about +Z with a uniform scale, lifted by `ty`.
func trsZ(_ degrees: Float, scale: Float, ty: Float) -> [Float] {
    let a = Double(degrees) * .pi / 180
    let c = Float(cos(a)) * scale
    let s = Float(sin(a)) * scale
    return [c, s, 0, 0, -s, c, 0, 0, 0, 0, scale, 0, 0, ty, 0, 1]
}

struct BinaryBuilder {
    var data = Data()

    /// Appends little-endian floats, padded to four bytes; returns where they are.
    mutating func floats(_ values: [Float]) -> Range<Int> {
        let start = data.count
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return start..<data.count
    }

    /// Appends single bytes, padded to four bytes; returns where they are.
    mutating func bytes(_ values: [UInt8]) -> Range<Int> {
        let start = data.count
        data.append(contentsOf: values)
        let end = data.count
        while data.count % 4 != 0 { data.append(0) }
        return start..<end
    }

    mutating func shorts(_ values: [Int16]) -> Range<Int> {
        let start = data.count
        for v in values { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let end = data.count
        while data.count % 4 != 0 { data.append(0) }
        return start..<end
    }
}

func makeGLB(json: [String: Any], bin: Data) -> Data {
    let text = String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
    return makeGLB(jsonText: text, bin: bin)
}

func makeGLB(jsonText: String, bin: Data) -> Data {
    func u32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
    var json = Data(jsonText.utf8)
    while json.count % 4 != 0 { json.append(0x20) }
    var body = Data()
    body.append(u32(json.count))
    body.append(u32(0x4E4F_534A))
    body.append(json)
    if !bin.isEmpty {
        var padded = bin
        while padded.count % 4 != 0 { padded.append(0) }
        body.append(u32(padded.count))
        body.append(u32(0x004E_4942))
        body.append(padded)
    }
    var out = Data()
    out.append(u32(0x4654_6C67))
    out.append(u32(2))
    out.append(u32(12 + body.count))
    out.append(body)
    return out
}
