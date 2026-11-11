import Foundation

/// Why an import was refused. The UI maps these to messages.
public enum ImportError: Error, Equatable, Sendable {
    case cannotRead
    case notAModel
    case tooLarge
    case zipWithoutModel
    case badManifest
    case storage
}

/// What a picked file is, judged by its first bytes and never by its name.
public enum PackFileKind: Equatable, Sendable {
    case glb
    case zip
    case unknown

    public static let glbMagic: [UInt8] = [0x67, 0x6C, 0x54, 0x46] // "glTF"
    public static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04] // "PK\3\4"

    public static func detect<Bytes: Collection>(_ firstBytes: Bytes) -> PackFileKind where Bytes.Element == UInt8 {
        let head = Array(firstBytes.prefix(4))
        if head == glbMagic { return .glb }
        if head == zipMagic { return .zip }
        return .unknown
    }
}

/// The safety limits and naming rules of the pack importer, shared with `content/PackImporter.kt`.
/// A picked file is untrusted: sizes are capped, zip entries cannot escape the pack folder and only model /
/// manifest / image files are kept.
public enum PackRules {

    public static let charactersDirectory = "characters"
    public static let maxModelBytes: Int64 = 200 * 1024 * 1024
    public static let maxZipEntries = 400
    public static let allowedExtensions: Set<String> = ["glb", "json", "png", "jpg", "jpeg", "webp"]

    /// A GLB shorter than this cannot hold a header and a chunk.
    public static let minGlbBytes: Int64 = 20

    /// Folder-safe id: lowercase ASCII letters, digits, `_` and `-`; never empty, never starts with a dot.
    public static func sanitizeId(_ raw: String) -> String {
        var cleaned = ""
        var pendingGap = false
        for scalar in raw.lowercased().unicodeScalars {
            let ok = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-"
            if ok {
                if pendingGap { cleaned.append("_") }
                pendingGap = false
                cleaned.unicodeScalars.append(scalar)
            } else {
                // A run of other characters becomes one underscore.
                pendingGap = true
            }
        }
        if pendingGap { cleaned.append("_") }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        let limited = String(trimmed.prefix(48))
        return limited.isEmpty ? "model" : limited
    }

    /// File name without its last extension; `model` when nothing is left.
    public static func baseName(_ fileName: String) -> String {
        let base: String
        if let dot = fileName.lastIndex(of: ".") {
            base = String(fileName[..<dot])
        } else {
            base = fileName
        }
        return base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "model" : base
    }

    /// The flat file name a zip entry is stored under, or nil when the entry is not kept.
    /// Only the last path component survives, so an entry can never land outside the staging folder.
    public static func flattenedEntryName(_ entryPath: String) -> String? {
        let unified = entryPath.replacingOccurrences(of: "\\", with: "/")
        let name = unified.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if name.isEmpty || name.hasPrefix(".") || name == ".." { return nil }
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        return allowedExtensions.contains(ext) ? name : nil
    }

    public static func isGlbFileName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".glb")
    }

    /// `wanted`, or `wanted_2`, `wanted_3`... : the first id `isTaken` does not claim.
    public static func uniqueId(_ wanted: String, isTaken: (String) -> Bool) -> String {
        var id = wanted
        var n = 2
        while isTaken(id) {
            id = "\(wanted)_\(n)"
            n += 1
        }
        return id
    }
}
