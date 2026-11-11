import Foundation

/// Loudness of the music under a recording: the chosen volume, a short fade-in at the very start so the first
/// sample does not click, and a fade-out at the very end so the music does not stop dead with the video.
/// Loop seams in between are not touched. Port of `music/MusicGain.kt`.
public enum MusicGain {
    public static let fadeInMillis = 20
    public static let fadeOutMillis = 700

    /// A video at least this long gets the full fades; a shorter one gets both shortened in proportion.
    public static let fullFadesMillis = 1_500

    public struct Envelope: Equatable, Sendable {
        public let totalFrames: Int
        public let fadeInFrames: Int
        public let fadeOutFrames: Int
        public let volume: Float

        /// Gain of the frame with index `frame`: 0 outside the recording, `volume` between the fades.
        public func at(_ frame: Int) -> Float {
            if frame < 0 || frame >= totalFrames { return 0 }
            var gain = volume
            if frame < fadeInFrames { gain *= Float(frame) / Float(fadeInFrames) }
            let framesAfter = totalFrames - 1 - frame
            if framesAfter < fadeOutFrames {
                // Raised cosine: leaves the full volume gently and lands on silence without a corner.
                let x = Double(framesAfter) / Double(fadeOutFrames)
                gain *= Float(0.5 - 0.5 * cos(Double.pi * x))
            }
            return gain
        }
    }

    /// The envelope for music of `totalFrames` frames at `sampleRate`; `volume` is clamped to 0...1.
    public static func envelope(totalFrames: Int, sampleRate: Int, volume: Float) -> Envelope {
        let level: Float = volume.isNaN ? 0 : min(max(volume, 0), 1)
        if totalFrames <= 0 || sampleRate <= 0 {
            return Envelope(totalFrames: 0, fadeInFrames: 0, fadeOutFrames: 0, volume: level)
        }
        // Fades are a fixed share of the first 1.5 s: full length from there on, shorter in proportion below.
        let fadedFrames = min(totalFrames, sampleRate * fullFadesMillis / 1_000)
        return Envelope(
            totalFrames: totalFrames,
            fadeInFrames: fadedFrames * fadeInMillis / fullFadesMillis,
            fadeOutFrames: fadedFrames * fadeOutMillis / fullFadesMillis,
            volume: level
        )
    }

    public static func gain(frame: Int, totalFrames: Int, sampleRate: Int, volume: Float) -> Float {
        envelope(totalFrames: totalFrames, sampleRate: sampleRate, volume: volume).at(frame)
    }
}

/// What the AAC encoder is asked for.
///
/// Narrower than `AacTarget` on Android, on purpose: the asset writer's encoder is only asked for the two rates
/// and the two bit rates the app already uses or that every iPhone is known to take. Music at any other rate is
/// handed over as it is and the writer's own converter brings it to 44.1 kHz.
public enum AacTarget {
    public static let fallbackSampleRate = 44_100
    static let stereoBitRate = 160_000
    static let monoBitRate = 96_000

    /// The rate of the AAC track for music at `sourceRate`: 48 kHz stays, everything else becomes 44.1 kHz.
    public static func sampleRate(_ sourceRate: Int) -> Int {
        sourceRate == 48_000 ? 48_000 : fallbackSampleRate
    }

    public static func bitRate(channels: Int) -> Int {
        channels <= 1 ? monoBitRate : stereoBitRate
    }

    /// Audio frames that cover `durationMicros` microseconds, to the nearest frame.
    public static func frames(durationMicros: Int64, sampleRate: Int) -> Int {
        if durationMicros <= 0 || sampleRate <= 0 { return 0 }
        return Int((durationMicros * Int64(sampleRate) + 500_000) / 1_000_000)
    }
}
