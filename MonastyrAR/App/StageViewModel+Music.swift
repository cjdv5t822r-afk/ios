import Foundation
import StageCore

/// The music part of the view model: the track list, the chosen track, import and delete.
/// Port of the music functions of `StageViewModel.kt`.
extension StageViewModel {

    /// Built-in tracks first, then imported ones. The chosen one is `AppSettings.musicTrackId`.
    var musicTracks: [MusicTrack] { musicRepository.tracks }

    /// The track that goes into the next recordings, or nil for recordings without music.
    var musicTrack: MusicTrack? { musicRepository.find(settings.musicTrackId) }

    /// Reads the track list and hands the chosen track and the player to the capture controller.
    /// Called once, when the view model is made.
    func startMusic() {
        capture.musicPlayer = musicPlayer
        Task { [weak self, musicRepository] in
            // What a killed process left half-imported in the music folder goes before anything else happens there.
            await musicRepository.clearLeftovers()
            await musicRepository.refresh()
            // The chosen track may be gone: an imported file lost with the app's data (the music folder is not
            // part of a backup), or a built-in one dropped by an update.
            self?.dropMissingMusic()
            self?.syncMusic()
        }
    }

    /// Tells the capture controller which track the next recording gets. To be called whenever the chosen id or
    /// the track list may have changed.
    func syncMusic() {
        capture.setMusic(musicTrack)
    }

    /// Chooses the track written into the next recordings; nil for recordings without music.
    func selectMusic(_ track: MusicTrack?) {
        updateSettings { $0.musicTrackId = track?.id }
    }

    /// Copies a picked audio file into the app and chooses it.
    func importMusic(from url: URL) {
        if importingMusic { return }
        importingMusic = true
        Task { [weak self, musicRepository] in
            await musicRepository.clearLeftovers()
            let result = await MusicImporter(repository: musicRepository).importTrack(from: url)
            guard let self else { return }
            self.importingMusic = false
            switch result {
            case .success(let track):
                self.selectMusic(track)
                self.syncMusic()
                self.show(Strings.musicImportedMessage(track.title))
            case .failure(let error):
                self.show(Strings.musicImportError(error))
            }
        }
    }

    /// Deletes an imported track; recordings go back to having no music when it was the chosen one.
    func deleteMusic(_ track: MusicTrack) {
        if track.isBuiltIn { return }
        // The player must let go of the file before it is removed.
        if musicPlayer.playingId == track.id { musicPlayer.stop() }
        Task { [weak self, musicRepository] in
            let deleted = await musicRepository.delete(track)
            guard let self else { return }
            self.dropMissingMusic()
            self.syncMusic()
            self.show(deleted ? Strings.musicDeletedMessage(track.title) : Strings.musicDeleteFailed)
        }
    }

    /// Forgets the chosen track when it is not in the list any more. Only meaningful once the list has been read.
    private func dropMissingMusic() {
        guard let id = settings.musicTrackId, musicRepository.find(id) == nil else { return }
        updateSettings { $0.musicTrackId = nil }
    }
}
