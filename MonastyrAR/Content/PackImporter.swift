import Foundation
import StageCore
import ZIPFoundation

enum ImportResult {
    case success(CharacterPack)
    case failure(ImportError)
}

/// Copies a user-picked file into the app's own storage as a character pack. Accepts
///  - a single `.glb` (becomes a pack with a default manifest), or
///  - a `.zip` made from a pack folder (`character.json` + `model.glb`, at the top level or in one sub-folder).
/// The picked file is treated as untrusted: sizes are capped, zip entries cannot escape the pack folder and
/// only model / manifest / image files are kept. Same rules and limits as `content/PackImporter.kt`.
///
/// An import never copies a hidden file, so an imported archive cannot pose as a downloaded pack (see
/// `PackStore`), and it only ever takes an id that nothing on the phone holds.
@MainActor
final class PackImporter {

    private let repository: PackRepository

    init(repository: PackRepository) {
        self.repository = repository
    }

    /// - Parameter url: the URL the Files picker returned (security-scoped)
    func importPack(from url: URL) async -> ImportResult {
        let directory = PackRepository.packsDirectory
        let staged = await Task.detached(priority: .userInitiated) {
            PackImporter.stage(url: url, into: directory)
        }.value
        switch staged {
        case .failure(let error):
            return .failure(error)
        case .success(let id):
            let packs = await repository.refresh()
            if let pack = packs.first(where: { $0.id == id }) {
                return .success(pack)
            }
            return .failure(.storage)
        }
    }

    // MARK: file work (off the main thread)

    private struct TooLarge: Error {}

    private nonisolated static func stage(url: URL, into packsDirectory: URL) -> Result<String, ImportError> {
        let fm = FileManager.default
        let staging = packsDirectory.appendingPathComponent(
            PackStoreRules.importPrefix + UUID().uuidString, isDirectory: true
        )
        defer { try? fm.removeItem(at: staging) }

        // A file picked outside the app's container is only readable between these two calls.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return .failure(.storage)
        }

        let displayName = url.lastPathComponent.isEmpty ? "model" : url.lastPathComponent
        do {
            guard let head = try readHead(of: url, count: 4) else { return .failure(.cannotRead) }
            switch PackFileKind.detect(head) {
            case .glb:
                let target = staging.appendingPathComponent(CharacterManifest.defaultModelFile, isDirectory: false)
                try copyLimited(from: url, to: target, limit: PackRules.maxModelBytes)
            case .zip:
                if let refusal = try stageZip(url, into: staging) { return .failure(refusal) }
            case .unknown:
                return .failure(.notAModel)
            }

            // Staging now holds character.json (optional) + the model. Give it its final, unique id.
            let manifestURL = staging.appendingPathComponent(CharacterManifest.fileName, isDirectory: false)
            var manifestText: String?
            if fm.fileExists(atPath: manifestURL.path) {
                manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
            }
            let base = PackRules.baseName(displayName)
            guard var manifest = CharacterManifest.parse(manifestText, fallbackId: base) else { return .failure(.badManifest) }
            guard isGlb(staging.appendingPathComponent(manifest.model, isDirectory: false)) else { return .failure(.zipWithoutModel) }
            if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manifest.name = ClipRules.prettyLabel(base)
            }

            // An import only ever takes an id that nothing on the phone holds, downloaded packs included (see
            // PackStore); the lock keeps a download from claiming the same id in between.
            let wanted = PackRules.sanitizeId(manifest.id)
            let id: String? = try PackStore.locked {
                let free = PackStore.freeId(in: packsDirectory, wanted: wanted)
                manifest.id = free
                try manifest.jsonText().write(to: manifestURL, atomically: true, encoding: .utf8)
                do {
                    try fm.moveItem(at: staging, to: packsDirectory.appendingPathComponent(free, isDirectory: true))
                    return free
                } catch {
                    return nil
                }
            }
            guard let id else { return .failure(.storage) }
            return .success(id)
        } catch is TooLarge {
            return .failure(.tooLarge)
        } catch {
            return .failure(.cannotRead)
        }
    }

    private nonisolated static func readHead(of url: URL, count: Int) throws -> [UInt8]? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: count) else { return nil }
        return [UInt8](data)
    }

    /// Copies at most `limit` bytes; one byte more and the import is refused. Returns the bytes written.
    @discardableResult
    private nonisolated static func copyLimited(from source: URL, to target: URL, limit: Int64) throws -> Int64 {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var written: Int64 = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            written += Int64(chunk.count)
            if written > limit { throw TooLarge() }
            try output.write(contentsOf: chunk)
        }
        return written
    }

    /// Unpacks the files worth keeping into `staging`, flat. Returns why the archive is refused, or nil when it is fine.
    private nonisolated static func stageZip(_ url: URL, into staging: URL) throws -> ImportError? {
        let fm = FileManager.default
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw CocoaError(.fileReadCorruptFile)
        }
        var total: Int64 = 0
        var entries = 0
        for entry in archive {
            entries += 1
            if entries > PackRules.maxZipEntries { throw TooLarge() }
            // Hidden files are never kept: the name of a kept entry cannot start with a dot.
            guard entry.type == .file, let name = PackRules.flattenedEntryName(entry.path) else { continue }
            let target = staging.appendingPathComponent(name, isDirectory: false)
            // The name is a single path component, so this cannot leave the folder; checked all the same.
            guard target.deletingLastPathComponent().standardizedFileURL.path == staging.standardizedFileURL.path else { continue }
            if fm.fileExists(atPath: target.path) { continue } // first one wins when two folders hold the same file name
            // The size in the archive's directory is only a claim, so the bytes are counted as they come out.
            guard fm.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            let remaining = PackRules.maxModelBytes - total
            var written: Int64 = 0
            _ = try archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: false, progress: nil) { chunk in
                written += Int64(chunk.count)
                if written > remaining { throw TooLarge() }
                try output.write(contentsOf: chunk)
            }
            total += written
        }

        let glbs = ((try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
            .filter { PackRules.isGlbFileName($0.lastPathComponent) }
        if glbs.isEmpty { return .zipWithoutModel }
        // A zip without a manifest but with exactly one GLB behaves like importing that GLB.
        let manifestURL = staging.appendingPathComponent(CharacterManifest.fileName, isDirectory: false)
        if !fm.fileExists(atPath: manifestURL.path) {
            guard glbs.count == 1 else { return .badManifest }
            if glbs[0].lastPathComponent != CharacterManifest.defaultModelFile {
                do {
                    try fm.moveItem(at: glbs[0], to: staging.appendingPathComponent(CharacterManifest.defaultModelFile, isDirectory: false))
                } catch {
                    return .storage
                }
            }
        }
        return nil
    }

    private nonisolated static func isGlb(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard Int64(size) >= PackRules.minGlbBytes, let head = try? readHead(of: url, count: 4) else { return false }
        return PackFileKind.detect(head) == .glb
    }
}
