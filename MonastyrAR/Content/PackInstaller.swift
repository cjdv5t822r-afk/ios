import CryptoKit
import Foundation
import StageCore

/// A download that ended without a pack; `error` is what the creator is told.
struct DownloadFailure: Error {
    let error: DownloadError

    init(_ error: DownloadError) {
        self.error = error
    }
}

/// A catalog that could not be fetched or read.
struct CatalogFailure: Error {
    let error: CatalogError

    init(_ error: CatalogError) {
        self.error = error
    }
}

/// Fetches the catalog and installs packs from it into the packs folder. Port of `content/PackInstaller.kt`.
///
/// A pack is downloaded into a hidden staging folder next to the packs, every file checked against the size and
/// the SHA-256 the catalog declares, and only a complete, verified folder is renamed to `<id>`. Until that rename
/// the previous copy of the pack is untouched; whatever goes wrong before it leaves no trace. Every call gets a
/// staging folder of its own, so two downloads of one pack never share a file.
///
/// Nothing in here touches the main actor: the chunks are checked and written on the transport's delegate queue.
final class PackInstaller: @unchecked Sendable {

    /// Kept free on top of the pack itself, so a download never fills the phone to the last byte.
    static let spaceMarginBytes: Int64 = 20 * 1024 * 1024
    private static let lowSpaceBytes: Int64 = 1 * 1024 * 1024

    private let packsDirectory: URL
    /// The base address without a trailing slash; nil when the app has none, and every request then fails as a
    /// server error.
    private let base: String?
    private let transport: PackTransport

    init(packsDirectory: URL, base: String?, transport: PackTransport) {
        self.packsDirectory = packsDirectory
        self.base = base
        self.transport = transport
    }

    /// - Throws: `CatalogFailure`, or `CancellationError` when the calling task was cancelled
    func fetchCatalog() async throws -> [RemotePack] {
        guard let base, let url = PackServerRules.catalogURL(base: base) else { throw CatalogFailure(.server) }
        let limit = CatalogRules.maxCatalogBytes
        let buffer = CatalogBuffer()
        do {
            try await transport.fetch(url, head: { announced in
                // Too long, and the server says so up front.
                if announced > limit { throw CatalogFailure(.badData) }
            }, body: { chunk in
                if Int64(buffer.data.count) + Int64(chunk.count) > limit { throw CatalogFailure(.badData) }
                buffer.data.append(chunk)
            })
        } catch let error as TransportError {
            try Task.checkCancellation()
            throw CatalogFailure(PackServerRules.catalogError(for: PackInstaller.fault(of: error)))
        }
        guard let catalog = CatalogRules.parse(data: buffer.data) else { throw CatalogFailure(.badData) }
        return catalog.characters
    }

    /// Downloads `requested` and puts it in place of whatever holds its id.
    ///
    /// - Parameter onProgress: gets the fraction of the whole pack each time its whole percent changes, on the
    ///   downloading thread
    /// - Throws: `DownloadFailure`, or `CancellationError` when the calling task was cancelled before the pack
    ///   was put in place
    func install(_ requested: RemotePack, onProgress: @escaping @Sendable (Float) -> Void) async throws {
        guard let pack = CatalogRules.sanitize(requested) else {
            throw DownloadFailure(CatalogRules.problem(of: requested) == .tooLarge ? .tooLarge : .server)
        }
        guard let base else { throw DownloadFailure(.server) }
        let fm = FileManager.default
        // A cancelled download can be stuck in a connection attempt long after the next download of the same
        // pack has started. With a folder per attempt, all it can remove when it finally unwinds is its own.
        let staging = packsDirectory.appendingPathComponent(
            PackStoreRules.stagingName(packId: pack.id, attempt: UUID().uuidString), isDirectory: true
        )
        defer { try? fm.removeItem(at: staging) }

        do {
            try fm.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
        } catch {
            throw DownloadFailure(.storage)
        }
        if freeBytes() < pack.bytes + PackInstaller.spaceMarginBytes { throw DownloadFailure(.noSpace) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw DownloadFailure(.storage)
        }
        // A downloaded pack can be downloaded again: it stays out of backups. The mark travels with the folder
        // when it is renamed into place.
        PackStore.excludeFromBackup(staging)

        let progress = ProgressCounter(totalBytes: pack.bytes, report: onProgress)
        for file in pack.files {
            guard let url = PackServerRules.fileURL(base: base, packId: pack.id, fileName: file.name) else {
                throw DownloadFailure(.server)
            }
            let target = staging.appendingPathComponent(file.name, isDirectory: false)
            try await fetchFile(url, file: file, to: target, progress: progress)
        }
        try checkManifest(in: staging, pack: pack)
        try writeVersion(pack.version, in: staging)
        try swapIn(staging, id: pack.id)
    }

    // MARK: one file

    private func fetchFile(_ url: URL, file: RemoteFile, to target: URL, progress: ProgressCounter) async throws {
        let sink = FileSink(target: target, file: file, storageError: { [self] in storageError() })
        defer { sink.close() }
        do {
            try await transport.fetch(url, head: { announced in
                guard PackServerRules.announcedLengthMatches(announced: announced, listed: file.bytes) else {
                    throw DownloadFailure(.checksum)
                }
                try sink.open()
            }, body: { chunk in
                try sink.write(chunk)
                progress.add(chunk.count)
            })
        } catch let error as TransportError {
            try Task.checkCancellation()
            throw DownloadFailure(PackServerRules.downloadError(for: PackInstaller.fault(of: error)))
        }
        // A connection closed by a cancellation can look like a clean, short end of the file.
        try Task.checkCancellation()
        try sink.finish()
    }

    private static func fault(of error: TransportError) -> NetworkFault {
        switch error {
        case .server: return .server
        case .offline: return .offline
        }
    }

    // MARK: putting the pack in place

    /// The files are what the catalog promised; now they also have to be a pack the app can open.
    private func checkManifest(in staging: URL, pack: RemotePack) throws {
        let url = staging.appendingPathComponent(CharacterManifest.fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { throw DownloadFailure(storageError()) }
        guard let text = String(data: data, encoding: .utf8),
              let manifest = CharacterManifest.parse(text, fallbackId: pack.id),
              pack.files.contains(where: { $0.name == manifest.model })
        else { throw DownloadFailure(.server) }
    }

    private func writeVersion(_ version: String, in staging: URL) throws {
        let url = staging.appendingPathComponent(PackStoreRules.versionFile, isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(version.utf8)) else {
            throw DownloadFailure(storageError())
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch {
            throw DownloadFailure(storageError())
        }
    }

    private func swapIn(_ staging: URL, id: String) throws {
        let fm = FileManager.default
        let target = packsDirectory.appendingPathComponent(id, isDirectory: true)
        try PackStore.locked {
            // The last point where a cancelled download still leaves the phone as it was. Checked with the lock
            // held: whoever cancels a download and then deletes its pack under the same lock finds either the
            // new copy already in place, and deletes that, or a download that will not put one there any more.
            try Task.checkCancellation()
            if !fm.fileExists(atPath: target.path) {
                guard PackInstaller.move(staging, to: target) else { throw DownloadFailure(storageError()) }
                return
            }
            // An older download of this pack is replaced; an imported pack keeps its files and gets another id.
            let replaced = PackStore.isDownloaded(target)
            let parkedName = replaced
                ? PackStoreRules.backupPrefix + id
                : PackStore.freeId(in: packsDirectory, wanted: id)
            let parked = packsDirectory.appendingPathComponent(parkedName, isDirectory: true)
            if replaced && fm.fileExists(atPath: parked.path) {
                guard (try? fm.removeItem(at: parked)) != nil else { throw DownloadFailure(storageError()) }
            }
            guard PackInstaller.move(target, to: parked) else { throw DownloadFailure(storageError()) }
            guard PackInstaller.move(staging, to: target) else {
                // Should even this fail, a replaced copy waits in its backup folder for the next start.
                _ = PackInstaller.move(parked, to: target)
                throw DownloadFailure(storageError())
            }
            if replaced { try? fm.removeItem(at: parked) }
        }
    }

    /// Renames a folder inside the packs folder; false when it could not. On one volume this is a single rename.
    private static func move(_ from: URL, to: URL) -> Bool {
        do {
            try FileManager.default.moveItem(at: from, to: to)
            return true
        } catch {
            return false
        }
    }

    // MARK: space

    /// Room left on the volume of the packs folder.
    private func freeBytes() -> Int64 {
        let values = try? packsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    private func storageError() -> DownloadError {
        freeBytes() < PackInstaller.lowSpaceBytes ? .noSpace : .storage
    }
}

/// The catalog as it arrives. Filled on the delegate queue, read once the request has ended.
private final class CatalogBuffer: @unchecked Sendable {
    var data = Data()
}

/// Progress of one pack over all of its files. Fed on the delegate queue, one file after the other.
private final class ProgressCounter: @unchecked Sendable {
    private let totalBytes: Int64
    private let report: @Sendable (Float) -> Void
    private var received: Int64 = 0
    private var reportedPercent = 0

    init(totalBytes: Int64, report: @escaping @Sendable (Float) -> Void) {
        self.totalBytes = totalBytes
        self.report = report
    }

    func add(_ count: Int) {
        received += Int64(count)
        let fraction = PackProgress.fraction(receivedBytes: received, totalBytes: totalBytes)
        let percent = PackProgress.percent(fraction)
        if percent != reportedPercent {
            reportedPercent = percent
            report(fraction)
        }
    }
}

/// One file on its way to the staging folder: counted, hashed and written chunk by chunk on the delegate queue.
private final class FileSink: @unchecked Sendable {
    private let target: URL
    private let file: RemoteFile
    private let storageError: () -> DownloadError
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0

    init(target: URL, file: RemoteFile, storageError: @escaping () -> DownloadError) {
        self.target = target
        self.file = file
        self.storageError = storageError
    }

    func open() throws {
        guard FileManager.default.createFile(atPath: target.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: target)
        else { throw DownloadFailure(storageError()) }
        self.handle = handle
    }

    func write(_ chunk: Data) throws {
        received += Int64(chunk.count)
        // Stop at the first byte too many: the declared size is also the most this file may cost.
        if received > file.bytes { throw DownloadFailure(.tooLarge) }
        hasher.update(data: chunk)
        guard let handle else { throw DownloadFailure(storageError()) }
        do {
            try handle.write(contentsOf: chunk)
        } catch {
            throw DownloadFailure(storageError())
        }
    }

    /// Call when the transfer has ended well: the file has to be the one the catalog lists.
    func finish() throws {
        guard let handle else { throw DownloadFailure(.checksum) }
        // The folder is renamed into place next, and a rename does not put the bytes of the files inside it on
        // the disk: without this a power cut could leave an installed pack with a short model.
        do {
            try handle.synchronize()
        } catch {
            throw DownloadFailure(storageError())
        }
        close()
        guard received == file.bytes, CatalogRules.hex(hasher.finalize()) == file.sha256 else {
            throw DownloadFailure(.checksum)
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
