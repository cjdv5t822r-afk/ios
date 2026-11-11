import Foundation

/// Which clip plays, at what time, and how far a cross-fade from the previous clip has got.
/// Pure state machine with no rendering code, so it can be unit-tested; the app's `ClipPlayer` applies it to a model.
/// Port of `stage/ClipTimeline.kt`.
///
/// Rules:
///  - `play` starts a clip from its beginning and cross-fades from whatever was showing.
///  - A looping clip wraps. A one-shot clip holds its last frame, then (if an idle clip is set and it is not the
///    idle clip itself) cross-fades back to idle; `advance` reports the clip that just ended.
///  - `paused` freezes everything, the cross-fade included, so the pose holds.
public final class ClipTimeline {

    public static let defaultFadeSeconds: Float = 0.22
    public static let minSpeed: Float = 0.05
    public static let maxSpeed: Float = 4

    /// A frame gap longer than this (app paused, debugger) is treated as this long.
    public static let maxStepSeconds: Float = 0.1

    private let durations: [Float]

    /// Clip to return to after a one-shot, or nil to keep holding the last frame.
    public var idleIndex: Int?

    /// Cross-fade length in real time (not affected by `speed`).
    public let fadeSeconds: Float

    /// Playback rate; 1 = authored speed. Values outside `minSpeed...maxSpeed` are clamped.
    public var speed: Float = 1 {
        didSet {
            let clamped = speed.isFinite ? min(max(speed, ClipTimeline.minSpeed), ClipTimeline.maxSpeed) : 1
            if clamped != speed { speed = clamped }
        }
    }

    public var paused = false

    /// Index of the clip being shown, or -1 when nothing has been played yet (rest pose).
    public private(set) var current = -1
    public private(set) var time: Float = 0
    public private(set) var looping = true

    /// Clip being faded out, or -1.
    public private(set) var previous = -1
    public private(set) var previousTime: Float = 0
    private var previousLooping = false

    /// 0 = only `previous` is visible, 1 = only `current`.
    public private(set) var fade: Float = 1

    /// True once a one-shot clip reached its end and is holding its last frame.
    public private(set) var holding = false

    /// - Parameters:
    ///   - durations: clip length in seconds, indexed like the model's clips
    ///   - idleIndex: clip to return to after a one-shot, or nil to keep holding the last frame
    ///   - fadeSeconds: cross-fade length in real time
    public init(durations: [Float], idleIndex: Int? = nil, fadeSeconds: Float = ClipTimeline.defaultFadeSeconds) {
        self.durations = durations
        self.idleIndex = idleIndex
        self.fadeSeconds = fadeSeconds
    }

    public var clipCount: Int { durations.count }
    public var isFading: Bool { previous >= 0 && fade < 1 }

    public func duration(_ index: Int) -> Float {
        guard durations.indices.contains(index) else { return 0 }
        let d = durations[index]
        return d.isFinite && d > 0 ? d : 0
    }

    /// Starts `index` from the beginning. Out-of-range indices are ignored.
    public func play(_ index: Int, loop: Bool) {
        guard durations.indices.contains(index) else { return }
        if current >= 0 && fadeSeconds > 0 {
            previous = current
            previousTime = time
            previousLooping = looping && !holding
            fade = 0
        } else {
            previous = -1
            fade = 1
        }
        current = index
        time = 0
        looping = loop
        holding = false
    }

    /// Back to the rest pose: nothing playing, no fade.
    public func reset() {
        current = -1
        previous = -1
        time = 0
        previousTime = 0
        fade = 1
        holding = false
    }

    /// Moves the timeline forward by `dtSeconds` of real time.
    /// - Returns: the index of a one-shot clip that reached its end during this step, or -1
    @discardableResult
    public func advance(_ dtSeconds: Float) -> Int {
        if paused || current < 0 { return -1 }
        let dt = dtSeconds.isFinite ? min(max(dtSeconds, 0), ClipTimeline.maxStepSeconds) : 0
        if dt == 0 { return -1 }

        // Keep the outgoing clip moving while it fades, so walk -> run blends two moving poses.
        if previous >= 0 {
            let pd = duration(previous)
            previousTime += dt * speed
            if pd <= 0 {
                previousTime = 0
            } else if previousLooping {
                previousTime = previousTime.truncatingRemainder(dividingBy: pd)
            } else {
                previousTime = min(previousTime, pd)
            }
            fade += fadeSeconds > 0 ? dt / fadeSeconds : 1
            if fade >= 1 {
                fade = 1
                previous = -1
            }
        }

        if holding { return -1 }
        let d = duration(current)
        time += dt * speed
        if looping {
            time = d > 0 ? time.truncatingRemainder(dividingBy: d) : 0
            return -1
        }
        if time < d { return -1 }

        // A one-shot reached its end: hold the exact last frame and hand over to idle if there is one.
        let ended = current
        time = d
        if let idle = idleIndex, idle != ended, durations.indices.contains(idle) {
            play(idle, loop: true)
        } else {
            holding = true
        }
        return ended
    }
}
