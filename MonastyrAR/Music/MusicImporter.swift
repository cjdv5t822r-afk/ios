import AVFoundation
import Foundation
import StageCore

enum MusicImportResult {
    case success(MusicTrack)
    case failure(MusicImportError)
}

/// Copies a user-picked audio file into the app's own storage. The picked file is treated as untrusted: its size
/// is capped, its name is only used after being reduced to a safe one, and it is kept only when Core Audio can
/// open it and finds audio the mixer takes in it. Same rules and limit as `music/MusicImporter.kt`.
///
/// "Is this audio" is asked of `AVAudioFile`, the reader the preview and the recording use too, so a track that
/// gets into the list can also be played and written into a video. That is narrower than on Android: an iPhone
/// has no decoder for Ogg Vorbis, Matroska or WebM, and such files are refused with the "cannot be played"
/// message.
@MainActor
final class MusicImporter {

    private let repository: MusicRepository

    init(repository: MusicRepository) {
        self.repository = repository
    }

    /// - Parameter url: the URL the Files picker returned (security-scoped)
    func importTrack(from url: URL) async -> MusicImportResult {
        let staged = await Task.detached(priority: .userInitiated) {
            MusicImporter.stage(url: url)
        }.value
        switch staged {
        case .failure(let error):
            return .failure(error)
        case .success(let name):
            let id = MusicNames.importId(name)
            let tracks = await repository.refresh()
            if let track = tracks.first(where: { $0.id == id && !$0.isBuiltIn }) {
                return .success(track)
            }
            return .failure(.storage)
        }
    }

    // MARK: file work (off the main thread)

    /// Copies, checks and names the picked file. Returns the file name it got in the music folder.
    private nonisolated static func stage(url: URL) -> Result<String, MusicImportError> {
        let fm = FileManager.default
        guard MusicRepository.prepareImportDirectory() else { return .failure(.storage) }
        let directory = MusicRepository.importDirectory

        // A file picked outside the app's container is only readable between these two calls.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let displayName = url.lastPathComponent
        let knownExtension = MusicNames.fileExtension(displayName)
        // Hidden while it is being checked: the repository does not list dot-files. The extension stays on,
        // because Core Audio takes it as a hint for the formats it cannot tell by their first bytes.
        var stagingName = MusicRules.stagingPrefix + UUID().uuidString
        if let knownExtension { stagingName += "." + knownExtension }
        let staging = directory.appendingPathComponent(stagingName, isDirectory: false)
        defer { try? fm.removeItem(at: staging) }

        if let refusal = copyLimited(from: url, to: staging) { return .failure(refusal) }
        guard let mime = audioMime(of: staging) else { return .failure(.notAudio) }

        let name = MusicNames.uniqueFileName(
            base: MusicNames.safeBaseName(displayName),
            fileExtension: knownExtension ?? MusicNames.extensionForMime(mime)
        ) { candidate in
            fm.fileExists(atPath: directory.appendingPathComponent(candidate, isDirectory: false).path)
        }
        let target = directory.appendingPathComponent(name, isDirectory: false)
        // The name is a single path component, so this cannot leave the folder; checked all the same.
        guard target.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            return .failure(.storage)
        }
        do {
            // Same folder, so the move is a rename: the list never sees half a file.
            try fm.moveItem(at: staging, to: target)
        } catch {
            return .failure(.storage)
        }
        return .success(name)
    }

    /// Copies at most `MusicRules.maxImportBytes` bytes into `target`. Returns nil when the whole file was
    /// copied, otherwise why not: one byte over the limit refuses the file, and a failed write is the phone's
    /// storage, not the file.
    private nonisolated static func copyLimited(from source: URL, to target: URL) -> MusicImportError? {
        guard let input = try? FileHandle(forReadingFrom: source) else { return .cannotRead }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil),
              let output = try? FileHandle(forWritingTo: target)
        else { return .storage }
        defer { try? output.close() }
        var written: Int64 = 0
        while true {
            let chunk: Data?
            do {
                chunk = try input.read(upToCount: 64 * 1024)
            } catch {
                return .cannotRead
            }
            guard let chunk, !chunk.isEmpty else { break }
            written += Int64(chunk.count)
            if written > MusicRules.maxImportBytes { return .tooLarge }
            do {
                try output.write(contentsOf: chunk)
            } catch {
                return .storage
            }
        }
        return written == 0 ? .notAudio : nil
    }

    /// MIME type of the audio Core Audio finds in `file`, or nil when it cannot open the file, finds no frames in
    /// it or decodes it to something the mixer does not take.
    private nonisolated static func audioMime(of file: URL) -> String? {
        guard let audio = try? AVAudioFile(forReading: file), audio.length > 0 else { return nil }
        let decoded = audio.processingFormat
        guard MusicRules.isSupportedFormat(
            sampleRate: Int(decoded.sampleRate.rounded()), channels: Int(decoded.channelCount)
        ) else { return nil }
        switch audio.fileFormat.streamDescription.pointee.mFormatID {
        case kAudioFormatMPEGLayer3: return "audio/mpeg"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatAppleLossless: return "audio/mp4"
        case kAudioFormatFLAC: return "audio/flac"
        case kAudioFormatOpus: return "audio/opus"
        case kAudioFormatLinearPCM: return "audio/raw"
        case kAudioFormatAMR, kAudioFormatAMR_WB: return "audio/3gpp"
        default: return "audio/x-unknown"
        }
    }
}
