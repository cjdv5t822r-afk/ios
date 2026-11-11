import XCTest
@testable import StageCore

/// Port of `ClipRulesTest.kt`.
final class ClipRulesTests: XCTestCase {

    func testCategorisesEnglishAndPolishNames() {
        XCTAssertEqual(ClipRules.categoryOf("Idle"), .idle)
        XCTAssertEqual(ClipRules.categoryOf("stanie"), .idle)
        XCTAssertEqual(ClipRules.categoryOf("Walk"), .move)
        XCTAssertEqual(ClipRules.categoryOf("chod"), .move)
        XCTAssertEqual(ClipRules.categoryOf("chód"), .move)
        XCTAssertEqual(ClipRules.categoryOf("Attack_Slash"), .attack)
        XCTAssertEqual(ClipRules.categoryOf("atak_ciecie"), .attack)
        XCTAssertEqual(ClipRules.categoryOf("taniec"), .emote)
        XCTAssertEqual(ClipRules.categoryOf("Jump"), .emote)
        XCTAssertEqual(ClipRules.categoryOf("clip_07"), .other)
    }

    func testAttackWinsOverMove() {
        XCTAssertEqual(ClipRules.categoryOf("run_attack"), .attack)
    }

    func testLoopDefaults() {
        XCTAssertTrue(ClipRules.loopsByDefault("Idle", category: .idle))
        XCTAssertTrue(ClipRules.loopsByDefault("Run", category: .move))
        XCTAssertTrue(ClipRules.loopsByDefault("Dance", category: .emote))
        XCTAssertFalse(ClipRules.loopsByDefault("Wave", category: .emote))
        XCTAssertFalse(ClipRules.loopsByDefault("Attack_Slash", category: .attack))
    }

    func testPrettyLabels() {
        XCTAssertEqual(ClipRules.prettyLabel("Attack_Slash"), "Attack Slash")
        XCTAssertEqual(ClipRules.prettyLabel("walkCycle"), "walk Cycle")
        XCTAssertEqual(ClipRules.prettyLabel("_"), "_")
        XCTAssertEqual(ClipRules.prettyLabel("stage_dummy"), "stage dummy")
        XCTAssertEqual(ClipRules.prettyLabel("a--b..c"), "a b c")
    }

    private let raw = [
        RawClip(index: 0, name: "Idle", durationSeconds: 3),
        RawClip(index: 1, name: "Walk", durationSeconds: 1),
        RawClip(index: 2, name: "Attack_Slash", durationSeconds: 1.1),
        RawClip(index: 3, name: "Dance", durationSeconds: 4),
        RawClip(index: 4, name: "helper_pose", durationSeconds: 0.1),
    ]

    func testManifestOverridesWinAndKeepTheirOrder() {
        let manifest = CharacterManifest(
            id: "x",
            animations: [
                AnimationEntry(clip: "Dance", label: "Taniec", category: .emote, loop: false),
                AnimationEntry(clip: "helper_pose", hidden: true),
            ]
        )
        let clips = ClipRules.buildClips(manifest: manifest, raw: raw)
        XCTAssertEqual(clips.map(\.name), ["Dance", "Idle", "Walk", "Attack_Slash"])
        XCTAssertEqual(clips[0].label, "Taniec")
        XCTAssertFalse(clips[0].loop)
        XCTAssertEqual(clips[0].index, 3)
        XCTAssertEqual(clips[3].category, .attack)
    }

    func testDefaultClipPrefersManifestThenIdle() {
        let clips = ClipRules.buildClips(manifest: CharacterManifest(id: "x"), raw: raw)
        XCTAssertEqual(ClipRules.defaultClip(manifest: CharacterManifest(id: "x"), clips: clips)?.name, "Idle")
        XCTAssertEqual(ClipRules.defaultClip(manifest: CharacterManifest(id: "x", defaultAnimation: "Walk"), clips: clips)?.name, "Walk")
        let noIdle = clips.filter { $0.category != .idle }
        XCTAssertNil(ClipRules.defaultClip(manifest: CharacterManifest(id: "x", defaultAnimation: "missing"), clips: noIdle))
    }

    func testUnlistedClipsFollowGroupedByCategory() {
        let mixed = [
            RawClip(index: 0, name: "Wave", durationSeconds: 1),
            RawClip(index: 1, name: "Attack", durationSeconds: 1),
            RawClip(index: 2, name: "Run", durationSeconds: 1),
            RawClip(index: 3, name: "Idle", durationSeconds: 1),
            RawClip(index: 4, name: "mystery", durationSeconds: 1),
        ]
        let clips = ClipRules.buildClips(manifest: CharacterManifest(id: "x"), raw: mixed)
        XCTAssertEqual(clips.map(\.name), ["Idle", "Run", "Attack", "Wave", "mystery"])
        XCTAssertEqual(clips.map(\.loop), [true, true, false, false, false])
    }

    func testToggledLoopKeepsEverythingElse() {
        let clip = Clip(index: 2, name: "Wave", label: "Machanie", category: .emote, loop: false, durationSeconds: 2.2)
        let toggled = clip.togglingLoop()
        XCTAssertTrue(toggled.loop)
        XCTAssertEqual(toggled.name, clip.name)
        XCTAssertEqual(toggled.index, clip.index)
    }
}
