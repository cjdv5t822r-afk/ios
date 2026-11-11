import XCTest
@testable import StageCore

// Ports of the Android tests in `app/src/test/.../music/` that apply to what the iOS app does itself. Left out:
// byte-level PCM decoding (Core Audio decodes), the linear resampler and the silent tail for the encoder (the
// asset writer converts sample rates and handles the end of the AAC track).

final class MusicNamesTests: XCTestCase {

    func testTitlesAreMadeFromFileNames() {
        XCTAssertEqual(MusicNames.title("war_drums.wav"), "War drums")
        XCTAssertEqual(MusicNames.title("  my__song-final.mp3"), "My song-final")
        XCTAssertEqual(MusicNames.title("żółw_na_plaży.ogg"), "Żółw na plaży")
        XCTAssertEqual(MusicNames.title("Track 1.5 remix.flac"), "Track 1.5 remix")
        XCTAssertEqual(MusicNames.title("noext"), "Noext")
        // Nothing left to show: the file name itself is better than an empty row.
        XCTAssertEqual(MusicNames.title("___.mp3"), "___.mp3")
    }

    func testSafeNamesCannotLeaveTheMusicFolder() {
        XCTAssertEqual(MusicNames.safeBaseName("../../etc/passwd.mp3"), "passwd")
        XCTAssertEqual(MusicNames.safeBaseName("a/b\\c:d*.MP3"), "c d")
        XCTAssertEqual(MusicNames.safeBaseName(".hidden.mp3"), "hidden")
        XCTAssertEqual(MusicNames.safeBaseName("..\\..\\evil.wav"), "evil")
        XCTAssertEqual(MusicNames.safeBaseName("a\u{0}\nb.ogg"), "a b")
        let forbidden: Set<Unicode.Scalar> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
        for name in ["../x.mp3", "a/b\\c.wav", ".x.ogg", "C:\\Music\\song?.flac", "\u{7}.mp3"] {
            let safe = MusicNames.safeBaseName(name)
            XCTAssertFalse(safe.isEmpty, name)
            XCTAssertFalse(safe.hasPrefix("."), name)
            XCTAssertFalse(
                safe.unicodeScalars.contains { forbidden.contains($0) || $0.properties.generalCategory == .control },
                name
            )
        }
    }

    func testSafeNamesFallBackWhenNothingIsLeft() {
        XCTAssertEqual(MusicNames.safeBaseName(nil), "muzyka")
        XCTAssertEqual(MusicNames.safeBaseName(""), "muzyka")
        XCTAssertEqual(MusicNames.safeBaseName("..."), "muzyka")
        XCTAssertEqual(MusicNames.safeBaseName("???.mp3"), "muzyka")
        XCTAssertEqual(MusicNames.safeBaseName(".mp3"), "muzyka")
    }

    func testSafeNamesKeepLettersOfAnyAlphabet() {
        XCTAssertEqual(MusicNames.safeBaseName("Zażółć gęślą jaźń.flac"), "Zażółć gęślą jaźń")
        XCTAssertEqual(MusicNames.safeBaseName("Песня (live) 2.m4a"), "Песня (live) 2")
    }

    func testSafeNamesAreCutWithoutSplittingACharacter() {
        let long = MusicNames.safeBaseName(String(repeating: "x", count: 200) + ".mp3")
        XCTAssertEqual(long.utf16.count, 60)
        // The 60th and 61st UTF-16 units are the two halves of one emoji.
        let cut = MusicNames.safeBaseName(String(repeating: "x", count: 59) + "\u{1F3B5}" + "tail.mp3")
        XCTAssertEqual(cut, String(repeating: "x", count: 59))
    }

    func testOnlyKnownAudioExtensionsAreKept() {
        XCTAssertEqual(MusicNames.fileExtension("Song.MP3"), "mp3")
        XCTAssertEqual(MusicNames.fileExtension("a.b.flac"), "flac")
        XCTAssertNil(MusicNames.fileExtension("tool.exe"))
        XCTAssertNil(MusicNames.fileExtension("noext"))
        XCTAssertNil(MusicNames.fileExtension(nil))
        // An unknown extension stays part of the name and the real one comes from the content.
        XCTAssertEqual(MusicNames.safeBaseName("song.xyz"), "song.xyz")
        // iOS only: the containers Apple's own apps write.
        XCTAssertEqual(MusicNames.fileExtension("Memo.AIFF"), "aiff")
        XCTAssertEqual(MusicNames.fileExtension("loop.caf"), "caf")
    }

    func testAMissingExtensionComesFromTheAudioFormat() {
        XCTAssertEqual(MusicNames.extensionForMime("audio/mpeg"), "mp3")
        XCTAssertEqual(MusicNames.extensionForMime("audio/mp4a-latm"), "m4a")
        XCTAssertEqual(MusicNames.extensionForMime("audio/vorbis"), "ogg")
        XCTAssertEqual(MusicNames.extensionForMime("audio/opus"), "opus")
        XCTAssertEqual(MusicNames.extensionForMime("AUDIO/FLAC"), "flac")
        XCTAssertEqual(MusicNames.extensionForMime("audio/raw"), "wav")
        XCTAssertEqual(MusicNames.extensionForMime("audio/x-something-new"), "audio")
    }

    func testATakenNameGetsANumber() {
        let taken: Set<String> = ["song.mp3", "song 2.mp3"]
        XCTAssertEqual(MusicNames.uniqueFileName(base: "song", fileExtension: "mp3") { taken.contains($0) }, "song 3.mp3")
        XCTAssertEqual(MusicNames.uniqueFileName(base: "other", fileExtension: "mp3") { taken.contains($0) }, "other.mp3")
        XCTAssertEqual(MusicNames.title("song 2.mp3"), "Song 2")
    }

    func testManifestFileNamesMustBePlain() {
        XCTAssertTrue(MusicNames.isPlainFileName("war_drums.wav"))
        XCTAssertFalse(MusicNames.isPlainFileName("../war_drums.wav"))
        XCTAssertFalse(MusicNames.isPlainFileName("sub/war_drums.wav"))
        XCTAssertFalse(MusicNames.isPlainFileName("sub\\war_drums.wav"))
        XCTAssertFalse(MusicNames.isPlainFileName(".hidden.wav"))
        XCTAssertFalse(MusicNames.isPlainFileName(""))
        XCTAssertFalse(MusicNames.isPlainFileName("  "))
    }

    func testImportedTracksHaveTheirOwnIdSpace() {
        XCTAssertEqual(MusicNames.importId("song.mp3"), "import:song.mp3")
        XCTAssertTrue(MusicNames.importId("war_drums.wav").hasPrefix(MusicNames.importPrefix))
    }

    func testImportLimitsMatchTheAndroidApp() {
        XCTAssertEqual(MusicRules.maxImportBytes, 62_914_560)
        XCTAssertEqual(MusicRules.stagingPrefix, ".import-")
        XCTAssertTrue(MusicRules.isSupportedFormat(sampleRate: 44_100, channels: 2))
        XCTAssertTrue(MusicRules.isSupportedFormat(sampleRate: 4_000, channels: 16))
        XCTAssertFalse(MusicRules.isSupportedFormat(sampleRate: 3_999, channels: 2))
        XCTAssertFalse(MusicRules.isSupportedFormat(sampleRate: 384_001, channels: 2))
        XCTAssertFalse(MusicRules.isSupportedFormat(sampleRate: 44_100, channels: 0))
        XCTAssertFalse(MusicRules.isSupportedFormat(sampleRate: 44_100, channels: 17))
    }
}

final class MusicManifestTests: XCTestCase {

    func testTheShippedManifestListsTheFourLoops() throws {
        let folder = repositoryRoot().appendingPathComponent("content/music")
        guard let text = try? String(contentsOf: folder.appendingPathComponent(MusicRules.manifestFile), encoding: .utf8) else {
            throw XCTSkip("content/ is not next to the package")
        }
        let tracks = MusicManifest.builtInTracks(text) { file in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
        }
        XCTAssertEqual(tracks.map(\.id), ["war_drums", "night_dance", "quiet_temple", "triumph"])
        XCTAssertEqual(tracks.map(\.title), ["Bębny wojenne", "Nocny taniec", "Cicha świątynia", "Triumf"])
        XCTAssertEqual(tracks.map(\.file), ["war_drums.wav", "night_dance.wav", "quiet_temple.wav", "triumph.wav"])
        XCTAssertEqual(tracks.map(\.seconds), [19.2, 15.484, 20, 17.455])
    }

    func testEntriesThatCannotBeUsedAreLeftOut() {
        let text = """
        {
          "format": 1,
          "tracks": [
            { "id": "a", "title": "Pierwszy", "file": "a.wav", "seconds": 12.5, "bpm": 100 },
            { "id": "a", "title": "Drugi z tym samym id", "file": "b.wav" },
            { "id": " ", "file": "c.wav" },
            { "id": "import:x", "file": "d.wav" },
            { "id": "escape", "file": "../e.wav" },
            { "id": "hidden", "file": ".f.wav" },
            { "id": "missing", "file": "gone.wav" },
            { "id": "untitled", "file": "night_dance.wav", "seconds": 0 },
            { "id": " padded ", "title": "  ", "file": "g.wav", "seconds": -3 }
          ]
        }
        """
        let tracks = MusicManifest.builtInTracks(text) { $0 != "gone.wav" }
        XCTAssertEqual(tracks, [
            MusicManifestEntry(id: "a", title: "Pierwszy", file: "a.wav", seconds: 12.5),
            MusicManifestEntry(id: "untitled", title: "Night dance", file: "night_dance.wav", seconds: nil),
            MusicManifestEntry(id: "padded", title: "G", file: "g.wav", seconds: nil),
        ])
    }

    func testABrokenManifestGivesNoTracks() {
        XCTAssertEqual(MusicManifest.builtInTracks("{", fileExists: { _ in true }), [])
        XCTAssertEqual(MusicManifest.builtInTracks("[]", fileExists: { _ in true }), [])
        XCTAssertEqual(MusicManifest.builtInTracks("{}", fileExists: { _ in true }), [])
        XCTAssertEqual(MusicManifest.builtInTracks(#"{ "tracks": [ { "id": 5, "file": "a.wav" } ] }"#, fileExists: { _ in true }), [])
    }
}

final class MusicSettingsTests: XCTestCase {

    func testDefaultsMatchTheAndroidApp() {
        let s = AppSettings()
        XCTAssertNil(s.musicTrackId)
        XCTAssertEqual(s.musicVolume, 0.8)
        XCTAssertTrue(s.musicGuide)
        XCTAssertEqual(AppSettings.musicVolumeMin, 0.1)
    }

    func testSanitizeClampsTheVolumeAndDropsABlankTrack() {
        var s = AppSettings()
        s.musicVolume = 0.01
        s.musicTrackId = "   "
        XCTAssertEqual(s.sanitized().musicVolume, AppSettings.musicVolumeMin)
        XCTAssertNil(s.sanitized().musicTrackId)
        s.musicVolume = 7
        s.musicTrackId = "import:song 2.mp3"
        XCTAssertEqual(s.sanitized().musicVolume, 1)
        XCTAssertEqual(s.sanitized().musicTrackId, "import:song 2.mp3")
        s.musicVolume = .nan
        XCTAssertEqual(s.sanitized().musicVolume, 0.8)
    }

    func testStoredFormRoundTrips() {
        var s = AppSettings()
        s.musicTrackId = "night_dance"
        s.musicVolume = 0.35
        s.musicGuide = false
        let stored = s.stored
        XCTAssertEqual(stored[AppSettings.Keys.musicTrackId] as? String, "night_dance")
        XCTAssertEqual(AppSettings(stored: stored), s)
        // No track: the key is absent, so the repository removes it.
        XCTAssertNil(AppSettings().stored[AppSettings.Keys.musicTrackId])
        XCTAssertTrue(AppSettings.Keys.all.contains(AppSettings.Keys.musicTrackId))
        XCTAssertTrue(AppSettings.Keys.all.contains(AppSettings.Keys.musicVolume))
        XCTAssertTrue(AppSettings.Keys.all.contains(AppSettings.Keys.musicGuide))
    }

    func testUnreadableStoredValuesKeepDefaults() {
        let s = AppSettings(stored: [
            AppSettings.Keys.musicTrackId: 7,
            AppSettings.Keys.musicVolume: "loud",
            AppSettings.Keys.musicGuide: "yes",
        ])
        XCTAssertEqual(s, AppSettings())
    }
}

final class MusicGainTests: XCTestCase {

    private let rate = 44_100
    private var tenSeconds: Int { 10 * rate }

    func testFadesOfALongVideoAre20And700Milliseconds() {
        let envelope = MusicGain.envelope(totalFrames: tenSeconds, sampleRate: rate, volume: 0.8)
        XCTAssertEqual(envelope.fadeInFrames, 882)
        XCTAssertEqual(envelope.fadeOutFrames, 30_870)
        let at48k = MusicGain.envelope(totalFrames: 10 * 48_000, sampleRate: 48_000, volume: 1)
        XCTAssertEqual(at48k.fadeInFrames, 960)
        XCTAssertEqual(at48k.fadeOutFrames, 33_600)
    }

    func testStartsAndEndsInSilenceAndHoldsTheVolumeBetween() {
        let envelope = MusicGain.envelope(totalFrames: tenSeconds, sampleRate: rate, volume: 0.8)
        XCTAssertEqual(envelope.at(0), 0)
        XCTAssertEqual(envelope.at(tenSeconds - 1), 0)
        // The first and the last frame at full volume.
        XCTAssertEqual(envelope.at(envelope.fadeInFrames), 0.8)
        XCTAssertEqual(envelope.at(tenSeconds - 1 - envelope.fadeOutFrames), 0.8)
        XCTAssertEqual(envelope.at(tenSeconds / 2), 0.8)
        XCTAssertLessThan(envelope.at(envelope.fadeInFrames - 1), 0.8)
        XCTAssertLessThan(envelope.at(tenSeconds - envelope.fadeOutFrames + 1_000), 0.8)
    }

    func testFadeInOnlyRises() {
        let envelope = MusicGain.envelope(totalFrames: tenSeconds, sampleRate: rate, volume: 1)
        var previous: Float = -1
        var rising = true
        for frame in 0...envelope.fadeInFrames {
            let gain = envelope.at(frame)
            if gain <= previous { rising = false }
            previous = gain
        }
        XCTAssertTrue(rising)
        XCTAssertEqual(previous, 1)
    }

    func testFadeOutOnlyFalls() {
        let envelope = MusicGain.envelope(totalFrames: tenSeconds, sampleRate: rate, volume: 1)
        var previous: Float = 2
        var falling = true
        for frame in (tenSeconds - 1 - envelope.fadeOutFrames)..<tenSeconds {
            let gain = envelope.at(frame)
            if gain > previous || gain < 0 || gain > 1 { falling = false }
            previous = gain
        }
        XCTAssertTrue(falling)
        XCTAssertEqual(previous, 0)
        // Half way through the fade the music is at half volume.
        XCTAssertEqual(envelope.at(tenSeconds - 1 - envelope.fadeOutFrames / 2), 0.5, accuracy: 0.001)
    }

    func testGainNeverLeavesTheRangeOfTheVolume() {
        let envelope = MusicGain.envelope(totalFrames: 2 * rate, sampleRate: rate, volume: 0.35)
        var inRange = true
        for frame in 0..<(2 * rate) {
            let gain = envelope.at(frame)
            if gain < 0 || gain > 0.35 { inRange = false }
        }
        XCTAssertTrue(inRange)
    }

    func testAVideoShorterThanTheFadesGetsShorterFades() {
        let total = rate * 3 / 4 // 0.75 s: half of the length that earns full fades
        let envelope = MusicGain.envelope(totalFrames: total, sampleRate: rate, volume: 1)
        XCTAssertEqual(envelope.fadeInFrames, 441)
        XCTAssertEqual(envelope.fadeOutFrames, 15_435)
        XCTAssertLessThan(envelope.fadeInFrames + envelope.fadeOutFrames, total)
        XCTAssertEqual(envelope.at(0), 0)
        XCTAssertEqual(envelope.at(total - 1), 0)
        // The fades do not meet: there is still music at full volume between them.
        XCTAssertEqual(envelope.at(envelope.fadeInFrames), 1)
        XCTAssertEqual(envelope.at(total - 1 - envelope.fadeOutFrames), 1)
    }

    func testFadesGrowWithTheVideoUpToTheirFullLength() {
        var previous = MusicGain.envelope(totalFrames: 1, sampleRate: rate, volume: 1)
        for millis in [10, 100, 500, 1_000, 1_499, 1_500, 1_501, 5_000, 600_000] {
            let envelope = MusicGain.envelope(totalFrames: rate * millis / 1_000, sampleRate: rate, volume: 1)
            XCTAssertGreaterThanOrEqual(envelope.fadeInFrames, previous.fadeInFrames)
            XCTAssertGreaterThanOrEqual(envelope.fadeOutFrames, previous.fadeOutFrames)
            XCTAssertTrue(envelope.fadeInFrames <= 882 && envelope.fadeOutFrames <= 30_870)
            XCTAssertLessThan(envelope.fadeInFrames + envelope.fadeOutFrames, envelope.totalFrames)
            previous = envelope
        }
        XCTAssertEqual(MusicGain.envelope(totalFrames: rate * 3 / 2, sampleRate: rate, volume: 1).fadeOutFrames, 30_870)
    }

    func testDegenerateLengthsAreHandled() {
        let empty = MusicGain.envelope(totalFrames: 0, sampleRate: rate, volume: 1)
        XCTAssertEqual(empty.at(0), 0)
        XCTAssertEqual(empty.fadeOutFrames, 0)

        // One frame cannot fade; it simply plays.
        let single = MusicGain.envelope(totalFrames: 1, sampleRate: rate, volume: 0.6)
        XCTAssertEqual(single.at(0), 0.6)

        XCTAssertEqual(MusicGain.envelope(totalFrames: -5, sampleRate: rate, volume: 1).at(0), 0)
        XCTAssertEqual(MusicGain.envelope(totalFrames: 1_000, sampleRate: 0, volume: 1).at(10), 0)
    }

    func testOutsideTheRecordingIsSilent() {
        let envelope = MusicGain.envelope(totalFrames: tenSeconds, sampleRate: rate, volume: 1)
        XCTAssertEqual(envelope.at(-1), 0)
        XCTAssertEqual(envelope.at(tenSeconds), 0)
        XCTAssertEqual(envelope.at(tenSeconds + 1_000), 0)
    }

    func testVolumeIsClampedToZeroToOne() {
        XCTAssertEqual(MusicGain.gain(frame: tenSeconds / 2, totalFrames: tenSeconds, sampleRate: rate, volume: 3), 1)
        XCTAssertEqual(MusicGain.gain(frame: tenSeconds / 2, totalFrames: tenSeconds, sampleRate: rate, volume: -1), 0)
        XCTAssertEqual(MusicGain.gain(frame: tenSeconds / 2, totalFrames: tenSeconds, sampleRate: rate, volume: .nan), 0)
        XCTAssertEqual(MusicGain.gain(frame: tenSeconds / 2, totalFrames: tenSeconds, sampleRate: rate, volume: 0.25), 0.25)
    }

    func testAacTargetKeepsTheTwoRatesTheWriterIsAskedFor() {
        XCTAssertEqual(AacTarget.sampleRate(44_100), 44_100)
        XCTAssertEqual(AacTarget.sampleRate(48_000), 48_000)
        for rate in [4_000, 8_000, 22_050, 32_000, 37_800, 88_200, 96_000, 192_000] {
            XCTAssertEqual(AacTarget.sampleRate(rate), 44_100)
        }
    }

    func testAacBitRates() {
        XCTAssertEqual(AacTarget.bitRate(channels: 2), 160_000)
        XCTAssertEqual(AacTarget.bitRate(channels: 1), 96_000)
    }

    func testFrameCountsComeFromTheLengthOfTheVideo() {
        XCTAssertEqual(AacTarget.frames(durationMicros: 10_000_000, sampleRate: 44_100), 441_000)
        XCTAssertEqual(AacTarget.frames(durationMicros: 0, sampleRate: 44_100), 0)
        XCTAssertEqual(AacTarget.frames(durationMicros: -1, sampleRate: 44_100), 0)
        // 33 333 µs is 1469.98 frames: rounded, not cut.
        XCTAssertEqual(AacTarget.frames(durationMicros: 33_333, sampleRate: 44_100), 1_470)
        // Ten minutes of 384 kHz music still fit the arithmetic.
        XCTAssertEqual(AacTarget.frames(durationMicros: 600_000_000, sampleRate: 384_000), 230_400_000)
    }
}

/// A decoded track standing in for the real decoder: hands its samples out in small pieces.
private final class FakeTrack: RestartableSource {
    let channels: Int
    let sampleRate: Int
    private let samples: [Float]
    private let pieceFrames: Int
    private var position = 0
    var restarts = 0
    var reads = 0
    var closed = false
    /// A read or a restart after `close`, which the loop must never do.
    var usedAfterClose = false

    init(_ samples: [Float], channels: Int = 1, sampleRate: Int = 44_100, pieceFrames: Int = 100) {
        self.samples = samples
        self.channels = channels
        self.sampleRate = sampleRate
        self.pieceFrames = pieceFrames
    }

    func read(into out: inout [Float], maxFrames: Int) throws -> Int {
        if closed { usedAfterClose = true }
        reads += 1
        let frames = min(maxFrames, pieceFrames, samples.count / channels - position)
        for i in 0..<(frames * channels) {
            out[i] = samples[position * channels + i]
        }
        position += frames
        return frames
    }

    func restart() {
        if closed { usedAfterClose = true }
        restarts += 1
        position = 0
    }

    func close() {
        closed = true
    }
}

final class MusicStreamTests: XCTestCase {

    private func ramp(_ frames: Int) -> [Float] {
        (0..<frames).map { Float($0 + 1) / Float(frames + 1) }
    }

    private func constant(_ frames: Int, _ value: Float = 1) -> [Float] {
        [Float](repeating: value, count: frames)
    }

    /// Reads `frames` frames in requests of `request` frames, as a consumer with its own buffer size would.
    private func readAll(_ source: FrameSource, frames: Int, request: Int) throws -> [Float] {
        let channels = source.channels
        var result = [Float](repeating: 0, count: frames * channels)
        var piece = [Float](repeating: 0, count: request * channels)
        var done = 0
        while done < frames {
            let n = try source.read(into: &piece, maxFrames: min(request, frames - done))
            if n == 0 { break }
            for i in 0..<(n * channels) {
                result[done * channels + i] = piece[i]
            }
            done += n
        }
        return Array(result.prefix(done * channels))
    }

    private func renderAll(_ renderer: MusicRenderer, request: Int) throws -> [Int16] {
        let channels = renderer.channels
        var result = [Int16](repeating: 0, count: renderer.totalFrames * channels)
        var piece = [Int16](repeating: 0, count: request * channels)
        var done = 0
        while true {
            let n = try renderer.render(into: &piece, maxFrames: request)
            if n == 0 { break }
            for i in 0..<(n * channels) {
                result[done * channels + i] = piece[i]
            }
            done += n
        }
        XCTAssertEqual(done, renderer.totalFrames, "rendered frames")
        return result
    }

    /// Index of the first sample of `out` that is not `expected(index)`, or nil when all are.
    private func firstMismatch<T: Equatable>(_ out: [T], _ expected: (Int) -> T) -> Int? {
        for i in out.indices where out[i] != expected(i) {
            return i
        }
        return nil
    }

    // MARK: looping

    func testAShortTrackLoopsFromMemoryWithNothingLostAtTheSeam() throws {
        let track = ramp(7)
        let fake = FakeTrack(track)
        let loop = LoopingSource(fake)
        let out = try readAll(loop, frames: 30, request: 4)
        XCTAssertEqual(out.count, 30)
        XCTAssertNil(firstMismatch(out) { track[$0 % 7] })
        // Read once, then released: the loop runs from the cache.
        XCTAssertEqual(fake.restarts, 0)
        XCTAssertTrue(fake.closed)
        XCTAssertFalse(fake.usedAfterClose)
    }

    func testATrackTooLongForTheCacheIsReadAgainForEveryPass() throws {
        let track = ramp(7)
        let fake = FakeTrack(track)
        let loop = LoopingSource(fake, cacheLimitSamples: 5)
        let out = try readAll(loop, frames: 30, request: 4)
        XCTAssertNil(firstMismatch(out) { track[$0 % 7] })
        XCTAssertEqual(fake.restarts, 4)
        XCTAssertFalse(fake.closed)
        loop.close()
        XCTAssertTrue(fake.closed)
    }

    func testLoopingWorksWithTheCacheSwitchedOff() throws {
        let track = ramp(250)
        let fake = FakeTrack(track)
        let out = try readAll(LoopingSource(fake, cacheLimitSamples: 0), frames: 1_000, request: 333)
        XCTAssertEqual(out.count, 1_000)
        XCTAssertNil(firstMismatch(out) { track[$0 % 250] })
        XCTAssertEqual(fake.restarts, 3)
    }

    func testACachedStereoTrackLongerThanOneCacheBlockLoopsExactly() throws {
        let frames = 70_000 // 140 000 samples: more than two cache blocks
        let track: [Float] = (0..<(frames * 2)).map { index -> Float in
            let frame = index / 2
            if index % 2 == 0 { return Float(frame % 1_000) / 1_000 }
            return -Float(frame % 777) / 777
        }
        let fake = FakeTrack(track, channels: 2, pieceFrames: 1_500)
        let loop = LoopingSource(fake)
        let out = try readAll(loop, frames: frames * 3 + 123, request: 4_096)
        XCTAssertEqual(out.count, (frames * 3 + 123) * 2)
        XCTAssertNil(firstMismatch(out) { track[$0 % track.count] })
        XCTAssertEqual(fake.restarts, 0)
    }

    func testAnEmptyTrackEndsTheLoopInsteadOfSpinning() throws {
        let fake = FakeTrack([])
        let loop = LoopingSource(fake)
        var buffer = [Float](repeating: 0, count: 16)
        let first = try loop.read(into: &buffer, maxFrames: 16)
        let second = try loop.read(into: &buffer, maxFrames: 16)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(fake.restarts, 0)
    }

    func testALoopKeepsTheFormatOfItsTrack() {
        let loop = LoopingSource(FakeTrack(ramp(4), channels: 2, sampleRate: 22_050))
        XCTAssertEqual(loop.channels, 2)
        XCTAssertEqual(loop.sampleRate, 22_050)
    }

    // MARK: rendering

    func testALoopedTrackIsCutToExactlyTheLengthOfTheVideo() throws {
        let total = 10 * 44_100
        for limit in [LoopingSource.defaultCacheSamples, 0] {
            let fake = FakeTrack(constant(1_000))
            let renderer = MusicRenderer(source: LoopingSource(fake, cacheLimitSamples: limit), totalFrames: total, volume: 0.5)
            let out = try renderAll(renderer, request: 4_096)
            XCTAssertEqual(out.count, total)
            XCTAssertTrue(renderer.isComplete)
            XCTAssertEqual(renderer.position, total)
            var rest = [Int16](repeating: 0, count: 16)
            let afterTheEnd = try renderer.render(into: &rest, maxFrames: 16)
            XCTAssertEqual(afterTheEnd, 0)
        }
    }

    func testThereIsNoFadeAtLoopSeamsOnlyAtTheVeryStartAndEnd() throws {
        let total = 10 * 44_100
        // A constant track: every sample between the two fades must be the plain volume, seam or not.
        let renderer = MusicRenderer(source: LoopingSource(FakeTrack(constant(1_000))), totalFrames: total, volume: 0.5)
        let out = try renderAll(renderer, request: 1_000)
        let envelope = MusicGain.envelope(totalFrames: total, sampleRate: 44_100, volume: 0.5)
        let firstFull = envelope.fadeInFrames
        let lastFull = total - 1 - envelope.fadeOutFrames
        XCTAssertGreaterThan(lastFull - firstFull, 400 * 1_000) // hundreds of seams in between
        XCTAssertNil(firstMismatch(Array(out[firstFull...lastFull])) { _ in 16_384 })
        XCTAssertEqual(out[0], 0)
        XCTAssertEqual(out[out.count - 1], 0)
        XCTAssertLessThan(out[firstFull - 1], 16_384)
        XCTAssertLessThan(out[lastFull + 2_000], 16_384)
        var monotonic = true
        for i in 1..<firstFull where out[i] < out[i - 1] { monotonic = false }
        for i in (lastFull + 1)..<out.count where out[i] > out[i - 1] { monotonic = false }
        XCTAssertTrue(monotonic)
    }

    func testTheMusicItselfRepeatsUnchangedUnderTheEnvelope() throws {
        let total = 5 * 44_100
        let track: [Float] = (0..<441).map { Float($0 - 220) / 441 }
        let renderer = MusicRenderer(source: LoopingSource(FakeTrack(track)), totalFrames: total, volume: 1)
        let out = try renderAll(renderer, request: 3_000)
        let envelope = MusicGain.envelope(totalFrames: total, sampleRate: 44_100, volume: 1)
        XCTAssertNil(firstMismatch(out) { Pcm.toPcm16(track[$0 % 441] * envelope.at($0)) })
    }

    func testStereoIsRenderedInterleavedWithTheSameGainOnBothSides() throws {
        let track: [Float] = (0..<200).map { $0 % 2 == 0 ? 0.5 : -0.25 }
        let renderer = MusicRenderer(source: LoopingSource(FakeTrack(track, channels: 2)), totalFrames: 44_100 * 4, volume: 1)
        let out = try renderAll(renderer, request: 512)
        XCTAssertEqual(out.count, 44_100 * 4 * 2)
        let middle = 44_100 * 2
        XCTAssertEqual(out[middle * 2], 16_384)
        XCTAssertEqual(out[middle * 2 + 1], -8_192)
        XCTAssertEqual(out[0], 0)
        XCTAssertEqual(out[1], 0)
    }

    func testAVideoShorterThanTheFadesStillGetsItsExactLength() throws {
        for total in [1, 2, 100, 4_410, 30_000] {
            let renderer = MusicRenderer(source: LoopingSource(FakeTrack(constant(64))), totalFrames: total, volume: 1)
            let out = try renderAll(renderer, request: 4_096)
            XCTAssertEqual(out.count, total)
            XCTAssertFalse(out.contains { $0 < 0 })
            if total >= 100 {
                XCTAssertEqual(out[0], 0)
                XCTAssertEqual(out[out.count - 1], 0)
                XCTAssertEqual(out.max(), 32_767, "full volume is still reached")
            }
        }
    }

    func testAVideoWithNoLengthRendersNothingAndTouchesNothing() throws {
        let fake = FakeTrack(constant(100))
        let renderer = MusicRenderer(source: LoopingSource(fake), totalFrames: 0, volume: 1)
        XCTAssertTrue(renderer.isComplete)
        var out = [Int16](repeating: 0, count: 64)
        let rendered = try renderer.render(into: &out, maxFrames: 64)
        XCTAssertEqual(rendered, 0)
        XCTAssertEqual(fake.reads, 0)
    }

    func testATrackWithNoAudioFailsTheRenderInsteadOfProducingSilence() {
        let renderer = MusicRenderer(source: LoopingSource(FakeTrack([])), totalFrames: 1_000, volume: 1)
        var out = [Int16](repeating: 0, count: 256)
        do {
            _ = try renderer.render(into: &out, maxFrames: 256)
            XCTFail("a track without audio was rendered")
        } catch {
            XCTAssertEqual(error as? MusicStreamError, .noAudio)
        }
    }

    func testARequestSmallerThanWhatIsLeftIsHonoured() throws {
        let renderer = MusicRenderer(source: LoopingSource(FakeTrack(ramp(50))), totalFrames: 1_000, volume: 1)
        var small = [Int16](repeating: 0, count: 10)
        let firstPiece = try renderer.render(into: &small, maxFrames: 10)
        XCTAssertEqual(firstPiece, 10)
        XCTAssertEqual(renderer.position, 10)
        var large = [Int16](repeating: 0, count: 2_000)
        let secondPiece = try renderer.render(into: &large, maxFrames: 2_000)
        XCTAssertEqual(secondPiece, 990)
        XCTAssertTrue(renderer.isComplete)
    }

    func testTenMinutesUnderAFiveMinuteSongKeepsOnlyTheCacheLimitInMemory() throws {
        // A "song" far beyond the cache limit, streamed: the loop must restart it instead of holding it.
        let songFrames = 300_000
        let song: [Float] = (0..<songFrames).map { Float($0 % 100) / 100 }
        let fake = FakeTrack(song, pieceFrames: 4_096)
        let loop = LoopingSource(fake, cacheLimitSamples: 100_000)
        let total = songFrames * 2 + 50_000
        let renderer = MusicRenderer(source: loop, totalFrames: total, volume: 1)
        var piece = [Int16](repeating: 0, count: 4_096)
        var frames = 0
        while true {
            let n = try renderer.render(into: &piece, maxFrames: 4_096)
            if n == 0 { break }
            frames += n
        }
        XCTAssertEqual(frames, total)
        XCTAssertEqual(fake.restarts, 2)
        XCTAssertFalse(fake.closed)
    }
}

final class MusicPcmTests: XCTestCase {

    /// One frame of planar audio, one value per channel, mixed to `outChannels`.
    private func mix(_ frame: [Float], to outChannels: Int) -> [Float] {
        var out = [Float](repeating: 0, count: outChannels)
        let frames = Pcm.interleave(frames: 1, sourceChannels: frame.count, outChannels: outChannels, into: &out) { channel, _ in
            frame[channel]
        }
        XCTAssertEqual(frames, 1)
        return out
    }

    private func assertClose(_ actual: [Float], _ expected: [Float], _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, message, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: 1e-6, message, line: line)
        }
    }

    func testPlanarChannelsAreInterleavedFrameByFrame() {
        let left: [Float] = [0.25, -0.5, 1]
        let right: [Float] = [0, 0.5, -1]
        var out = [Float](repeating: 9, count: 8)
        let frames = Pcm.interleave(frames: 3, sourceChannels: 2, outChannels: 2, into: &out) { channel, frame in
            channel == 0 ? left[frame] : right[frame]
        }
        XCTAssertEqual(frames, 3)
        XCTAssertEqual(Array(out.prefix(6)), [0.25, 0, -0.5, 0.5, 1, -1])
        // Nothing past the frames that were asked for is touched.
        XCTAssertEqual(Array(out.suffix(2)), [9, 9])
    }

    func testNonFiniteValuesBecomeSilence() {
        XCTAssertEqual(mix([.nan], to: 1), [0])
        XCTAssertEqual(mix([.infinity, -.infinity], to: 2), [0, 0])
        XCTAssertEqual(mix([-1.5], to: 1), [-1.5])
    }

    func testMonoIsCopiedToBothSidesWhenStereoIsAsked() {
        XCTAssertEqual(mix([0.25], to: 2), [0.25, 0.25])
    }

    func testStereoKeepsItsSides() {
        XCTAssertEqual(mix([0.5, -0.5], to: 2), [0.5, -0.5])
    }

    func testStereoIsAveragedWhenMonoIsAsked() {
        XCTAssertEqual(mix([1, 0], to: 1), [0.5])
        XCTAssertEqual(mix([0.5, -0.5], to: 1), [0])
    }

    func testFivePointOneIsMixedDownToStereo() {
        let front: Float = 1 / (1 + 2 * 0.70710678)
        let side: Float = 0.70710678 * front
        assertClose(mix([1, 0, 0, 0, 0, 0], to: 2), [front, 0], "front left")
        assertClose(mix([0, 0, 1, 0, 0, 0], to: 2), [side, side], "centre goes to both sides")
        XCTAssertEqual(mix([0, 0, 0, 1, 0, 0], to: 2), [0, 0], "effects channel is left out")
        assertClose(mix([0, 0, 0, 0, 0, 1], to: 2), [0, side], "back right")
        assertClose(mix([1, 1, 1, 1, 1, 1], to: 2), [1, 1], "full scale everywhere does not clip")
    }

    func testOtherLayoutsAreMixedDownToo() {
        let front: Float = 1 / 1.70710678
        let side: Float = 0.70710678 / 1.70710678

        // Three channels: left, right, centre.
        assertClose(mix([0, 0, 1], to: 2), [side, side])

        // Four channels: front pair and back pair, no centre.
        assertClose(mix([1, 0, 0, 0], to: 2), [front, 0])
        assertClose(mix([0, 0, 1, 0], to: 2), [side, 0])
        assertClose(mix([0, 0, 0, 1], to: 2), [0, side])

        // 7.1 at full scale still lands on full scale.
        assertClose(mix([1, 1, 1, 1, 1, 1, 1, 1], to: 2), [1, 1])
    }

    func testSurroundCanBeMixedAllTheWayToMono() {
        assertClose(mix([1, 1, 1, 1, 1, 1], to: 1), [1])
    }

    func testLayoutsTheMixerDoesNotTakeGiveNoFrames() {
        var out = [Float](repeating: 0, count: 4)
        XCTAssertEqual(Pcm.interleave(frames: 0, sourceChannels: 2, outChannels: 2, into: &out) { _, _ in 1 }, 0)
        XCTAssertEqual(Pcm.interleave(frames: 1, sourceChannels: 0, outChannels: 1, into: &out) { _, _ in 1 }, 0)
        XCTAssertEqual(Pcm.interleave(frames: 1, sourceChannels: 17, outChannels: 2, into: &out) { _, _ in 1 }, 0)
        XCTAssertEqual(Pcm.interleave(frames: 1, sourceChannels: 2, outChannels: 3, into: &out) { _, _ in 1 }, 0)
        // An output that is too small is refused, not overrun.
        XCTAssertEqual(Pcm.interleave(frames: 3, sourceChannels: 2, outChannels: 2, into: &out) { _, _ in 1 }, 0)
        XCTAssertEqual(out, [0, 0, 0, 0])
    }

    func testFloatToSixteenBitRoundsAndClips() {
        XCTAssertEqual(Pcm.toPcm16(0), 0)
        XCTAssertEqual(Pcm.toPcm16(1), 32_767)
        XCTAssertEqual(Pcm.toPcm16(-1), -32_767)
        XCTAssertEqual(Pcm.toPcm16(0.5), 16_384)
        XCTAssertEqual(Pcm.toPcm16(2), 32_767)
        XCTAssertEqual(Pcm.toPcm16(-2), -32_768)
        XCTAssertEqual(Pcm.toPcm16(.infinity), 32_767)
        XCTAssertEqual(Pcm.toPcm16(-.infinity), -32_768)
        XCTAssertEqual(Pcm.toPcm16(.nan), 0)
    }

    func testMonoStaysMonoAndEverythingElseBecomesStereo() {
        XCTAssertEqual(Pcm.outputChannels(1), 1)
        XCTAssertEqual(Pcm.outputChannels(2), 2)
        XCTAssertEqual(Pcm.outputChannels(6), 2)
    }
}
