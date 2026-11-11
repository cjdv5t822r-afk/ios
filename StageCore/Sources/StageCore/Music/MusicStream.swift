import Foundation

public enum MusicStreamError: Error, Equatable, Sendable {
    /// The source ran dry, which an endless loop only does for a track with no audio in it.
    case noAudio
}

/// A stream of interleaved float frames (one sample per channel), nominally in -1...1.
public protocol FrameSource: AnyObject {
    var sampleRate: Int { get }
    var channels: Int { get }

    /// Writes up to `maxFrames` frames at the start of `out`, which has room for them. Returns how many were
    /// written; 0 means the stream has ended.
    func read(into out: inout [Float], maxFrames: Int) throws -> Int
}

/// A finite source that can be played again from its first frame. `close` may be called more than once.
public protocol RestartableSource: FrameSource {
    func restart() throws
    func close()
}

/// Plays `inner` over and over, seam to seam, with nothing lost or added between the last frame of one pass and
/// the first frame of the next. It only ends when a whole pass holds no frames at all.
///
/// A track of up to `cacheLimitSamples` samples is kept in memory after its first pass and `inner` is closed;
/// a longer one is read again for every pass, so memory use does not grow with the track.
/// Port of `LoopingSource` in `music/MusicStream.kt`.
public final class LoopingSource: FrameSource {

    /// 16 MB of float samples: about 47 s of 44.1 kHz stereo.
    public static let defaultCacheSamples = 16 * 1024 * 1024 / MemoryLayout<Float>.size
    fileprivate static let chunkSamples = 1 << 16

    public let sampleRate: Int
    public let channels: Int

    private let inner: RestartableSource
    private var recording: SampleCache?
    private var cache: SampleCache?
    private var cachePosition = 0
    private var framesThisPass = 0

    public init(_ inner: RestartableSource, cacheLimitSamples: Int = LoopingSource.defaultCacheSamples) {
        self.inner = inner
        sampleRate = inner.sampleRate
        channels = inner.channels
        recording = cacheLimitSamples > 0 ? SampleCache(limit: cacheLimitSamples) : nil
    }

    public func read(into out: inout [Float], maxFrames: Int) throws -> Int {
        if maxFrames <= 0 { return 0 }
        if let cache { return readCached(cache, into: &out, maxFrames: maxFrames) }
        var frames = try inner.read(into: &out, maxFrames: maxFrames)
        if frames == 0 {
            if framesThisPass == 0 { return 0 }
            if let firstPass = recording {
                recording = nil
                cache = firstPass
                inner.close()
                return readCached(firstPass, into: &out, maxFrames: maxFrames)
            }
            try inner.restart()
            framesThisPass = 0
            frames = try inner.read(into: &out, maxFrames: maxFrames)
            if frames == 0 { return 0 }
        }
        framesThisPass += frames
        if let firstPass = recording, !firstPass.append(out, count: frames * channels) {
            recording = nil
        }
        return frames
    }

    public func close() {
        recording = nil
        cache = nil
        inner.close()
    }

    private func readCached(_ cache: SampleCache, into out: inout [Float], maxFrames: Int) -> Int {
        let wanted = maxFrames * channels
        var done = 0
        while done < wanted {
            let copied = cache.copy(from: cachePosition, into: &out, targetOffset: done, count: wanted - done)
            done += copied
            cachePosition += copied
            if cachePosition == cache.size { cachePosition = 0 }
        }
        return maxFrames
    }
}

/// Samples in fixed-size pieces, so growing never copies and the limit is the real memory bound.
private final class SampleCache {
    private let limit: Int
    private var chunks: [[Float]] = []
    private(set) var size = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// False (and emptied) when `count` more samples do not fit under the limit.
    func append(_ source: [Float], count: Int) -> Bool {
        if count > limit - size {
            chunks.removeAll()
            size = 0
            return false
        }
        let chunkSamples = LoopingSource.chunkSamples
        var copied = 0
        while copied < count {
            let offset = size % chunkSamples
            if offset == 0 { chunks.append([Float](repeating: 0, count: chunkSamples)) }
            let n = min(chunkSamples - offset, count - copied)
            let chunk = size / chunkSamples
            for i in 0..<n {
                chunks[chunk][offset + i] = source[copied + i]
            }
            copied += n
            size += n
        }
        return true
    }

    /// Copies up to `count` samples starting at sample `from` (which is below `size`); returns how many.
    func copy(from: Int, into target: inout [Float], targetOffset: Int, count: Int) -> Int {
        let chunkSamples = LoopingSource.chunkSamples
        let offset = from % chunkSamples
        let n = min(chunkSamples - offset, count, size - from)
        let chunk = from / chunkSamples
        for i in 0..<n {
            target[targetOffset + i] = chunks[chunk][offset + i]
        }
        return n
    }
}

/// Turns an endless `source` into exactly `totalFrames` frames of 16-bit PCM with the `MusicGain` envelope
/// applied: the music cut to the length of the video. Port of `MusicRenderer` in `music/MusicStream.kt`, without
/// its silent tail (the asset writer's AAC encoder does not swallow the end of the track).
public final class MusicRenderer {

    public let totalFrames: Int
    public let sampleRate: Int
    public let channels: Int

    private let source: FrameSource
    private let envelope: MusicGain.Envelope
    private var scratch: [Float] = []

    /// Frames rendered so far.
    public private(set) var position = 0

    public init(source: FrameSource, totalFrames: Int, volume: Float) {
        self.source = source
        self.totalFrames = totalFrames
        sampleRate = source.sampleRate
        channels = source.channels
        envelope = MusicGain.envelope(totalFrames: totalFrames, sampleRate: source.sampleRate, volume: volume)
    }

    public var isComplete: Bool { position >= totalFrames }

    /// Writes the next frames (at most `maxFrames`) at the start of `out` and returns how many; 0 once the whole
    /// length has been rendered.
    /// - Throws: `MusicStreamError.noAudio` when the source runs dry, or whatever the source itself throws.
    public func render(into out: inout [Int16], maxFrames: Int) throws -> Int {
        let wanted = min(maxFrames, totalFrames - position)
        if wanted <= 0 { return 0 }
        if scratch.count < wanted * channels { scratch = [Float](repeating: 0, count: wanted * channels) }
        var done = 0
        while done < wanted {
            let frames = try source.read(into: &scratch, maxFrames: wanted - done)
            if frames <= 0 { throw MusicStreamError.noAudio }
            for frame in 0..<frames {
                let gain = envelope.at(position + frame)
                for channel in 0..<channels {
                    out[(done + frame) * channels + channel] = Pcm.toPcm16(scratch[frame * channels + channel] * gain)
                }
            }
            done += frames
            position += frames
        }
        return wanted
    }
}

/// Sample conversions between what a decoder hands out and what the mixer works on.
/// The parts of `music/MusicPcm.kt` that apply to Core Audio, which always decodes to planar 32-bit float.
public enum Pcm {

    /// Mono stays mono; everything else becomes stereo.
    public static func outputChannels(_ sourceChannels: Int) -> Int {
        sourceChannels <= 1 ? 1 : 2
    }

    /// A float sample as 16-bit PCM, rounded and clipped to the 16-bit range.
    public static func toPcm16(_ value: Float) -> Int16 {
        if value.isNaN { return 0 }
        let scaled = value * 32_767
        if scaled >= 32_767 { return 32_767 }
        if scaled <= -32_768 { return -32_768 }
        // Halves round up, as on Android.
        return Int16((scaled + 0.5).rounded(.down))
    }

    /// Turns `frames` frames of planar audio (`sample(channel, frame)`, one call per sample) into interleaved
    /// frames of `outChannels` channels (1 or 2) at the start of `out`. More than two source channels are mixed
    /// down; values that are not finite become silence, because a float file can hold anything. Returns the
    /// number of frames written: 0 when the layout is not one the mixer takes or `out` is too small.
    public static func interleave(
        frames: Int,
        sourceChannels: Int,
        outChannels: Int,
        into out: inout [Float],
        sample: (_ channel: Int, _ frame: Int) -> Float
    ) -> Int {
        guard frames > 0, sourceChannels >= 1, sourceChannels <= MusicRules.maxSourceChannels,
              outChannels == 1 || outChannels == 2, out.count >= frames * outChannels
        else { return 0 }
        let downmix = sourceChannels > 2 ? Downmix(channels: sourceChannels) : nil
        for frame in 0..<frames {
            var left: Float = 0
            var right: Float = 0
            if let downmix {
                for channel in 0..<sourceChannels {
                    let value = finite(sample(channel, frame))
                    left += value * downmix.left[channel]
                    right += value * downmix.right[channel]
                }
            } else {
                left = finite(sample(0, frame))
                right = sourceChannels == 2 ? finite(sample(1, frame)) : left
            }
            if outChannels == 1 {
                out[frame] = (left + right) * 0.5
            } else {
                out[frame * 2] = left
                out[frame * 2 + 1] = right
            }
        }
        return frames
    }

    private static func finite(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }
}

/// Weights that fold a surround layout into stereo, for the channel orders decoders use (front left, front right,
/// centre, low-frequency effects, then the surrounds in left / right pairs). The centre and the surrounds go in
/// 3 dB down, the effects channel is left out, and each side is normalised so full scale in stays full scale out.
public struct Downmix: Equatable, Sendable {
    public let left: [Float]
    public let right: [Float]

    private static let minus3dB: Float = 0.70710678

    public init(channels: Int) {
        let count = max(channels, 0)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        let hasCentre = count == 3 || count >= 5
        let hasEffects = count >= 6
        let firstSurround = 2 + (hasCentre ? 1 : 0) + (hasEffects ? 1 : 0)
        for channel in 0..<count {
            if channel == 0 {
                left[channel] = 1
            } else if channel == 1 {
                right[channel] = 1
            } else if channel == 2 && hasCentre {
                left[channel] = Downmix.minus3dB
                right[channel] = Downmix.minus3dB
            } else if channel == 3 && hasEffects {
                continue
            } else if (channel - firstSurround) % 2 == 0 {
                left[channel] = Downmix.minus3dB
            } else {
                right[channel] = Downmix.minus3dB
            }
        }
        self.left = Downmix.normalised(left)
        self.right = Downmix.normalised(right)
    }

    private static func normalised(_ weights: [Float]) -> [Float] {
        let sum = weights.reduce(0, +)
        return sum > 0 ? weights.map { $0 / sum } : weights
    }
}
