import AVFoundation
import Foundation
import Observation
import StageCore

/// Lists the backing tracks: the ones shipped in the app bundle (`music/music.json` + the files it names, the
/// shared `content/music` folder of the repository) and the audio files the user imported
/// (`Library/Application Support/music/`). Port of `music/MusicRepository.kt`.
///
/// Where the imported files live, and why: Application Support is the app's own storage, out of sight of the
/// Files app, so nothing gets in there without passing the importer's checks. The folder is excluded from
/// iCloud / computer backups: a track can be 60 MB and is a copy of a file the creator already has, so it can be
/// imported again, while a backup would carry every copy around for good.
@MainActor
@Observable
final class MusicRepository {

    /// Built-in tracks first (in manifest order), then imported ones by title. Empty until the first `refresh`.
    private(set) var tracks: [MusicTrack] = []

    /// See `clearLeftovers`.
    @ObservationIgnored private var leftoverSweep: Task<Void, Never>?

    /// Folder that holds the imported audio files.
    nonisolated static var importDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(MusicRules.directory, isDirectory: true)
    }

    /// Folder with the tracks that ship inside the app, or nil when the bundle has none.
    nonisolated static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(MusicRules.directory, isDirectory: true)
    }

    /// Number of the newest scan that was started; see `refresh`.
    @ObservationIgnored private var lastScan = 0

    @discardableResult
    func refresh() async -> [MusicTrack] {
        // Scans run side by side (launch, an import, a delete) and may finish out of order. Only the one that
        // started last is published: an older listing never replaces a newer one.
        lastScan += 1
        let scan = lastScan
        let found = await Task.detached(priority: .userInitiated) { MusicRepository.scan() }.value
        if scan == lastScan { tracks = found }
        return found
    }

    /// Removes an imported track from disk. Built-in tracks cannot be deleted.
    func delete(_ track: MusicTrack) async -> Bool {
        guard !track.isBuiltIn else { return false }
        let file = track.url
        let deleted = await Task.detached(priority: .userInitiated) { () -> Bool in
            let parent = file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            let root = MusicRepository.importDirectory.standardizedFileURL.resolvingSymlinksInPath()
            guard parent.path == root.path else { return false }
            do {
                try FileManager.default.removeItem(at: file)
                return true
            } catch {
                return false
            }
        }.value
        await refresh()
        return deleted
    }

    /// Removes what an import left half-copied when its process was killed. The folder is swept once per process
    /// and every caller waits for that one sweep, so an import of this process only starts after it and is never
    /// taken for a leftover.
    func clearLeftovers() async {
        let sweep: Task<Void, Never>
        if let running = leftoverSweep {
            sweep = running
        } else {
            sweep = Task.detached(priority: .utility) {
                let fm = FileManager.default
                let entries = (try? fm.contentsOfDirectory(
                    at: MusicRepository.importDirectory, includingPropertiesForKeys: nil
                )) ?? []
                for entry in entries where entry.lastPathComponent.hasPrefix(MusicRules.stagingPrefix) {
                    try? fm.removeItem(at: entry)
                }
            }
            leftoverSweep = sweep
        }
        await sweep.value
    }

    /// The track with this id in the current list, or nil.
    func find(_ id: String?) -> MusicTrack? {
        guard let id else { return nil }
        return tracks.first { $0.id == id }
    }

    // MARK: file work (off the main thread)

    /// Creates the folder for imported tracks and keeps it out of backups. False when it cannot be created.
    nonisolated static func prepareImportDirectory() -> Bool {
        var directory = importDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return true
    }

    /// Length of one pass through an audio file in seconds, from the file itself; nil when Core Audio cannot
    /// open it or cannot tell.
    nonisolated static func seconds(of url: URL) -> Float? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Float(Double(file.length) / rate)
    }

    nonisolated static func scan() -> [MusicTrack] {
        let polish = Locale(identifier: "pl_PL")
        let imported = loadImported().sorted { a, b in
            a.title.compare(b.title, options: [.caseInsensitive], range: nil, locale: polish) == .orderedAscending
        }
        return loadBuiltIn() + imported
    }

    private nonisolated static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private nonisolated static func loadBuiltIn() -> [MusicTrack] {
        guard let root = bundledDirectory,
              let text = try? String(contentsOf: root.appendingPathComponent(MusicRules.manifestFile, isDirectory: false), encoding: .utf8)
        else { return [] }
        let entries = MusicManifest.builtInTracks(text) { file in
            isFile(root.appendingPathComponent(file, isDirectory: false))
        }
        return entries.map { entry in
            let url = root.appendingPathComponent(entry.file, isDirectory: false)
            return MusicTrack(
                id: entry.id,
                title: entry.title,
                url: url,
                seconds: entry.seconds ?? measured(url, key: "bundle:\(entry.file)"),
                isBuiltIn: true
            )
        }
    }

    private nonisolated static func loadImported() -> [MusicTrack] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: importDirectory, includingPropertiesForKeys: keys, options: []
        )) ?? []
        return entries.compactMap { url in
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, !name.hasPrefix(".") else { return nil }
            let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return MusicTrack(
                id: MusicNames.importId(name),
                title: MusicNames.title(name),
                url: url,
                seconds: measured(url, key: "\(name)|\(values?.fileSize ?? 0)|\(stamp)"),
                isBuiltIn: false
            )
        }
    }

    /// Lengths already measured, so a refresh after an import does not open every file again.
    private nonisolated static func measured(_ url: URL, key: String) -> Float? {
        if let known = MeasuredLengths.shared.value(for: key) { return known }
        guard let length = MusicRepository.seconds(of: url) else { return nil }
        MeasuredLengths.shared.set(length, for: key)
        return length
    }
}

/// Track lengths by file identity (name, size, modification time). Read and written from background tasks.
private final class MeasuredLengths: @unchecked Sendable {
    static let shared = MeasuredLengths()

    private let lock = NSLock()
    private var values: [String: Float] = [:]

    func value(for key: String) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: Float, for key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }
}
