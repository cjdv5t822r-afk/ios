import AVFoundation
import Observation
import RealityKit
import StageCore
import UIKit

enum CaptureFailure: Equatable {
    /// The 3D view was not ready to be recorded (still starting, or being torn down).
    case notReady
    /// The encoder produced nothing: the recording was too short or the device refused the format.
    case noVideo
    /// The photo could not be read from the view.
    case noPhoto
    /// The file was captured but could not be kept.
    case storage
    /// The file was captured and can be shared, but the photo library refused it (no permission).
    case noLibraryAccess
    /// The video was saved, but the chosen music could not be written into it.
    case music
}

enum CaptureEvent: Equatable {
    case saved(SavedCapture, hasAudio: Bool)
    case failed(CaptureFailure)
}

/// Photo and video capture of the 3D view (camera feed + characters, never the SwiftUI controls), with the logo
/// composited into every frame. One controller lives above the AR / Studio switch and serves both scenes: the
/// scene that is showing attaches its view. Port of `capture/CaptureController.kt`.
///
/// A recording started while a music track is chosen (`setMusic`) is made without the microphone and gets that
/// track written into it before it reaches the photo library.
///
/// The first controller of a process also sends to the library the recordings a killed process never got there.
///
/// All members are main-actor; the observable ones drive SwiftUI.
@MainActor
@Observable
final class CaptureController {

    static let minRecordingMillis = 1_000
    private static let stopFallbackSeconds: TimeInterval = 2
    private static let helperHideDelay: Duration = .milliseconds(120)

    /// When this process began capturing. Whatever was last written to the temporary folder before this moment
    /// was left there by an earlier process.
    private static let launchDate = Date()
    private static var leftoversRecovered = false

    let recorder: SceneRecorder
    private let overlay: LogoOverlay
    @ObservationIgnored private var settings = AppSettings()
    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var recordingStartedAt = Date.distantPast
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    /// Plays the chosen track aloud while recording when the settings ask for the guide; nil for no guide.
    @ObservationIgnored var musicPlayer: MusicPlayer?

    /// The track that will be added to the next recording, or nil for a recording without music.
    @ObservationIgnored private var music: MusicTrack?

    /// The music of the recording that is running or closing its file, fixed when it started; nil when it has none.
    @ObservationIgnored private var recordingMusic: RecordingMusic?

    /// Takes that were started and whose file the recorder has not reported back yet: 0 or 1. The next take waits
    /// for it, so `recordingMusic` always belongs to the take that reports next.
    @ObservationIgnored private var unfinishedTakes = 0

    /// See `isSaving`. A count, because captures queue up behind one another on their way to the library.
    private var savingCount = 0

    /// See `isAddingMusic`.
    private var addingMusicCount = 0

    /// See `canStop`.
    private var stopUnlocked = false

    /// One call per finished capture (saved or failed). The screen shows a message for it.
    @ObservationIgnored var onEvent: ((CaptureEvent) -> Void)?

    private(set) var isRecording = false

    /// Length of the running recording; updated a few times per second.
    private(set) var elapsedMillis = 0

    /// Seconds left before a capture starts, or nil when no countdown is running.
    private(set) var countdown: Int?

    private(set) var isTakingPhoto = false

    /// A capture is on its way into the photo library; for a video with music that includes adding the music.
    var isSaving: Bool { savingCount > 0 }

    /// The most recent capture of this session, for the thumbnail / share button.
    private(set) var lastCapture: SavedCapture?

    init() {
        let overlay = LogoOverlay(logo: BrandLogo.image?.cgImage)
        self.overlay = overlay
        recorder = SceneRecorder(overlay: overlay)
        recorder.onRecordingFinished = { [weak self] recording in
            // Runs for every way a recording can end: stop button, time limit, app going to the background.
            self?.recordingFinished(recording)
        }
        recoverLeftovers()
    }

    /// The music is being written into a finished recording.
    var isAddingMusic: Bool { addingMusicCount > 0 }

    /// True while a frame is going into a file: the stage hides the reticle and the surface tint.
    var hideHelpers: Bool { isRecording || isTakingPhoto }

    /// A recording shorter than this has no frames in it yet, so the stop button waits. Should no frame ever arrive
    /// (the frame capture failing on some device), the button unlocks anyway after a moment, so a take can always
    /// be ended.
    var canStop: Bool { isRecording && (stopUnlocked || elapsedMillis >= CaptureController.minRecordingMillis) }

    var isBusy: Bool { isRecording || isTakingPhoto || countdown != nil }

    func apply(_ value: AppSettings) {
        settings = value
        overlay.apply(value)
    }

    /// The track to write into the recordings that start from now on (the one chosen in the music sheet), or nil
    /// for none. A recording that is already running keeps the track it started with.
    func setMusic(_ track: MusicTrack?) {
        music = track
    }

    /// The scene that is showing hands in its view.
    func attach(to view: ARView) {
        arView = view
        recorder.attach(to: view)
    }

    func detach(from view: ARView) {
        guard arView === view else { return }
        cancelCountdown()
        recorder.detach(from: view)
        if isRecording { markStopped() }
        arView = nil
    }

    /// Starts a recording (after the countdown from the settings), or stops the running one.
    func toggleRecording() {
        if isRecording {
            if canStop { stopRecording() }
        } else if countdown != nil {
            cancelCountdown()
        } else if !isTakingPhoto {
            afterCountdown { [weak self] in self?.startRecording() }
        }
    }

    /// Takes a photo (after the countdown from the settings). Works while recording too.
    func takePhoto() {
        if isTakingPhoto || countdown != nil { return }
        if isRecording {
            capturePhoto()
        } else {
            afterCountdown { [weak self] in self?.capturePhoto() }
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    /// Ends a running recording and keeps the file. Called when the app leaves the foreground: rendering stops there.
    func stopIfRecording() {
        cancelCountdown()
        if isRecording { stopRecording() }
    }

    // MARK: video

    private func afterCountdown(_ action: @escaping () -> Void) {
        let seconds = settings.countdownSeconds
        guard seconds > 0 else {
            action()
            return
        }
        countdownTask = Task { [weak self] in
            for left in stride(from: seconds, through: 1, by: -1) {
                self?.countdown = left
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.countdown = nil
            self?.countdownTask = nil
            action()
        }
    }

    private func startRecording() {
        // The take before this one is still closing its file (a matter of milliseconds).
        guard unfinishedTakes == 0 else {
            onEvent?(.failed(.notReady))
            return
        }
        let limit = settings.maxDurationSeconds
        let microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let track = music
        let volume = settings.musicVolume
        // A preview still playing has no place in a recording; the guide starts the track from its first note.
        // It is made ready before the take starts, so that opening the file and the audio output does not cost
        // the take its first frames, and is set off the moment the recorder runs.
        var guideReady = false
        if let track, settings.musicGuide, let player = musicPlayer {
            guideReady = player.prepareGuide(track, volume: volume)
        } else {
            musicPlayer?.stop()
        }
        let started = recorder.startRecording(settings: VideoSettings(
            // The microphone would pick the guide up from the speaker, under the clean copy added afterwards.
            recordAudio: track == nil && settings.recordMicrophone && microphoneGranted,
            maxDurationMillis: limit > 0 ? limit * 1_000 : 0
        ))
        guard started else {
            musicPlayer?.stop()
            onEvent?(.failed(.notReady))
            return
        }
        unfinishedTakes += 1
        recordingMusic = track.map { RecordingMusic(track: $0, volume: volume) }
        if guideReady { musicPlayer?.startPreparedGuide() }
        isRecording = true
        elapsedMillis = 0
        stopUnlocked = false
        recordingStartedAt = Date()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.elapsedMillis = self.recorder.elapsedMillis
                if !self.stopUnlocked,
                   Date().timeIntervalSince(self.recordingStartedAt) >= CaptureController.stopFallbackSeconds {
                    self.stopUnlocked = true
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopRecording() {
        markStopped()
        recorder.stopRecording()
    }

    private func markStopped() {
        isRecording = false
        clock?.invalidate()
        clock = nil
        // The guide ends with the take, whichever way the take ends.
        if recordingMusic != nil { musicPlayer?.stop() }
    }

    private func recordingFinished(_ recording: Recording?) {
        // The recorder may have stopped by itself (time limit, view torn down).
        if isRecording { markStopped() }
        unfinishedTakes = max(0, unfinishedTakes - 1)
        let withMusic = recordingMusic
        recordingMusic = nil
        guard let recording else {
            onEvent?(.failed(.noVideo))
            return
        }
        publish(recording.file, kind: .video, hasAudio: recording.hasAudio, music: withMusic)
    }

    // MARK: photo

    private func capturePhoto() {
        guard let view = arView else {
            onEvent?(.failed(.notReady))
            return
        }
        isTakingPhoto = true
        Task { [weak self] in
            // Give the scene a few frames to drop the reticle and the surface tint before the pixels are copied.
            try? await Task.sleep(for: CaptureController.helperHideDelay)
            let image: UIImage? = await withCheckedContinuation { continuation in
                view.snapshot(saveToHDR: false) { continuation.resume(returning: $0) }
            }
            guard let self else { return }
            let file = image.flatMap { self.writePhoto($0) }
            self.isTakingPhoto = false
            if let file {
                self.publish(file, kind: .photo, hasAudio: false, music: nil)
            } else {
                self.onEvent?(.failed(.noPhoto))
            }
        }
    }

    /// Draws the logo over a snapshot of the view and writes it as a JPEG; nil when that fails.
    private func writePhoto(_ snapshot: UIImage) -> URL? {
        guard let cgImage = snapshot.cgImage, cgImage.width > 0, cgImage.height > 0 else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let placed = overlay.placement(frameWidth: cgImage.width, frameHeight: cgImage.height)
        let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.92) { _ in
            // UIKit drawing has its origin in the top-left corner, like the layout maths.
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
            if let placed {
                UIImage(cgImage: placed.image).draw(in: placed.rect, blendMode: .normal, alpha: placed.opacity)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: saving

    /// Sends a captured file to the photo library; a recording made with `music` gets the track written into it
    /// first. When that fails the silent recording is saved instead, and reported both as saved and as
    /// `CaptureFailure.music`.
    private func publish(_ file: URL, kind: CaptureKind, hasAudio: Bool, music: RecordingMusic?) {
        savingCount += 1
        let previous = publishTask
        // One of the ways a recording ends is the app leaving the foreground. Ask for the time to finish the file
        // and hand it to the library before the app is suspended.
        let background = BackgroundTime(name: "MonastyrAR.publish")
        publishTask = Task { [weak self] in
            // One at a time: publishing empties the captures folder, and the capture before this one may still
            // be on its way into the photo library from there.
            _ = await previous?.value
            var source = file
            var audible = hasAudio
            var musicFailed = false
            if let music {
                self?.addingMusicCount += 1
                let mixed = await MusicMux.addMusic(to: file, track: music.track, volume: music.volume)
                self?.addingMusicCount -= 1
                if let mixed {
                    try? FileManager.default.removeItem(at: file)
                    source = mixed
                    audible = true
                } else {
                    musicFailed = true
                }
            }
            let outcome = await CaptureSaver.publish(source, kind: kind)
            background.end()
            guard let self else { return }
            self.savingCount -= 1
            switch outcome {
            case .saved(let capture):
                self.lastCapture = capture
                self.onEvent?(.saved(capture, hasAudio: audible))
                if musicFailed { self.onEvent?(.failed(.music)) }
            case .keptWithoutLibraryAccess(let capture):
                self.lastCapture = capture
                self.onEvent?(.failed(.noLibraryAccess))
            case .failed:
                self.onEvent?(.failed(.storage))
            }
        }
    }

    // MARK: leftovers

    /// A process that is killed between the end of a recording and its arrival in the photo library (it is in the
    /// background by then, writing the music) leaves the recording in the temporary folder, where nothing would
    /// look for it again. Those takes are published now, as they were recorded: the music they were meant to get
    /// is not known any more. Half-written copies with music and takes cut off mid-recording are deleted.
    private func recoverLeftovers() {
        if CaptureController.leftoversRecovered { return }
        CaptureController.leftoversRecovered = true
        let before = CaptureController.launchDate
        Task { [weak self] in
            let leftovers = await Task.detached(priority: .utility) {
                await CaptureController.leftoverRecordings(before: before)
            }.value
            for leftover in leftovers {
                self?.publish(leftover.file, kind: .video, hasAudio: leftover.hasAudio, music: nil)
            }
        }
    }

    /// The playable takes in the temporary folder that were last written before `before`, oldest first. One that
    /// cannot be opened was cut off mid-recording; it is of no use to anyone and is deleted.
    private nonisolated static func leftoverRecordings(before: Date) async -> [Leftover] {
        MusicMux.removeOutputs(olderThan: before)
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        )) ?? []
        var takes: [(file: URL, modified: Date)] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(SceneRecorder.takePrefix), name.hasSuffix(SceneRecorder.takeSuffix) else { continue }
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate, modified < before else { continue }
            takes.append((file: entry, modified: modified))
        }
        takes.sort { $0.modified < $1.modified }

        var leftovers: [Leftover] = []
        for take in takes {
            let asset = AVURLAsset(url: take.file)
            let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            if video.isEmpty {
                try? fm.removeItem(at: take.file)
            } else {
                let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                leftovers.append(Leftover(file: take.file, hasAudio: !audio.isEmpty))
            }
        }
        return leftovers
    }

    private struct RecordingMusic {
        let track: MusicTrack
        let volume: Float
    }

    private struct Leftover {
        let file: URL
        let hasAudio: Bool
    }
}

/// Time to finish a piece of work after the app has left the foreground.
@MainActor
private final class BackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Out of time: iOS suspends the app, and the work goes on when the app is opened again.
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
