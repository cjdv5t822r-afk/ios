import Foundation

/// Why a music import was refused. The UI maps these to messages. Same cases as `music/MusicImporter.kt`.
public enum MusicImportError: Error, Equatable, Sendable {
    case cannotRead
    case notAudio
    case tooLarge
    case storage
}

/// The limits and fixed names of the music library, shared with `music/MusicImporter.kt` and
/// `music/MusicRepository.kt`.
public enum MusicRules {
    /// Folder of the tracks: `music/` in the app bundle (built-in) and in the app's own storage (imported).
    public static let directory = "music"
    public static let manifestFile = "music.json"

    /// A picked file larger than this is refused; one byte over is enough.
    public static let maxImportBytes: Int64 = 60 * 1024 * 1024

    /// `.import-<n>`: a picked file while the importer copies and checks it. Dot-files are never listed.
    public static let stagingPrefix = ".import-"

    /// What a decoder may announce and still be mixed into a recording.
    public static let minSampleRate = 4_000
    public static let maxSampleRate = 384_000
    public static let maxSourceChannels = 16

    /// True for a decoded format the mixer takes.
    public static func isSupportedFormat(sampleRate: Int, channels: Int) -> Bool {
        sampleRate >= minSampleRate && sampleRate <= maxSampleRate && channels >= 1 && channels <= maxSourceChannels
    }
}

/// File-name rules for imported tracks. The picked file's name comes from outside the app and is not trusted.
/// Port of `MusicNames` in `music/MusicTrack.kt`.
public enum MusicNames {
    public static let importPrefix = "import:"
    static let fallbackName = "muzyka"
    static let fallbackExtension = "audio"
    static let maxNameLength = 60

    /// The Android list, plus the Apple containers (`aif`, `aiff`, `aifc`, `caf`) an iPhone hands out.
    static let extensions: Set<String> = [
        "mp3", "m4a", "aac", "ogg", "oga", "opus", "wav", "flac", "amr", "3gp", "mp4", "mka", "mkv", "webm",
        "aif", "aiff", "aifc", "caf",
    ]
    private static let forbidden: Set<Unicode.Scalar> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
    private static let trimmed = CharacterSet(charactersIn: " .")

    public static func importId(_ fileName: String) -> String { importPrefix + fileName }

    /// True for a name that can only mean a file directly inside the music folder.
    public static func isPlainFileName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.hasPrefix(".")
            && !name.contains("/")
            && !name.contains("\\")
    }

    /// What the list shows for a file: `my_song-final.mp3` becomes `My song-final`.
    public static func title(_ fileName: String) -> String {
        let stem = beforeLastDot(fileName).replacingOccurrences(of: "_", with: " ")
        let words = collapseSpaces(stem)
        guard let first = words.first else { return fileName }
        return String(first).capitalized + words.dropFirst()
    }

    /// The picked file's name without folders and extension, reduced to what is safe as a file name: no path
    /// separators, no control characters, never empty, never hidden. Letters of any alphabet are kept, because
    /// the title shown in the list is made from this name.
    public static func safeBaseName(_ displayName: String?) -> String {
        let unified = (displayName ?? "").replacingOccurrences(of: "\\", with: "/")
        let name = unified.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let base = fileExtension(name) != nil ? beforeLastDot(name) : name
        var spaced = String.UnicodeScalarView()
        for scalar in base.unicodeScalars {
            let refused = forbidden.contains(scalar) || scalar.properties.generalCategory == .control
            spaced.append(refused ? " " : scalar)
        }
        var cleaned = collapseSpaces(String(spaced)).trimmingCharacters(in: trimmed)
        if cleaned.utf16.count > maxNameLength {
            // Counted in UTF-16 units like on Android, and cut between characters, never inside one.
            var kept = String.UnicodeScalarView()
            var units = 0
            for scalar in cleaned.unicodeScalars {
                let width = scalar.value > 0xFFFF ? 2 : 1
                if units + width > maxNameLength { break }
                kept.append(scalar)
                units += width
            }
            cleaned = String(kept).trimmingCharacters(in: trimmed)
        }
        return cleaned.isEmpty ? fallbackName : cleaned
    }

    /// The lower-cased extension of `displayName` when it is one of the known audio ones, else nil.
    public static func fileExtension(_ displayName: String?) -> String? {
        guard let name = displayName, let dot = name.lastIndex(of: ".") else { return nil }
        let found = name[name.index(after: dot)...].lowercased()
        return extensions.contains(found) ? found : nil
    }

    /// Extension for a file whose name did not have a usable one, from the MIME type of its audio.
    public static func extensionForMime(_ mime: String) -> String {
        switch mime.lowercased() {
        case "audio/mpeg": return "mp3"
        case "audio/mp4a-latm", "audio/mp4": return "m4a"
        case "audio/vorbis", "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/flac": return "flac"
        case "audio/raw", "audio/wav", "audio/x-wav": return "wav"
        case "audio/3gpp", "audio/amr-wb": return "amr"
        default: return fallbackExtension
        }
    }

    /// `base.ext`, or `base 2.ext`, `base 3.ext`... : the first one `isTaken` does not claim.
    public static func uniqueFileName(base: String, fileExtension: String, isTaken: (String) -> Bool) -> String {
        var name = "\(base).\(fileExtension)"
        var n = 2
        while isTaken(name) {
            name = "\(base) \(n).\(fileExtension)"
            n += 1
        }
        return name
    }

    /// Everything before the last dot; the whole name when it has none.
    private static func beforeLastDot(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    /// Every run of whitespace becomes one space; the ends are trimmed.
    private static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// One usable entry of `music/music.json`.
public struct MusicManifestEntry: Equatable, Sendable {
    /// Stable id of the built-in track; never starts with `import:`.
    public var id: String
    public var title: String
    /// File name next to the manifest.
    public var file: String
    /// Length of one pass, when the manifest gives one.
    public var seconds: Float?

    public init(id: String, title: String, file: String, seconds: Float? = nil) {
        self.id = id
        self.title = title
        self.file = file
        self.seconds = seconds
    }
}

/// `music/music.json`, written by the track generator in `tools`.
public enum MusicManifest {

    private struct Document: Decodable {
        var tracks: [Track]?
    }

    private struct Track: Decodable {
        var id: String?
        var title: String?
        var file: String?
        var seconds: Double?
    }

    /// The built-in tracks the manifest lists, in its order, with the same rules as `MusicRepository.kt`: an
    /// entry needs an id (not in the imported id space) and a plain file name that `fileExists` confirms; the
    /// first of two entries with one id wins; a missing title is made from the file name; a length that is not
    /// positive counts as unknown. A manifest that cannot be read gives no tracks.
    public static func builtInTracks(_ text: String, fileExists: (String) -> Bool) -> [MusicManifestEntry] {
        guard let data = text.data(using: .utf8),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        var seen = Set<String>()
        var result: [MusicManifestEntry] = []
        for track in document.tracks ?? [] {
            let id = (track.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let file = track.file ?? ""
            if id.isEmpty || id.hasPrefix(MusicNames.importPrefix) || !MusicNames.isPlainFileName(file) { continue }
            if !fileExists(file) || seen.contains(id) { continue }
            seen.insert(id)
            let title = track.title ?? ""
            var seconds: Float?
            if let value = track.seconds, value.isFinite, value > 0 { seconds = Float(value) }
            result.append(MusicManifestEntry(
                id: id,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? MusicNames.title(file) : title,
                file: file,
                seconds: seconds
            ))
        }
        return result
    }
}
