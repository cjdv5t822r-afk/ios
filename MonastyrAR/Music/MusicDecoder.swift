import AVFoundation
import Foundation
import StageCore

enum MusicDecoderError: Error {
    /// Core Audio opened the file, but what it decodes to is not something the mixer takes.
    case unsupportedFormat
    case closed
}

/// One pass through the audio of a track as interleaved float frames, decoded as it is read: one buffer of
/// `chunkFrames` frames is held at a time, whatever the length of the track. The iOS counterpart of
/// `music/MusicDecoder.kt`, on `AVAudioFile` instead of MediaExtractor + MediaCodec.
///
/// `AVAudioFile` hands every format out as planar 32-bit float at the file's own sample rate, so there is one
/// path for WAV, MP3, AAC and the rest. More than two channels are mixed down as they are read.
///
/// Not thread-safe. The initializer throws when the track cannot be opened.
final class TrackDecoder: RestartableSource {

    private static let chunkFrames: AVAudioFrameCount = 8_192

    let sampleRate: Int

    /// 1 for a mono track, otherwise 2.
    let channels: Int

    private var file: AVAudioFile?
    private let buffer: AVAudioPCMBuffer
    private let sourceChannels: Int
    private var framesThisPass = 0

    init(url: URL) throws {
        let opened = try AVAudioFile(forReading: url)
        let format = opened.processingFormat
        let rate = Int(format.sampleRate.rounded())
        let count = Int(format.channelCount)
        guard MusicRules.isSupportedFormat(sampleRate: rate, channels: count),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: TrackDecoder.chunkFrames)
        else { throw MusicDecoderError.unsupportedFormat }
        file = opened
        buffer = pcm
        sourceChannels = count
        sampleRate = rate
        channels = Pcm.outputChannels(count)
    }

    func read(into out: inout [Float], maxFrames: Int) throws -> Int {
        guard let file else { throw MusicDecoderError.closed }
        if maxFrames <= 0 { return 0 }
        let remaining = file.length - file.framePosition
        if remaining <= 0 { return 0 }
        let wanted = min(Int64(min(maxFrames, Int(TrackDecoder.chunkFrames))), remaining)
        buffer.frameLength = 0
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(wanted))
        } catch {
            // A compressed file can end a little before the length its header promised. That is the end of this
            // pass, not a failure; a file that gives nothing at all is one.
            if framesThisPass > 0 { return 0 }
            throw error
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return 0 }
        let written = Pcm.interleave(frames: frames, sourceChannels: sourceChannels, outChannels: channels, into: &out) { channel, frame in
            data[channel][frame]
        }
        framesThisPass += written
        return written
    }

    func restart() throws {
        guard let file else { throw MusicDecoderError.closed }
        file.framePosition = 0
        framesThisPass = 0
    }

    func close() {
        file = nil
    }
}
