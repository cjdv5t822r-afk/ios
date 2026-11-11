import AVFoundation
import Foundation
import Observation
import StageCore

/// A message along the bottom of the screen (the Android app's snackbar).
struct Banner: Equatable, Identifiable {
    enum Action: Equatable {
        /// "Udostępnij": open the share sheet for a capture.
        case share(SavedCapture)
    }

    let id = UUID()
    let text: String
    var action: Action?
}

/// State that lives as long as the app: the settings, the character packs, the stage itself and the capture
/// controller. Port of `StageViewModel.kt`; everything here runs on the main actor.
@MainActor
@Observable
final class StageViewModel {

    let stage: StageState
    let capture: CaptureController
    let packRepository: PackRepository

    /// The character library: what the pack server offers and the downloads in progress.
    let library: PackLibrary

    /// The in-memory copy is the truth: a mode switch and the stage reset that goes with it have to land in the
    /// same frame, and a slider cannot wait for a disk round trip per step.
    private(set) var settings: AppSettings

    /// True while a picked file is being copied into the app.
    private(set) var importing = false

    /// The message that is up right now, if any.
    private(set) var banner: Banner?

    /// The microphone permission was refused, so the switch in the settings cannot stay on.
    private(set) var microphoneBlocked = false

    /// The backing tracks, built-in and imported. What is done with them is in `StageViewModel+Music.swift`.
    let musicRepository: MusicRepository

    /// One player for the previews in the music sheet and for the guide during a take: the two never overlap.
    let musicPlayer: MusicPlayer

    /// True while a picked audio file is being copied into the app.
    var importingMusic = false

    @ObservationIgnored private let settingsRepository = SettingsRepository()
    @ObservationIgnored private var importer: PackImporter?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    private static let persistDelay: Duration = .milliseconds(200)
    private static let shortBanner: Duration = .seconds(3)
    private static let longBanner: Duration = .seconds(7)

    /// The packs on the phone, downloaded and imported.
    var packs: [CharacterPack] { packRepository.packs }

    /// False until `packs` has been read from disk; before that an empty list does not mean "nothing installed".
    var packsLoaded: Bool { packRepository.loaded }

    init() {
        stage = StageState()
        capture = CaptureController()
        musicRepository = MusicRepository()
        musicPlayer = MusicPlayer()
        let repository = PackRepository()
        packRepository = repository
        library = PackLibrary(repository: repository)
        settings = settingsRepository.load()
        capture.apply(settings)
        capture.onEvent = { [weak self] event in self?.onCaptureEvent(event) }
        startMusic()
        importer = PackImporter(repository: packRepository)
        library.onEvent = { [weak self] event in self?.onLibraryEvent(event) }
        Task { [packRepository, library] in
            // A pack that the last run left half-way through being replaced is put back first; listed before
            // that, it would be missing.
            await library.awaitRecovery()
            await packRepository.refresh()
        }
        refreshCatalog()
    }

    // MARK: settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        updated = updated.sanitized()
        if updated == settings { return }
        settings = updated
        capture.apply(updated)
        syncMusic()
        persistTask?.cancel()
        persistTask = Task { [settingsRepository] in
            try? await Task.sleep(for: StageViewModel.persistDelay)
            if Task.isCancelled { return }
            settingsRepository.save(updated)
        }
    }

    /// Writes pending settings now. Called when the app leaves the foreground, where a delayed write may never run.
    func flushSettings() {
        persistTask?.cancel()
        persistTask = nil
        settingsRepository.save(settings)
    }

    /// Switches between AR and Studio. Models do not survive the switch, so the stage is emptied first.
    func setMode(_ mode: StageMode) {
        if settings.mode == mode { return }
        resetStage()
        updateSettings { $0.mode = mode }
    }

    /// Empties the stage: before a scene (re)starts, because nothing from the previous one is alive any more.
    func resetStage() {
        stage.clear()
        stage.armedPack = nil
        stage.applyToAll = false
        stage.arHint = .starting
    }

    /// AR could not start on this device: fall back to Studio and say why.
    func onArUnavailable() {
        if settings.mode != .ar { return }
        setMode(.studio)
        show(Strings.arUnsupported)
    }

    /// The microphone switch was flipped. Asks for the permission the first time it is switched on.
    func setMicrophone(_ on: Bool) {
        updateSettings { $0.recordMicrophone = on }
        guard on else {
            microphoneBlocked = false
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneBlocked = false
        case .notDetermined:
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                self?.microphoneBlocked = !granted
                self?.updateSettings { $0.recordMicrophone = granted }
            }
        default:
            // Refused earlier: iOS does not ask twice, only the system settings can change it.
            microphoneBlocked = true
            updateSettings { $0.recordMicrophone = false }
        }
    }

    // MARK: characters

    /// Puts `pack` on the stage: in Studio right away, in AR with the next tap on a surface.
    /// Returns false (and says so) when the stage is full.
    @discardableResult
    func choosePack(_ pack: CharacterPack) -> Bool {
        guard stage.canAddMore else {
            show(Strings.stageFull)
            return false
        }
        place(pack)
        updateSettings { $0.lastCharacterId = pack.id }
        return true
    }

    /// Gives an empty stage its first character: the one used last time, or the first one there is.
    func placeStarter() {
        if !stage.actors.isEmpty || stage.armedPack != nil { return }
        let available = packs
        if let pack = available.first(where: { $0.id == settings.lastCharacterId }) ?? available.first {
            place(pack)
        }
    }

    func importPack(from url: URL) {
        guard !importing, let importer else { return }
        importing = true
        Task { [weak self, library] in
            // The clean-up after a killed process removes import leftovers; this import must not be one.
            await library.awaitRecovery()
            let result = await importer.importPack(from: url)
            guard let self else { return }
            self.importing = false
            switch result {
            case .success(let pack): self.onImported(pack)
            case .failure(let error): self.show(Strings.importError(error))
            }
        }
    }

    /// Asks the pack server for its catalog again.
    func refreshCatalog() {
        Task { [library] in await library.refreshCatalog() }
    }

    /// Downloads `pack`, or its newer version; when it arrives it is put on the stage like an imported one.
    func downloadPack(_ pack: RemotePack) {
        library.download(pack)
    }

    func cancelDownload(_ packId: String) {
        library.cancel(packId)
    }

    /// Starts a failed download again.
    func retryDownload(_ pack: RemotePack) {
        library.dismissFailure(pack.id)
        library.download(pack)
    }

    /// Deletes a pack from the phone, taking its characters off the stage first.
    func deletePack(_ pack: CharacterPack) {
        // The list may have moved on since the creator was asked: a download that needs the id of an imported
        // pack moves that pack to another folder and takes this one. What is here now is not what was meant.
        guard packs.contains(where: { $0.directory == pack.directory && sameOrigin($0, pack) }) else {
            show(Strings.deleteFailed)
            return
        }
        // An update that is still downloading would bring the pack straight back. An imported pack has no
        // updates: a download under its id is another character, which the library offers next to it.
        if pack.isDownloaded { library.cancel(pack.id) }
        // An imported and a downloaded pack can have held one id one after the other; only this one's go.
        for actor in stage.actors where actor.pack.id == pack.id && sameOrigin(actor.pack, pack) {
            stage.remove(actor)
        }
        if let armed = stage.armedPack, armed.id == pack.id, sameOrigin(armed, pack) { stage.armedPack = nil }
        if settings.lastCharacterId == pack.id {
            updateSettings { $0.lastCharacterId = nil }
        }
        Task { [weak self, packRepository] in
            let deleted = await packRepository.delete(pack)
            self?.show(deleted ? Strings.deleted(pack.name) : Strings.deleteFailed)
        }
    }

    private func onImported(_ pack: CharacterPack) {
        if capture.isBusy {
            // Not into a take that is running: the model waits in the library.
            show(Strings.imported(pack.name))
            return
        }
        show(placeNew(pack) ? Strings.imported(pack.name) : Strings.importedStageFull(pack.name))
    }

    private func onLibraryEvent(_ event: LibraryEvent) {
        switch event {
        case .installed(let pack):
            show(onDownloaded(pack))
        case .failed(let pack, let error):
            show(LibraryMessages.downloadFailed(pack.displayName, error: error))
        }
    }

    /// Puts a pack that has just been downloaded where an imported one would go; returns what to say about it.
    private func onDownloaded(_ pack: CharacterPack) -> String {
        let name = pack.name
        // The pack list is published before this event arrives, so the starter or a tap in the sheet may have
        // put this very copy on the stage already.
        if stage.armedPack == pack || stage.actors.contains(where: { $0.pack == pack }) {
            return LibraryMessages.downloaded(name)
        }
        // A newer version of a character that stands on the stage. Its actors keep the model they loaded, which
        // lives in memory and not in the files that were just replaced, so nothing changes under a take that
        // may be running; a second copy next to them is not what "update" asked for either.
        if stage.actors.contains(where: { $0.pack.id == pack.id && $0.pack.isDownloaded }) {
            // The next tap in AR must not place the old manifest on top of the new model.
            if stage.armedPack?.id == pack.id { stage.armedPack = pack }
            return LibraryMessages.updatedOnStage(name)
        }
        // Not into a take that is running: the character waits in the library.
        if capture.isBusy { return LibraryMessages.downloaded(name) }
        return placeNew(pack) ? LibraryMessages.downloaded(name) : LibraryMessages.downloadedStageFull(name)
    }

    /// A pack that has just arrived goes on the stage when there is room; false when there is none.
    private func placeNew(_ pack: CharacterPack) -> Bool {
        guard stage.canAddMore else { return false }
        place(pack)
        updateSettings { $0.lastCharacterId = pack.id }
        return true
    }

    /// Whether both packs were downloaded, or both imported.
    private func sameOrigin(_ a: CharacterPack, _ b: CharacterPack) -> Bool {
        a.isDownloaded == b.isDownloaded
    }

    private func place(_ pack: CharacterPack) {
        switch settings.mode {
        case .ar: stage.armedPack = pack
        case .studio: stage.addInStudio(pack: pack)
        }
    }

    // MARK: messages

    /// Shows `text` now, replacing whatever message is up: the newest one is the one that matters.
    func show(_ text: String, action: Banner.Action? = nil) {
        let next = Banner(text: text, action: action)
        banner = next
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: action == nil ? StageViewModel.shortBanner : StageViewModel.longBanner)
            if Task.isCancelled { return }
            if self?.banner?.id == next.id { self?.banner = nil }
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    private func onCaptureEvent(_ event: CaptureEvent) {
        switch event {
        case .saved(let capture, _):
            show(Strings.saved, action: .share(capture))
        case .failed(let failure):
            show(Strings.captureFailure(failure))
        }
    }
}
