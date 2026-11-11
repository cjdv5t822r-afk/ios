import Foundation

/// One file of a pack on the server: `<base>/characters/<id>/<name>`.
public struct RemoteFile: Equatable, Sendable {
    public var name: String
    public var bytes: Int64
    public var sha256: String

    public init(name: String, bytes: Int64, sha256: String) {
        self.name = name
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// A pack the server offers, as listed in `catalog.json`. Same schema as `content/RemoteCatalog.kt`.
public struct RemotePack: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Changes whenever any file of the pack changes; compared with the version a downloaded pack was stored with.
    public var version: String
    public var clips: Int?
    public var bytes: Int64
    public var files: [RemoteFile]

    public init(id: String, name: String = "", version: String = "", clips: Int? = nil, bytes: Int64 = 0, files: [RemoteFile] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.clips = clips
        self.bytes = bytes
        self.files = files
    }

    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ClipRules.prettyLabel(id) : name
    }
}

public struct RemoteCatalog: Equatable, Sendable {
    public var format: Int
    public var updated: String?
    public var characters: [RemotePack]

    public init(format: Int = 1, updated: String? = nil, characters: [RemotePack] = []) {
        self.format = format
        self.updated = updated
        self.characters = characters
    }
}

public enum CatalogError: Equatable, CaseIterable, Sendable {
    case offline
    case server
    case badData
}

public enum CatalogState: Equatable, Sendable {
    case idle
    case loading
    case ready([RemotePack])
    case failed(CatalogError)
}

public enum DownloadError: Equatable, CaseIterable, Sendable {
    case offline
    case server
    case checksum
    case noSpace
    case tooLarge
    case storage
}

/// State of one pack download. A pack id that is absent from the map is not being downloaded.
public enum DownloadState: Equatable, Sendable {
    /// Fraction of the whole pack, 0...1. A download waiting for its turn reports 0.
    case running(Float)
    case failed(DownloadError)
}

/// Why a catalog entry is refused.
public enum PackProblem: Equatable, Sendable {
    case badId
    case noFiles
    case tooManyFiles
    case badFileName
    case duplicateFile
    case noManifest
    case badChecksum
    case badSize
    case tooLarge
    case sizeMismatch
}

/// The catalog comes from the network, so nothing in it is trusted: every entry is checked here before any of its
/// text is shown, turned into a URL or into a file path. Port of `CatalogRules` in `content/RemoteCatalog.kt`.
public enum CatalogRules {
    public static let maxCatalogBytes: Int64 = 2 * 1024 * 1024
    public static let maxPacks = 2000
    public static let maxFilesPerPack = 32
    public static let maxFileBytes: Int64 = 200 * 1024 * 1024
    public static let maxPackBytes: Int64 = 250 * 1024 * 1024

    /// The manifest is read into memory whole, so it gets a much smaller cap than a model.
    public static let maxManifestBytes: Int64 = 1 * 1024 * 1024

    static let format = 1
    static let maxNameLength = 80
    static let maxClips = 10_000

    // MARK: names

    /// A pack id doubles as a folder name and a URL segment: `[a-z0-9_-]{1,64}`.
    public static func isSafeId(_ id: String) -> Bool {
        let bytes = id.utf8
        return (1...64).contains(bytes.count) && bytes.allSatisfy { isLowercase($0) || isDigit($0) || $0 == underscore || $0 == hyphen }
    }

    /// A plain file name inside the pack folder: never a path, never hidden (a leading dot is where the app keeps
    /// its own bookkeeping files), never `.` or `..`. `[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}`.
    public static func isSafeFileName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard (1...64).contains(bytes.count), bytes.first != dot else { return false }
        return bytes.allSatisfy(isNameByte)
    }

    /// 64 lowercase hex digits.
    public static func isSha256(_ text: String) -> Bool {
        let bytes = text.utf8
        return bytes.count == 64 && bytes.allSatisfy { isDigit($0) || (0x61...0x66).contains($0) }
    }

    /// Whether `text` can be stored as the version of a downloaded pack: `[A-Za-z0-9._-]{1,64}`.
    public static func isVersion(_ text: String) -> Bool {
        let bytes = text.utf8
        return (1...64).contains(bytes.count) && bytes.allSatisfy(isNameByte)
    }

    private static let underscore = UInt8(ascii: "_")
    private static let hyphen = UInt8(ascii: "-")
    private static let dot = UInt8(ascii: ".")

    private static func isLowercase(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte) }

    private static func isUppercase(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isLowercase(byte) || isUppercase(byte) || isDigit(byte) || byte == underscore || byte == hyphen || byte == dot
    }

    // MARK: checksums

    public static func sha256Hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        hex(Sha256.digest(bytes))
    }

    public static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The version the packing tool gives a pack: the first 12 hex digits of the SHA-256 of `<name>:<sha256>\n`
    /// over the files sorted by name.
    public static func packVersion(_ files: [RemoteFile]) -> String {
        let sorted = files.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        var listing = ""
        for file in sorted {
            listing += "\(file.name):\(file.sha256)\n"
        }
        return String(sha256Hex(listing.utf8).prefix(12))
    }

    // MARK: text

    /// `text` as it may be shown: no control or invisible formatting characters (a right-to-left override would
    /// turn the rest of a row around), trimmed, and short enough for one line of a list.
    ///
    /// The length is counted the way the Android app counts it, in UTF-16 units, and a character that takes two
    /// of them is never cut in half.
    public static func cleanLabel(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isInvisible(scalar) {
            kept.append(scalar)
        }
        let cleaned = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.utf16.count <= maxNameLength { return cleaned }
        var cut = String.UnicodeScalarView()
        var length = 0
        for scalar in cleaned.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if length + width > maxNameLength { break }
            cut.append(scalar)
            length += width
        }
        return String(cut)
    }

    /// Control characters, and the formatting characters of the basic plane (the Android app looks at UTF-16
    /// units one by one, so it never sees a formatting character from beyond that plane; neither does this).
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        let category = scalar.properties.generalCategory
        return category == .control || (category == .format && scalar.value <= 0xFFFF)
    }

    // MARK: validation

    /// Nil when `pack` is safe to show and to download.
    public static func problem(of pack: RemotePack) -> PackProblem? {
        if !isSafeId(pack.id) { return .badId }
        if pack.files.isEmpty { return .noFiles }
        if pack.files.count > maxFilesPerPack { return .tooManyFiles }
        if pack.files.contains(where: { !isSafeFileName($0.name) }) { return .badFileName }
        // Compared without case: two names that differ only by case are one file on some file systems.
        if Set(pack.files.map { $0.name.lowercased() }).count != pack.files.count { return .duplicateFile }
        guard let manifest = pack.files.first(where: { $0.name == CharacterManifest.fileName }) else { return .noManifest }
        if pack.files.contains(where: { !isSha256($0.sha256) }) { return .badChecksum }
        if pack.files.contains(where: { $0.bytes <= 0 }) { return .badSize }
        if pack.files.contains(where: { $0.bytes > maxFileBytes }) || manifest.bytes > maxManifestBytes {
            return .tooLarge
        }
        // Every file is at most maxFileBytes and there are at most maxFilesPerPack of them: no overflow.
        var total: Int64 = 0
        for file in pack.files {
            total += file.bytes
        }
        if total > maxPackBytes { return .tooLarge }
        if pack.bytes != total { return .sizeMismatch }
        return nil
    }

    /// `pack` with its display fields cleaned up, or nil when it has a `problem(of:)`. A missing or odd version is
    /// replaced by the one computed from the files, so an update can always be told from the copy on the phone.
    public static func sanitize(_ pack: RemotePack) -> RemotePack? {
        if problem(of: pack) != nil { return nil }
        var clean = pack
        clean.name = cleanLabel(pack.name)
        clean.version = isVersion(pack.version) ? pack.version : packVersion(pack.files)
        if let clips = pack.clips, !(0...maxClips).contains(clips) {
            clean.clips = nil
        }
        return clean
    }

    /// The usable entries of `packs` in their order: bad ones dropped, the first of two with one id kept.
    public static func validPacks(_ packs: [RemotePack]) -> [RemotePack] {
        var seen = Set<String>()
        var valid: [RemotePack] = []
        for pack in packs.prefix(maxPacks) {
            guard let clean = sanitize(pack), seen.insert(clean.id).inserted else { continue }
            valid.append(clean)
        }
        return valid
    }

    // MARK: catalog.json

    /// Reads a `catalog.json`. Entries are decoded one by one, so a single malformed entry costs only itself.
    /// Nil when the document is not a catalog of this format, or lists packs of which none is usable.
    public static func parse(_ text: String) -> RemoteCatalog? {
        parse(data: Data(text.utf8))
    }

    /// As `parse(_:)`, from the bytes the server sent.
    ///
    /// Stricter than the Android parser about JSON itself (kotlinx in lenient mode also takes unquoted text and a
    /// number where a string is expected): here a value of the wrong kind drops the entry it is in. What both
    /// accept is validated by the same rules.
    public static func parse(data: Data) -> RemoteCatalog? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let fields) = root else {
            return nil
        }
        switch fields["format"] {
        case nil:
            break
        case .integer(let value)?:
            if value != Int64(format) { return nil }
        case .string(let value)?:
            if Int32(value) != Int32(format) { return nil }
        default:
            return nil
        }
        let entries: [JSONValue]
        switch fields["characters"] {
        case nil:
            entries = []
        case .array(let values)?:
            entries = Array(values.prefix(maxPacks))
        default:
            return nil
        }
        let packs = validPacks(entries.compactMap(pack(from:)))
        if !entries.isEmpty && packs.isEmpty { return nil }
        var updated: String?
        if case .string(let value)? = fields["updated"] {
            updated = value
        }
        return RemoteCatalog(format: format, updated: updated, characters: packs)
    }

    /// One entry of `characters`, or nil when it is not shaped like one. `id` and the three fields of every file
    /// are required; the rest falls back to its default when it is left out or `null`.
    private static func pack(from value: JSONValue) -> RemotePack? {
        guard case .object(let fields) = value, case .string(let id)? = fields["id"] else { return nil }
        var pack = RemotePack(id: id)
        switch fields["name"] {
        case nil, .null?: break
        case .string(let name)?: pack.name = name
        default: return nil
        }
        switch fields["version"] {
        case nil, .null?: break
        case .string(let version)?: pack.version = version
        default: return nil
        }
        switch fields["clips"] {
        case nil, .null?: break
        case .integer(let clips)?:
            guard let count = Int32(exactly: clips) else { return nil }
            pack.clips = Int(count)
        default: return nil
        }
        switch fields["bytes"] {
        case nil, .null?: break
        case .integer(let bytes)?: pack.bytes = bytes
        default: return nil
        }
        switch fields["files"] {
        case nil, .null?: break
        case .array(let values)?:
            // More files than a pack may have is a refusal anyway; there is no need to decode them all first.
            for value in values.prefix(maxFilesPerPack + 1) {
                guard case .object(let file) = value,
                      case .string(let name)? = file["name"],
                      case .integer(let bytes)? = file["bytes"],
                      case .string(let sha256)? = file["sha256"]
                else { return nil }
                pack.files.append(RemoteFile(name: name, bytes: bytes, sha256: sha256))
            }
        default: return nil
        }
        return pack
    }
}

/// Progress of a pack download, counted over all of its files.
public enum PackProgress {
    public static func fraction(receivedBytes: Int64, totalBytes: Int64) -> Float {
        if totalBytes <= 0 { return 0 }
        let value = Float(Double(receivedBytes) / Double(totalBytes))
        return min(max(value, 0), 1)
    }

    /// Whole percent of `fraction`; the UI state is only touched when this changes.
    public static func percent(_ fraction: Float) -> Int {
        if fraction.isNaN { return 0 }
        return Int(min(max(fraction, 0), 1) * 100)
    }
}

/// Any JSON value. Decoding the whole document into this first is what lets one malformed entry cost only itself.
private enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    /// Something the decoder has no value for, such as a number beyond a `Double`.
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .other
        }
    }
}

/// SHA-256 in plain Swift, so that this package keeps depending on Foundation alone. It hashes short texts (the
/// file listing behind a pack version); the downloaded files themselves are hashed by CryptoKit in the app.
enum Sha256 {

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    static func digest<Bytes: Sequence>(_ message: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var data = [UInt8](message)
        let bitLength = UInt64(data.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 {
            data.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var w = [UInt32](repeating: 0, count: 64)
        for block in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let at = block + i * 4
                let b0 = UInt32(data[at]) << 24
                let b1 = UInt32(data[at + 1]) << 16
                let b2 = UInt32(data[at + 2]) << 8
                let b3 = UInt32(data[at + 3])
                w[i] = b0 | b1 | b2 | b3
            }
            for i in 16..<64 {
                let x = w[i - 15]
                let y = w[i - 2]
                let s0: UInt32 = rotateRight(x, 7) ^ rotateRight(x, 18) ^ (x >> 3)
                let s1: UInt32 = rotateRight(y, 17) ^ rotateRight(y, 19) ^ (y >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            var f = state[5]
            var g = state[6]
            var h = state[7]
            for i in 0..<64 {
                let s1: UInt32 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice: UInt32 = (e & f) ^ (~e & g)
                let t1: UInt32 = h &+ s1 &+ choice &+ k[i] &+ w[i]
                let s0: UInt32 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority: UInt32 = (a & b) ^ (a & c) ^ (b & c)
                let t2: UInt32 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in state {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }
}
