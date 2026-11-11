import Foundation
import Observation
import StageCore

/// Lists the character packs on the phone (`Documents/characters/<id>/`): the ones downloaded from the pack
/// server and the ones the user imported from a file. The app itself ships none. Port of
/// `content/PackRepository.kt`.
@MainActor
@Observable
final class PackRepository {

    /// Downloaded and imported packs by name. Empty until the first `refresh`.
    private(set) var packs: [CharacterPack] = []

    /// True once `packs` has been read from disk: from then on an empty list means that nothing is installed.
    private(set) var loaded = false

    /// The listing `packs` came from; see `PackStore.Listing`.
    @ObservationIgnored private var publishedSerial = 0

    /// Folder that holds one sub-folder per pack, downloaded or imported.
    nonisolated static var packsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return documents.appendingPathComponent(PackRules.charactersDirectory, isDirectory: true)
    }

    /// Reads the packs folder again and returns what is in it.
    @discardableResult
    func refresh() async -> [CharacterPack] {
        let directory = PackRepository.packsDirectory
        // Read with the store's lock held: a listing never catches a pack between the two renames that replace it.
        let listing = await Task.detached(priority: .userInitiated) {
            PackStore.list(directory) { id in NSLog("PackRepository: bad manifest, pack skipped: %@", id) }
        }.value
        // Two listings can come back in either order; the older one is never published over the newer.
        if listing.serial > publishedSerial {
            publishedSerial = listing.serial
            if packs != listing.packs { packs = listing.packs }
            if !loaded { loaded = true }
        }
        return listing.packs
    }

    /// Removes a pack from disk. False when it is not there any more as the pack that `pack` was listed as.
    func delete(_ pack: CharacterPack) async -> Bool {
        let directory = PackRepository.packsDirectory
        let ok = await Task.detached(priority: .userInitiated) {
            PackStore.delete(pack, from: directory)
        }.value
        await refresh()
        return ok
    }
}
