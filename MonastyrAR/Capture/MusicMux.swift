import AVFoundation
import CoreMedia
import Foundation
import StageCore

/// Writes a backing track into a recorded video. The iOS counterpart of `capture/AudioMux.kt`, and built the same
/// way: the music is added to the finished file, the picture is copied as it is and the music becomes the file's
/// only audio track.
///
/// Why after the take and not as a second input of the recorder's own asset writer:
///  - the fade-out has to end on the last frame, and while a take runs nobody knows which frame that will be;
///  - a writer that fails takes the whole file with it. Here a track that cannot be decoded or encoded costs
///    only the music: the take itself is already closed and stays untouched;
///  - nothing extra runs during the take, when the render thread and the video encoder are busiest.
///
/// Why an asset reader and writer and not `AVAssetExportSession`: the pass-through export preset copies tracks
/// but cannot loop, fade or scale the music, and every other preset encodes the picture a second time. With a
/// reader that hands out the stored H.264 samples and a writer input without output settings the picture is
/// copied sample for sample, and the music is rendered by the same tested code as on Android (`LoopingSource`,
/// `MusicRenderer`, `MusicGain` in StageCore) and encoded to AAC by the writer.
enum MusicMux {

    static let outputPrefix = "music-"
    static let outputSuffix = ".mp4"

    private static let queue = DispatchQueue(label: "farm.monastyr2.ar.musicmux", qos: .userInitiated)
    private static let feedFrames = 4_096
    private static let pollSeconds = 0.002

    /// Idle polls in a row before the writer is given up on; each waits `pollSeconds`, so 15 seconds. Counted in
    /// polls, not on the clock: the clock also runs while the app is suspended in the background.
    private static let stallPolls = 7_500

    enum Failure: Error {
        case noVideo
        case noLength
        case reader
        case writer
        case encoder
        case buffer
        case stalled
    }

    /// Makes a copy of `video` in the temporary folder with `track` as its sound: the video samples are copied
    /// one for one (same time stamps and orientation, no re-encoding), and the music is looped to the length of
    /// the video, cut at its end, scaled by `volume` (0...1), given a 20 ms fade-in and a 700 ms fade-out, and
    /// encoded as AAC-LC.
    ///
    /// Neither the video nor the music is ever held decoded in memory beyond one loop of a short track.
    ///
    /// - Returns: the new file, or nil when the music could not be added; nothing is left behind then and
    ///   `video` is untouched either way.
    static func addMusic(to video: URL, track: MusicTrack, volume: Float) async -> URL? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(outputPrefix)\(UUID().uuidString)\(outputSuffix)", isDirectory: false)
        do {
            try await mux(video: video, music: track.url, volume: volume, output: output)
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 0 { return output }
        } catch {
            // Whatever the picked file or the encoder did, the recording itself must survive it.
            NSLog("MusicMux: could not add \"%@\" to %@: %@", track.title, video.lastPathComponent, String(describing: error))
        }
        try? FileManager.default.removeItem(at: output)
        return nil
    }

    /// Removes the partial outputs of a process that was killed while it was writing one: every output last
    /// written before `date`. Called once at launch with the launch time, so nothing it finds can be in use.
    static func removeOutputs(olderThan date: Date) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        )) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(outputPrefix), name.hasSuffix(outputSuffix) else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified >= date { continue }
            try? fm.removeItem(at: entry)
        }
    }

    private static func mux(video: URL, music: URL, volume: Float, output: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let timeRange = try await videoTrack.load(.timeRange)
        let formats = try await videoTrack.load(.formatDescriptions)
        let transform = try await videoTrack.load(.preferredTransform)
        guard let format = formats.first else { throw Failure.noVideo }
        let end = timeRange.end
        guard end.isValid, CMTimeGetSeconds(end) > 0 else { throw Failure.noLength }

        let job = MuxJob(
            asset: asset, videoTrack: videoTrack, videoFormat: format, transform: transform, end: end,
            music: music, volume: volume, output: output
        )
        // The copy loop blocks while it waits for the writer, so it gets a thread of its own.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try job.run()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One pass of copying the picture and writing the music. Used once, on the mux queue.
    private final class MuxJob: @unchecked Sendable {
        private let asset: AVAsset
        private let videoTrack: AVAssetTrack
        private let videoFormat: CMFormatDescription
        private let transform: CGAffineTransform
        private let end: CMTime
        private let music: URL
        private let volume: Float
        private let output: URL

        init(
            asset: AVAsset, videoTrack: AVAssetTrack, videoFormat: CMFormatDescription, transform: CGAffineTransform,
            end: CMTime, music: URL, volume: Float, output: URL
        ) {
            self.asset = asset
            self.videoTrack = videoTrack
            self.videoFormat = videoFormat
            self.transform = transform
            self.end = end
            self.music = music
            self.volume = volume
            self.output = output
        }

        func run() throws {
            // The music first: a track that cannot be opened must not get as far as creating a file.
            let decoder = try TrackDecoder(url: music)
            let loop = LoopingSource(decoder)
            defer { loop.close() }
            let channels = loop.channels
            let rate = loop.sampleRate
            let micros = CMTimeConvertScale(end, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
            let totalFrames = AacTarget.frames(durationMicros: micros, sampleRate: rate)
            guard totalFrames > 0 else { throw Failure.noLength }
            let renderer = MusicRenderer(source: loop, totalFrames: totalFrames, volume: volume)

            let reader = try AVAssetReader(asset: asset)
            // No output settings: the samples come out as they are stored, still compressed.
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            guard reader.canAdd(videoOutput) else { throw Failure.reader }
            reader.add(videoOutput)

            let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            // No output settings here either: what is appended is written as it is. An MPEG-4 file then needs to
            // be told the format up front.
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
            videoInput.expectsMediaDataInRealTime = false
            videoInput.transform = transform
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AacTarget.sampleRate(rate),
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: AacTarget.bitRate(channels: channels),
            ]
            // Asked first, because an input made with settings the writer cannot apply raises an exception.
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else { throw Failure.encoder }
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw Failure.writer }
            writer.add(videoInput)
            writer.add(audioInput)

            // 16-bit interleaved PCM in the byte order of the device, which is what `MusicRenderer` hands out.
            var description = AudioStreamBasicDescription(
                mSampleRate: Float64(rate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(2 * channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(2 * channels),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 16,
                mReserved: 0
            )
            var createdFormat: CMAudioFormatDescription?
            let formatStatus = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &createdFormat
            )
            guard formatStatus == noErr, let pcmFormat = createdFormat else { throw Failure.buffer }

            guard reader.startReading() else { throw reader.error ?? Failure.reader }
            guard writer.startWriting() else {
                reader.cancelReading()
                throw writer.error ?? Failure.writer
            }
            // The take starts at zero on its own time line, and so does the music.
            writer.startSession(atSourceTime: .zero)

            do {
                try copy(
                    from: reader, videoOutput: videoOutput, to: writer, videoInput: videoInput, audioInput: audioInput,
                    renderer: renderer, pcmFormat: pcmFormat
                )
            } catch {
                reader.cancelReading()
                writer.cancelWriting()
                throw error
            }

            // A writer that failed after the last append must not be asked to end its session.
            guard writer.status == .writing else {
                reader.cancelReading()
                throw writer.error ?? Failure.writer
            }
            // The file ends with the picture, whatever the encoder padded its last packet with.
            writer.endSession(atSourceTime: end)
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            finished.wait()
            guard writer.status == .completed else { throw writer.error ?? Failure.writer }
        }

        /// Feeds both tracks to the writer until the video and the music are through. The writer says which of
        /// the two it wants next (`isReadyForMoreMediaData`), which keeps them interleaved in the file.
        private func copy(
            from reader: AVAssetReader,
            videoOutput: AVAssetReaderTrackOutput,
            to writer: AVAssetWriter,
            videoInput: AVAssetWriterInput,
            audioInput: AVAssetWriterInput,
            renderer: MusicRenderer,
            pcmFormat: CMAudioFormatDescription
        ) throws {
            let channels = renderer.channels
            let timescale = CMTimeScale(renderer.sampleRate)
            var samples = [Int16](repeating: 0, count: MusicMux.feedFrames * channels)
            var videoDone = false
            var audioDone = false
            var idlePolls = 0

            while !(videoDone && audioDone) {
                guard writer.status == .writing else { throw writer.error ?? Failure.writer }
                var progressed = false

                if !videoDone, videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        // A buffer without samples only carries markers; the writer has no use for it.
                        if CMSampleBufferGetNumSamples(sample) > 0, !videoInput.append(sample) {
                            throw writer.error ?? Failure.writer
                        }
                    } else {
                        guard reader.status == .completed else { throw reader.error ?? Failure.reader }
                        videoInput.markAsFinished()
                        videoDone = true
                    }
                    progressed = true
                }

                if !audioDone, audioInput.isReadyForMoreMediaData {
                    // The time stamp comes from the frame count, so it cannot drift.
                    let time = CMTime(value: CMTimeValue(renderer.position), timescale: timescale)
                    let frames = try renderer.render(into: &samples, maxFrames: MusicMux.feedFrames)
                    if frames > 0 {
                        let buffer = try MuxJob.sampleBuffer(samples, frames: frames, channels: channels, format: pcmFormat, time: time)
                        if !audioInput.append(buffer) { throw writer.error ?? Failure.writer }
                    }
                    if renderer.isComplete {
                        audioInput.markAsFinished()
                        audioDone = true
                    }
                    progressed = true
                }

                if progressed {
                    idlePolls = 0
                } else {
                    idlePolls += 1
                    if idlePolls > MusicMux.stallPolls { throw Failure.stalled }
                    Thread.sleep(forTimeInterval: MusicMux.pollSeconds)
                }
            }
        }

        /// The first `frames` frames of `samples` as a sample buffer that starts at `time`.
        private static func sampleBuffer(
            _ samples: [Int16], frames: Int, channels: Int, format: CMAudioFormatDescription, time: CMTime
        ) throws -> CMSampleBuffer {
            let byteCount = frames * channels * MemoryLayout<Int16>.size
            var createdBlock: CMBlockBuffer?
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &createdBlock
            )
            guard blockStatus == noErr, let block = createdBlock else { throw Failure.buffer }
            let copyStatus = samples.withUnsafeBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress, bytes.count >= byteCount else { return -1 }
                return CMBlockBufferReplaceDataBytes(
                    with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount
                )
            }
            guard copyStatus == noErr else { throw Failure.buffer }
            var createdSample: CMSampleBuffer?
            let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil,
                sampleBufferOut: &createdSample
            )
            guard sampleStatus == noErr, let sample = createdSample else { throw Failure.buffer }
            return sample
        }
    }
}
