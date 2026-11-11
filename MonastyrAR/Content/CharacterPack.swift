import Foundation
import StageCore

/// One character the creator can put on the stage: a `character.json` and the GLB it points at, in a folder of
/// its own in the app's Documents directory. The app itself ships none: a pack is either downloaded from the
/// pack server or imported from a file.
struct CharacterPack: Equatable, Identifiable, Sendable {
    let manifest: CharacterManifest

    /// The folder of the pack, `Documents/characters/<id>/`.
    let directory: URL

    /// The catalog version this pack was downloaded as (`RemotePack.version`); nil for a pack imported from a
    /// file. A downloaded pack whose version differs from the catalog's has an update waiting.
    let remoteVersion: String?

    init(manifest: CharacterManifest, directory: URL, remoteVersion: String? = nil) {
        self.manifest = manifest
        self.directory = directory
        self.remoteVersion = remoteVersion
    }

    var id: String { manifest.id }
    var name: String { manifest.displayName }

    /// True for a pack that came from the pack server, false for one imported from a file.
    var isDownloaded: Bool { remoteVersion != nil }

    /// The GLB file of the pack.
    var modelURL: URL { directory.appendingPathComponent(manifest.model, isDirectory: false) }
}
