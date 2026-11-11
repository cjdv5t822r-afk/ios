import Foundation

/// The two chunks of a binary glTF file.
struct GLBContainer {
    let json: Data
    /// The embedded binary buffer; empty when the file has none.
    let bin: Data

    private static let magic: UInt32 = 0x4654_6C67 // "glTF"
    private static let jsonChunk: UInt32 = 0x4E4F_534A // "JSON"
    private static let binChunk: UInt32 = 0x004E_4942 // "BIN\0"

    init(data: Data) throws {
        guard data.count >= 12, GLBContainer.u32(data, 0) == GLBContainer.magic else { throw GLBError.notGLB }
        let version = GLBContainer.u32(data, 4)
        guard version == 2 else { throw GLBError.unsupportedVersion(version) }
        let declared = Int(GLBContainer.u32(data, 8))
        guard declared >= 20, declared <= data.count else { throw GLBError.truncated }

        var json: Data?
        var bin: Data?
        var offset = 12
        while offset + 8 <= declared {
            let length = Int(GLBContainer.u32(data, offset))
            let type = GLBContainer.u32(data, offset + 4)
            let start = offset + 8
            guard length <= declared - start else { throw GLBError.truncated }
            let range = (data.startIndex + start)..<(data.startIndex + start + length)
            if type == GLBContainer.jsonChunk, json == nil {
                // The JSON of a character is a few hundred kilobytes; decoding costs many times its size in memory.
                guard length <= GLBContainer.maxJSONBytes else { throw GLBError.tooComplex }
                json = data.subdata(in: range)
            } else if type == GLBContainer.binChunk, bin == nil {
                // A slice, not a copy: the buffer is most of the file.
                bin = data[range]
            }
            // Chunks are padded to four bytes.
            offset = start + ((length + 3) & ~3)
        }
        guard let json else { throw GLBError.truncated }
        self.json = json
        self.bin = bin ?? Data()
    }

    static let maxJSONBytes = 32 * 1024 * 1024

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        let b0 = UInt32(data[i])
        let b1 = UInt32(data[i + 1])
        let b2 = UInt32(data[i + 2])
        let b3 = UInt32(data[i + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /// Builds a GLB file from its two chunks (the reverse of `init(data:)`).
    static func assemble(json: Data, bin: Data) -> Data {
        func littleEndian(_ value: Int) -> [UInt8] {
            let v = UInt32(truncatingIfNeeded: value)
            return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        let jsonPadding = (4 - json.count % 4) % 4
        let binPadding = (4 - bin.count % 4) % 4
        let total = 12 + 8 + json.count + jsonPadding + (bin.isEmpty ? 0 : 8 + bin.count + binPadding)
        var out = Data(capacity: total)
        out.append(contentsOf: littleEndian(Int(magic)))
        out.append(contentsOf: littleEndian(2))
        out.append(contentsOf: littleEndian(total))
        out.append(contentsOf: littleEndian(json.count + jsonPadding))
        out.append(contentsOf: littleEndian(Int(jsonChunk)))
        out.append(json)
        out.append(contentsOf: [UInt8](repeating: 0x20, count: jsonPadding))
        if !bin.isEmpty {
            out.append(contentsOf: littleEndian(bin.count + binPadding))
            out.append(contentsOf: littleEndian(Int(binChunk)))
            out.append(bin)
            out.append(contentsOf: [UInt8](repeating: 0, count: binPadding))
        }
        return out
    }
}

/// The glTF JSON, reduced to the fields the stage reads. Everything is optional: files in the wild leave things out.
struct GLTFJSON: Decodable {
    struct Scene: Decodable {
        var nodes: [Int]?
    }

    struct Node: Decodable {
        var name: String?
        var children: [Int]?
        var mesh: Int?
        var skin: Int?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
        var matrix: [Float]?
    }

    struct Skin: Decodable {
        var name: String?
        var joints: [Int]?
        var skeleton: Int?
        var inverseBindMatrices: Int?
    }

    struct Animation: Decodable {
        struct Target: Decodable {
            var node: Int?
            var path: String?
        }

        struct Channel: Decodable {
            var sampler: Int?
            var target: Target?
        }

        struct Sampler: Decodable {
            var input: Int?
            var output: Int?
            var interpolation: String?
        }

        var name: String?
        var channels: [Channel]?
        var samplers: [Sampler]?
    }

    struct Accessor: Decodable {
        struct Sparse: Decodable {
            var count: Int?
        }

        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int?
        var normalized: Bool?
        var count: Int?
        var type: String?
        var min: [Float]?
        var max: [Float]?
        var sparse: Sparse?
    }

    struct BufferView: Decodable {
        var buffer: Int?
        var byteOffset: Int?
        var byteLength: Int?
        var byteStride: Int?
    }

    struct Buffer: Decodable {
        var uri: String?
        var byteLength: Int?
    }

    struct Mesh: Decodable {
        struct Primitive: Decodable {
            var attributes: [String: Int]?
        }

        var primitives: [Primitive]?
    }

    var scene: Int?
    var scenes: [Scene]?
    var nodes: [Node]?
    var skins: [Skin]?
    var animations: [Animation]?
    var accessors: [Accessor]?
    var bufferViews: [BufferView]?
    var buffers: [Buffer]?
    var meshes: [Mesh]?
}

/// Reads accessors as plain floats, checking every range against the buffer it points into.
struct AccessorReader {
    let json: GLTFJSON
    private let buffers: [Data?]

    /// Largest accessor (in floats) that is decoded for bounds when a file gives no `min` / `max`.
    private static let maxBoundsFloats = 12_000_000

    init(json: GLTFJSON, bin: Data) {
        self.json = json
        buffers = (json.buffers ?? []).enumerated().map { index, buffer -> Data? in
            if let uri = buffer.uri {
                // Only embedded data: a GLB pack is a single file.
                guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ","),
                      uri[..<comma].hasSuffix(";base64"), uri.utf8.count <= 64 * 1024 * 1024
                else { return nil }
                return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            }
            return index == 0 ? bin : nil
        }
    }

    private static func componentCount(_ type: String) -> Int? {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        case "MAT4": return 16
        default: return nil
        }
    }

    private static func componentSize(_ componentType: Int) -> Int? {
        switch componentType {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return nil
        }
    }

    /// The accessor as floats (`components` per element), or nil when it is missing, sparse, of another shape or
    /// reaches outside its buffer. Normalised integers are converted the way the glTF specification says.
    func read(_ index: Int, components expected: Int, limit: Int = Int.max) -> [Float]? {
        guard let accessors = json.accessors, accessors.indices.contains(index) else { return nil }
        let accessor = accessors[index]
        guard accessor.sparse == nil,
              let type = accessor.type, AccessorReader.componentCount(type) == expected,
              let componentType = accessor.componentType,
              let componentSize = AccessorReader.componentSize(componentType),
              let count = accessor.count, count >= 0,
              let viewIndex = accessor.bufferView,
              let views = json.bufferViews, views.indices.contains(viewIndex)
        else { return nil }
        if count == 0 { return [] }
        guard count <= limit / expected else { return nil }
        let view = views[viewIndex]
        guard let bufferIndex = view.buffer, buffers.indices.contains(bufferIndex),
              let buffer = buffers[bufferIndex], let viewLength = view.byteLength, viewLength >= 0
        else { return nil }
        let viewOffset = view.byteOffset ?? 0
        let accessorOffset = accessor.byteOffset ?? 0
        let elementSize = componentSize * expected
        let stride = view.byteStride ?? elementSize
        guard viewOffset >= 0, accessorOffset >= 0, stride >= elementSize, stride <= 4096,
              viewOffset <= buffer.count, viewLength <= buffer.count - viewOffset
        else { return nil }
        // Last byte the accessor touches, relative to the start of the view.
        let (span, overflow) = (count - 1).multipliedReportingOverflow(by: stride)
        guard !overflow, span <= viewLength, accessorOffset <= viewLength - span,
              elementSize <= viewLength - span - accessorOffset
        else { return nil }

        let normalized = accessor.normalized ?? false
        let base = viewOffset + accessorOffset
        var out = [Float](repeating: 0, count: count * expected)
        buffer.withUnsafeBytes { raw in
            for element in 0..<count {
                let elementBase = base + element * stride
                for c in 0..<expected {
                    let at = elementBase + c * componentSize
                    let value: Float
                    switch componentType {
                    case 5126:
                        value = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                    case 5120:
                        let v = Float(raw.loadUnaligned(fromByteOffset: at, as: Int8.self))
                        value = normalized ? max(v / 127, -1) : v
                    case 5121:
                        let v = Float(raw.loadUnaligned(fromByteOffset: at, as: UInt8.self))
                        value = normalized ? v / 255 : v
                    case 5122:
                        let v = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: Int16.self)))
                        value = normalized ? max(v / 32767, -1) : v
                    case 5123:
                        let v = Float(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)))
                        value = normalized ? v / 65535 : v
                    default:
                        value = Float(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                    }
                    out[element * expected + c] = value
                }
            }
        }
        return out
    }

    /// Bounds of a POSITION accessor: its declared `min` / `max`, else worked out from the data.
    /// `budget` is how many floats may still be decoded for this over the whole file; what is decoded is taken off it.
    func bounds(ofPositions index: Int, budget: inout Int) -> GLBDocument.Bounds? {
        guard let accessors = json.accessors, accessors.indices.contains(index) else { return nil }
        let accessor = accessors[index]
        if let lo = accessor.min, let hi = accessor.max, lo.count >= 3, hi.count >= 3,
           lo.prefix(3).allSatisfy(\.isFinite), hi.prefix(3).allSatisfy(\.isFinite) {
            return GLBDocument.Bounds(min: SIMD3(lo[0], lo[1], lo[2]), max: SIMD3(hi[0], hi[1], hi[2]))
        }
        guard let values = read(index, components: 3, limit: min(budget, AccessorReader.maxBoundsFloats)) else { return nil }
        budget -= values.count
        guard values.count >= 3 else { return nil }
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        var i = 0
        while i + 2 < values.count {
            let p = SIMD3(values[i], values[i + 1], values[i + 2])
            if p.x.isFinite && p.y.isFinite && p.z.isFinite {
                lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
                hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
            }
            i += 3
        }
        return lo.x.isFinite && hi.x.isFinite ? GLBDocument.Bounds(min: lo, max: hi) : nil
    }
}
