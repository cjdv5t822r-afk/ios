import Foundation
import StageCore

/// The folder that holds every pack on the phone, one sub-folder per pack id, shared by the importer and the
/// library. Port of `content/PackStore.kt`; the naming rules live in `PackStoreRules` (StageCore).
///
/// Who owns a folder is told by one file:
///  - a folder with `.remote-version` was downloaded and belongs to the library, which may replace it with a
///    newer download of the same id;
///  - a folder without it was imported from a file and is never replaced by anyone. The importer only takes ids
///    that are free on disk (`freeId`); when the library needs an id that an imported pack holds, it first moves
///    that pack to the next free id.
/// The importer never copies hidden files, so an imported archive cannot pose as a downloaded pack.
///
/// Everything here is file work: call it off the main thread.
enum PackStore {

    /// Held while a folder is given its final name, so two installs cannot claim one id, and while the folder is
    /// listed, so a listing never catches a pack between the two renames that replace it.
    private static let lock = NSRecursiveLock()

    /// Counts the listings, under the lock: of two listings the one with the higher number is the newer.
    private static var listings = 0

    /// The packs of the folder, and which listing this was.
    struct Listing: Sendable {
        let packs: [CharacterPack]
        let serial: Int
    }

    static func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The packs in `directory` by name. Hidden folders (staging and backups) are not packs. `onSkipped` gets
    /// the folder name of every pack left out for a broken manifest.
    static func list(_ directory: URL, onSkipped: (String) -> Void = { _ in }) -> Listing {
        locked {
            listings += 1
            var packs: [CharacterPack] = []
            for packDirectory in subdirectories(of: directory) {
                let name = packDirectory.lastPathComponent
                guard var manifest = CharacterManifest.parse(manifestText(in: packDirectory), fallbackId: name) else {
                    onSkipped(name)
                    continue
                }
                // The folder name is the identity of a pack, whatever the manifest inside says.
                manifest.id = name
                guard hasModel(manifest, in: packDirectory) else { continue }
                packs.append(CharacterPack(
                    manifest: manifest, directory: packDirectory, remoteVersion: remoteVersion(of: packDirectory)
                ))
            }
            packs.sort { first, second in
                let order = NameOrder.compare(first.name, second.name)
                if order == .orderedSame { return first.id < second.id }
                return order == .orderedAscending
            }
            return Listing(packs: packs, serial: listings)
        }
    }

    /// Removes `pack` from `directory`. False when its folder is gone or has changed hands since the pack was
    /// listed: a download that needs the id of an imported pack moves that pack aside and takes the folder.
    static func delete(_ pack: CharacterPack, from directory: URL) -> Bool {
        locked {
            let parent = pack.directory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            guard parent.path == root.path, isDownloaded(pack.directory) == pack.isDownloaded else { return false }
            do {
                try FileManager.default.removeItem(at: pack.directory)
                return true
            } catch {
                return false
            }
        }
    }

    static func isDownloaded(_ packDirectory: URL) -> Bool {
        isFile(packDirectory.appendingPathComponent(PackStoreRules.versionFile, isDirectory: false))
    }

    /// The catalog version `packDirectory` was downloaded as; nil for an imported pack.
    static func remoteVersion(of packDirectory: URL) -> String? {
        let file = packDirectory.appendingPathComponent(PackStoreRules.versionFile, isDirectory: false)
        guard isFile(file) else { return nil }
        return PackStoreRules.storedVersion(try? String(contentsOf: file, encoding: .utf8))
    }

    /// `wanted` when nothing of that name exists in `directory`, otherwise `<wanted>_2`, `<wanted>_3`, ...
    static func freeId(in directory: URL, wanted: String) -> String {
        PackRules.uniqueId(wanted) { candidate in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
    }

    /// Cleans up after a process that died mid-download or mid-import: the staging folders of both go, and a
    /// pack that was caught between "old copy moved away" and "new copy moved in" gets its old copy back. To be
    /// called once, before this process starts a download or an import of its own.
    static func recover(_ directory: URL) {
        locked {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) else {
                return
            }
            for entry in entries {
                let action = PackStoreRules.leftover(named: entry.lastPathComponent) { name in
                    fm.fileExists(atPath: directory.appendingPathComponent(name).path)
                }
                switch action {
                case .keep:
                    // A downloaded pack can be downloaded again, so it has no business in a backup. The mark was
                    // set when the pack arrived; it is set again here in case something has reset it since.
                    if isDownloaded(entry) { excludeFromBackup(entry) }
                case .remove:
                    try? fm.removeItem(at: entry)
                case .restore(let id):
                    // A backup that cannot be moved back now is kept for the next start rather than lost.
                    try? fm.moveItem(at: entry, to: directory.appendingPathComponent(id, isDirectory: true))
                }
            }
        }
    }

    /// Keeps `url` (a folder and what is in it) out of iCloud and computer backups.
    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    // MARK: helpers

    private static func subdirectories(of directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }
        return entries.filter { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory && !url.lastPathComponent.hasPrefix(".")
        }
    }

    private static func manifestText(in directory: URL) -> String? {
        let url = directory.appendingPathComponent(CharacterManifest.fileName, isDirectory: false)
        // No manifest (or one that cannot be read) means a pack with default settings, as on Android.
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func hasModel(_ manifest: CharacterManifest, in directory: URL) -> Bool {
        isFile(directory.appendingPathComponent(manifest.model, isDirectory: false))
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
