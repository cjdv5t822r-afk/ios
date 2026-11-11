import XCTest
@testable import StageCore

/// Port of `ClipTimelineTest.kt`: the same cases with the same numbers.
final class ClipTimelineTests: XCTestCase {

    // 0 = idle (3 s), 1 = walk (1 s), 2 = attack (1.1 s), 3 = zero-length
    private func timeline(idle: Int? = 0, fade: Float = 0.2) -> ClipTimeline {
        ClipTimeline(durations: [3, 1, 1.1, 0], idleIndex: idle, fadeSeconds: fade)
    }

    func testNothingPlaysUntilAsked() {
        let t = timeline()
        XCTAssertEqual(t.current, -1)
        XCTAssertEqual(t.advance(0.1), -1)
        XCTAssertFalse(t.isFading)
    }

    func testFirstClipStartsWithoutAFade() {
        let t = timeline()
        t.play(1, loop: true)
        XCTAssertEqual(t.current, 1)
        XCTAssertFalse(t.isFading)
        XCTAssertEqual(t.fade, 1)
    }

    func testLoopingClipWraps() {
        let t = timeline()
        t.play(1, loop: true)
        XCTAssertTrue(t.run(2.5).isEmpty)
        XCTAssertEqual(t.time, 0.5, accuracy: 0.02)
        XCTAssertEqual(t.current, 1)
    }

    func testSwitchingClipsCrossFades() {
        let t = timeline(fade: 0.2)
        t.play(1, loop: true)
        t.run(0.4)
        t.play(0, loop: true)
        XCTAssertTrue(t.isFading)
        XCTAssertEqual(t.previous, 1)
        XCTAssertEqual(t.previousTime, 0.4, accuracy: 0.02)
        t.run(0.1)
        XCTAssertEqual(t.fade, 0.5, accuracy: 0.05)
        // the outgoing looping clip keeps moving while it fades
        XCTAssertEqual(t.previousTime, 0.5, accuracy: 0.02)
        t.run(0.15)
        XCTAssertFalse(t.isFading)
        XCTAssertEqual(t.previous, -1)
    }

    func testOneShotReturnsToIdleAndReportsOnce() {
        let t = timeline(idle: 0)
        t.play(2, loop: false)
        let ended = t.run(2)
        XCTAssertEqual(ended, [2])
        XCTAssertEqual(t.current, 0)
        XCTAssertTrue(t.looping)
        XCTAssertFalse(t.holding)
    }

    func testOneShotFadesOutFromItsLastFrame() {
        let t = timeline(idle: 0, fade: 0.2)
        t.play(2, loop: false)
        t.run(1.1 + 1.0 / 60.0)
        XCTAssertEqual(t.current, 0)
        XCTAssertEqual(t.previous, 2)
        // the finished one-shot stays clamped on its final frame while idle fades in
        XCTAssertEqual(t.previousTime, 1.1, accuracy: 1e-4)
        t.run(0.1)
        XCTAssertEqual(t.previousTime, 1.1, accuracy: 1e-4)
    }

    func testOneShotWithoutIdleHoldsTheLastFrame() {
        let t = timeline(idle: nil)
        t.play(2, loop: false)
        XCTAssertEqual(t.run(3), [2])
        XCTAssertEqual(t.current, 2)
        XCTAssertTrue(t.holding)
        XCTAssertEqual(t.time, 1.1, accuracy: 1e-4)
    }

    func testIdleClipPlayedOnceDoesNotChainToItself() {
        let t = timeline(idle: 0)
        t.play(0, loop: false)
        XCTAssertEqual(t.run(5), [0])
        XCTAssertTrue(t.holding)
        XCTAssertEqual(t.time, 3, accuracy: 1e-4)
    }

    func testPauseFreezesTimeAndFade() {
        let t = timeline(fade: 0.2)
        t.play(1, loop: true)
        t.run(0.3)
        t.play(0, loop: true)
        t.run(0.1)
        let time = t.time
        let fade = t.fade
        t.paused = true
        t.run(1)
        XCTAssertEqual(t.time, time)
        XCTAssertEqual(t.fade, fade)
        t.paused = false
        t.run(0.05)
        XCTAssertGreaterThan(t.time, time)
    }

    func testSpeedScalesPlaybackButNotTheFade() {
        let t = timeline(fade: 0.2)
        t.play(1, loop: true)
        t.speed = 2
        t.run(0.25)
        XCTAssertEqual(t.time, 0.5, accuracy: 0.02)
        t.play(0, loop: true)
        t.run(0.1)
        XCTAssertEqual(t.fade, 0.5, accuracy: 0.05)
        t.speed = 1000
        XCTAssertEqual(t.speed, ClipTimeline.maxSpeed)
        t.speed = .nan
        XCTAssertEqual(t.speed, 1)
        t.speed = 0
        XCTAssertEqual(t.speed, ClipTimeline.minSpeed)
    }

    func testZeroLengthClipsAreSafe() {
        let t = timeline(idle: 0)
        t.play(3, loop: true)
        t.run(0.5)
        XCTAssertEqual(t.time, 0)
        t.play(3, loop: false)
        XCTAssertEqual(t.run(0.5), [3])
        XCTAssertEqual(t.current, 0)
    }

    func testBadIndicesAndHugeStepsAreIgnoredOrClamped() {
        let t = timeline()
        t.play(99, loop: true)
        XCTAssertEqual(t.current, -1)
        t.play(-1, loop: true)
        XCTAssertEqual(t.current, -1)
        t.play(1, loop: true)
        t.advance(10)
        XCTAssertEqual(t.time, ClipTimeline.maxStepSeconds, accuracy: 1e-4)
        XCTAssertEqual(t.advance(.nan), -1)
    }

    func testZeroFadeSwitchesInstantly() {
        let t = timeline(fade: 0)
        t.play(1, loop: true)
        t.run(0.2)
        t.play(0, loop: true)
        XCTAssertFalse(t.isFading)
    }

    func testResetGoesBackToTheRestPose() {
        let t = timeline()
        t.play(1, loop: true)
        t.run(0.3)
        t.play(2, loop: false)
        t.reset()
        XCTAssertEqual(t.current, -1)
        XCTAssertEqual(t.previous, -1)
        XCTAssertFalse(t.isFading)
        XCTAssertEqual(t.advance(0.1), -1)
    }
}

private extension ClipTimeline {

    /// Advances in 1/60 s steps; returns every "one-shot ended" index reported.
    @discardableResult
    func run(_ seconds: Float) -> [Int] {
        var ended: [Int] = []
        var left = seconds
        while left > 1e-6 {
            let step = min(left, 1.0 / 60.0)
            let result = advance(step)
            if result >= 0 { ended.append(result) }
            left -= step
        }
        return ended
    }
}
