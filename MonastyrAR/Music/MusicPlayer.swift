import AVFoundation
import Foundation
import Observation
import UIKit

/// Plays one backing track through the speaker, looped: the preview in the music sheet and the timing guide while
/// a recording runs. What it plays never reaches a recording by itself: a take with music is made without the
/// microphone, and the music is written into the file afterwards. Port of `music/MusicPlayer.kt`.
///
/// Audio session: the app has no session set-up of its own. The microphone capture (`MicrophoneCapture`, an
/// `AVCaptureSession`) lets the capture session configure the shared session for recording whenever it starts.
/// This player therefore sets the `playback` category itself every time it starts (whatever a take with the
/// microphone left behind), activates the session only while it plays and lets go of it when it stops, so music
/// from another app is paused for a preview and comes back afterwards. The two never run at the same time: a
/// preview is stopped when a recording starts, and the guide only plays in takes that leave the microphone out.
///
/// All members are main-actor; `playingId` drives SwiftUI. Nothing here throws: a track that cannot be played
/// simply never becomes the playing one.
@MainActor
@Observable
final class MusicPlayer {

    private enum Purpose {
        case preview
        case guide
    }

    /// Id of the track that is audible right now (preview or guide), else nil.
    private(set) var playingId: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    /// Id of the track `player` holds: playing, or prepared for a guide that has not started yet.
    @ObservationIgnored private var loadedId: String?
    @ObservationIgnored private var purpose = Purpose.preview
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let decodeErrors = DecodeErrorListener()

    init() {
        let center = NotificationCenter.default
        // A phone call, an alarm, another app taking the output: the system has already silenced the player.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.stop() }
        })
        // Headphones pulled out: the music must not carry on from the speaker.
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in self?.stop() }
        })
        // The audio server restarted: every player object is dead.
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        })
        // Like `ON_PAUSE` on Android: nothing keeps playing once the app is not in front.
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        })
        decodeErrors.onError = { [weak self] failed in
            Task { @MainActor [weak self] in self?.stop(ifHolding: failed) }
        }
    }

    /// Plays `track` in a loop until `stop`. Another track replaces the one playing; the same track keeps playing
    /// and only takes the new `volume`.
    func preview(_ track: MusicTrack, volume: Float) {
        if playingId == track.id, purpose == .preview, player != nil {
            setVolume(volume)
            return
        }
        guard load(track, volume: volume, purpose: .preview) else { return }
        startLoaded()
    }

    /// Gets `track` ready to play as the guide of a recording, without a sound yet: opening the file and the
    /// audio output takes a moment, and that moment should pass before the take starts, not during its first
    /// frames. Returns false when the track cannot be played.
    func prepareGuide(_ track: MusicTrack, volume: Float) -> Bool {
        load(track, volume: volume, purpose: .guide)
    }

    /// Starts the guide made ready by `prepareGuide`, from the first note of the track.
    func startPreparedGuide() {
        guard purpose == .guide else { return }
        startLoaded()
    }

    /// The level of whatever is playing; the volume slider is heard while it moves.
    func setVolume(_ volume: Float) {
        player?.volume = MusicPlayer.level(volume)
    }

    /// Stops the preview or the guide and lets other apps have the audio output back.
    func stop() {
        guard player != nil else { return }
        unload()
        MusicPlayer.deactivateSession()
    }

    /// Stops a preview, but leaves a guide alone. For the music sheet going away, which can happen a moment after
    /// a recording has started.
    func stopPreview() {
        if purpose == .preview { stop() }
    }

    // MARK: internals

    private func load(_ track: MusicTrack, volume: Float, purpose: Purpose) -> Bool {
        // The player that was playing goes, the audio session stays: no gap for another app's music to jump into.
        unload()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let created = try AVAudioPlayer(contentsOf: track.url)
            created.numberOfLoops = -1
            created.volume = MusicPlayer.level(volume)
            created.delegate = decodeErrors
            guard created.prepareToPlay() else {
                MusicPlayer.deactivateSession()
                return false
            }
            player = created
            loadedId = track.id
            self.purpose = purpose
            return true
        } catch {
            MusicPlayer.deactivateSession()
            return false
        }
    }

    private func startLoaded() {
        guard let loaded = player, let id = loadedId else { return }
        if loaded.play() {
            playingId = id
        } else {
            stop()
        }
    }

    private func unload() {
        guard let current = player else { return }
        player = nil
        loadedId = nil
        playingId = nil
        current.delegate = nil
        current.stop()
    }

    /// A decode error about a player that is gone already is ignored.
    private func stop(ifHolding failed: ObjectIdentifier) {
        guard let current = player, ObjectIdentifier(current) == failed else { return }
        stop()
    }

    private static func level(_ volume: Float) -> Float {
        volume.isFinite ? min(max(volume, 0), 1) : 0
    }

    private static func deactivateSession() {
        // Fails when something else in the app still uses the audio output; then there is nothing to give back.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// `AVAudioPlayerDelegate` needs an `NSObject`; this one only passes on which player failed. `onError` is set
/// once, before any player exists, and may be called on whatever thread the player reports from.
private final class DecodeErrorListener: NSObject, AVAudioPlayerDelegate {
    var onError: (@Sendable (ObjectIdentifier) -> Void)?

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onError?(ObjectIdentifier(player))
    }
}
