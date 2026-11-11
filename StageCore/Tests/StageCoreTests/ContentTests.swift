import XCTest
@testable import StageCore

final class ManifestTests: XCTestCase {

    func testMissingManifestGivesDefaults() {
        let m = CharacterManifest.parse(nil, fallbackId: "hero")
        XCTAssertEqual(m, CharacterManifest(id: "hero"))
        XCTAssertEqual(m?.model, "model.glb")
        XCTAssertEqual(m?.displayName, "hero")
    }

    func testSmallestManifest() {
        let m = CharacterManifest.parse(#"{ "id": "hero" }"#, fallbackId: "x")
        XCTAssertEqual(m?.id, "hero")
        XCTAssertEqual(m?.scale, 1)
        XCTAssertNil(m?.heightMeters)
        XCTAssertEqual(m?.animations, [])
    }

    func testFullManifest() throws {
        let text = """
        {
          "format": 1, "id": "bohater", "name": "Bohater", "model": "model.glb",
          "heightMeters": 1.8, "rotationY": 90, "defaultAnimation": "stanie", "unknownKey": [1, 2, 3],
          "animations": [
            { "clip": "atak", "label": "Cios", "category": "attack", "loop": false },
            { "clip": "taniec", "label": "Taniec", "category": "emote", "loop": true },
            { "clip": "pomocniczy", "hidden": true }
          ]
        }
        """
        let m = try XCTUnwrap(CharacterManifest.parse(text, fallbackId: "x"))
        XCTAssertEqual(m.name, "Bohater")
        XCTAssertEqual(m.heightMeters, 1.8)
        XCTAssertEqual(m.rotationY, 90)
        XCTAssertEqual(m.defaultAnimation, "stanie")
        XCTAssertEqual(m.animations.count, 3)
        XCTAssertEqual(m.animations[0], AnimationEntry(clip: "atak", label: "Cios", category: .attack, loop: false))
        XCTAssertTrue(m.animations[2].hidden)
        XCTAssertNil(m.animations[2].loop)
    }

    func testTheShippedDemoManifestParses() throws {
        let url = repositoryRoot().appendingPathComponent("content/characters/stage_dummy/character.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("content/ is not next to the package")
        }
        let m = try XCTUnwrap(CharacterManifest.parse(text, fallbackId: "stage_dummy"))
        XCTAssertEqual(m.id, "stage_dummy")
        XCTAssertEqual(m.name, "Stage Dummy")
        XCTAssertEqual(m.defaultAnimation, "Idle")
        XCTAssertEqual(m.animations.map(\.clip), ["Idle", "Walk", "Run", "Attack_Slash", "Attack_Spin", "Dance", "Wave", "Jump", "Cheer"])
        XCTAssertEqual(m.animations.map(\.label), ["Stanie", "Chód", "Bieg", "Cios", "Młynek", "Taniec", "Machanie", "Skok", "Wiwat"])
    }

    func testBrokenManifestsAreRefused() {
        XCTAssertNil(CharacterManifest.parse("{", fallbackId: "x"))
        XCTAssertNil(CharacterManifest.parse("[]", fallbackId: "x"))
        XCTAssertNil(CharacterManifest.parse(#"{ "id": "a", "animations": [ { "label": "no clip" } ] }"#, fallbackId: "x"))
        XCTAssertNil(CharacterManifest.parse(#"{ "id": "a", "animations": { "clip": "x" } }"#, fallbackId: "x"))
    }

    func testAManifestMayLeaveTheIdToTheFolder() {
        // The catalog tool publishes such packs, down to a manifest that only names the model.
        XCTAssertEqual(CharacterManifest.parse(#"{ "name": "no id" }"#, fallbackId: "x")?.id, "x")
        XCTAssertEqual(CharacterManifest.parse("{}", fallbackId: "fallback")?.id, "fallback")
        let plain = CharacterManifest.parse("{\n  \"model\": \"hero.glb\"\n}\n", fallbackId: "plain_pack-2")
        XCTAssertEqual(plain?.id, "plain_pack-2")
        XCTAssertEqual(plain?.model, "hero.glb")
        XCTAssertEqual(plain?.displayName, "plain pack 2")
        XCTAssertEqual(CharacterManifest.parse(#"{ "id": " ", "name": "Named" }"#, fallbackId: "folder_id")?.id, "folder_id")
    }

    func testTextFromAManifestIsCleanedBeforeItIsShown() throws {
        // What a careless or hostile server can put into a manifest of up to a megabyte.
        let name = "  Wojownik\u{202E}\\u0007 " + String(repeating: "x", count: 30_000)
        let label = "Atak\u{200F}\\n" + String(repeating: "y", count: 5_000)
        let text = "{ \"name\": \"\(name)\", \"animations\": [ { \"clip\": \"Attack_01\", \"label\": \"\(label)\" }, { \"clip\": \"Idle\" } ] }"
        let manifest = try XCTUnwrap(CharacterManifest.parse(text, fallbackId: "loud"))
        XCTAssertEqual(manifest.name, "Wojownik " + String(repeating: "x", count: 71))
        XCTAssertEqual(manifest.displayName, manifest.name)
        XCTAssertEqual(manifest.animations.map(\.label), ["Atak" + String(repeating: "y", count: 76), nil])
        // The clip name is the key into the model and stays as it is.
        XCTAssertEqual(manifest.animations.map(\.clip), ["Attack_01", "Idle"])
        XCTAssertEqual(CharacterManifest.parse(#"{ "name": " Krótka nazwa " }"#, fallbackId: "x")?.name, "Krótka nazwa")
    }

    func testNumbersBeyondAFloatFallBackToDefaults() {
        let m = CharacterManifest.parse(#"{ "scale": 3.5e38, "heightMeters": 1e39, "rotationY": -1e39 }"#, fallbackId: "x")
        XCTAssertEqual(m?.scale, 1)
        XCTAssertNil(m?.heightMeters)
        XCTAssertEqual(m?.rotationY, 0)
    }

    func testModelMustBeAPlainFileName() {
        XCTAssertNil(CharacterManifest.parse(#"{ "id": "a", "model": "../secret.glb" }"#, fallbackId: "x"))
        XCTAssertNil(CharacterManifest.parse(#"{ "id": "a", "model": "sub/model.glb" }"#, fallbackId: "x"))
        XCTAssertNil(CharacterManifest.parse(#"{ "id": "a", "model": "sub\\model.glb" }"#, fallbackId: "x"))
        XCTAssertNil(CharacterManifest.parse(#"{ "id": "a", "model": ".hidden.glb" }"#, fallbackId: "x"))
        XCTAssertEqual(CharacterManifest.parse(#"{ "id": "a", "model": "  " }"#, fallbackId: "x")?.model, "model.glb")
    }

    func testWrongKindsFallBackToDefaults() {
        let m = CharacterManifest.parse(
            #"{ "id": "", "scale": null, "heightMeters": "1.5", "rotationY": "abc", "name": null, "animations": null }"#,
            fallbackId: "fallback"
        )
        XCTAssertEqual(m?.id, "fallback")
        XCTAssertEqual(m?.scale, 1)
        XCTAssertEqual(m?.heightMeters, 1.5)
        XCTAssertEqual(m?.rotationY, 0)
        XCTAssertEqual(m?.name, "")
        let entry = CharacterManifest.parse(
            #"{ "id": "a", "animations": [ { "clip": "x", "category": "sideways", "loop": "true" } ] }"#, fallbackId: "x"
        )?.animations.first
        XCTAssertNil(entry?.category)
        XCTAssertEqual(entry?.loop, true)
    }

    func testWrittenManifestReadsBackTheSame() throws {
        let original = CharacterManifest(
            id: "hero_2", name: "Bohater „Ż”", heightMeters: 1.8, rotationY: 180, defaultAnimation: "Idle",
            animations: [AnimationEntry(clip: "Idle", label: "Stanie", category: .idle, loop: true), AnimationEntry(clip: "x", hidden: true)]
        )
        let text = original.jsonText()
        XCTAssertEqual(CharacterManifest.parse(text, fallbackId: "other"), original)
        // Defaults are left out, as the Android app writes them.
        XCTAssertFalse(text.contains("\"scale\""))
        XCTAssertFalse(text.contains("\"model\""))
    }
}

final class PackRulesTests: XCTestCase {

    func testSanitizeId() {
        XCTAssertEqual(PackRules.sanitizeId("Hero Model!"), "hero_model")
        // Every run of other characters (Polish letters included) becomes one underscore; the ends are trimmed.
        XCTAssertEqual(PackRules.sanitizeId("  --Zażółć gęślą--  "), "za_g_l")
        XCTAssertEqual(PackRules.sanitizeId("Zażółć"), "za")
        XCTAssertEqual(PackRules.sanitizeId("!!!"), "model")
        XCTAssertEqual(PackRules.sanitizeId(""), "model")
        XCTAssertEqual(PackRules.sanitizeId("../../etc/passwd"), "etc_passwd")
        XCTAssertEqual(PackRules.sanitizeId(".hidden"), "hidden")
        XCTAssertEqual(PackRules.sanitizeId("a_b-c9"), "a_b-c9")
        XCTAssertEqual(PackRules.sanitizeId(String(repeating: "a", count: 80)).count, 48)
    }

    func testBaseName() {
        XCTAssertEqual(PackRules.baseName("bohater.glb"), "bohater")
        XCTAssertEqual(PackRules.baseName("archive.tar.zip"), "archive.tar")
        XCTAssertEqual(PackRules.baseName("noextension"), "noextension")
        XCTAssertEqual(PackRules.baseName(".glb"), "model")
    }

    func testZipEntriesAreFlattenedAndFiltered() {
        XCTAssertEqual(PackRules.flattenedEntryName("model.glb"), "model.glb")
        XCTAssertEqual(PackRules.flattenedEntryName("hero/model.glb"), "model.glb")
        XCTAssertEqual(PackRules.flattenedEntryName("hero\\textures\\skin.PNG"), "skin.PNG")
        XCTAssertEqual(PackRules.flattenedEntryName("../../../Library/character.json"), "character.json")
        XCTAssertNil(PackRules.flattenedEntryName("hero/"))
        XCTAssertNil(PackRules.flattenedEntryName("hero/.DS_Store"))
        XCTAssertNil(PackRules.flattenedEntryName("__MACOSX/._model.glb"))
        XCTAssertNil(PackRules.flattenedEntryName("run.sh"))
        XCTAssertNil(PackRules.flattenedEntryName("model"))
        XCTAssertNil(PackRules.flattenedEntryName(".."))
    }

    func testFileKindComesFromTheFirstBytes() {
        XCTAssertEqual(PackFileKind.detect([0x67, 0x6C, 0x54, 0x46, 2, 0, 0, 0]), .glb)
        XCTAssertEqual(PackFileKind.detect([0x50, 0x4B, 0x03, 0x04, 20, 0]), .zip)
        XCTAssertEqual(PackFileKind.detect([0x50, 0x4B, 0x05, 0x06]), .unknown) // an empty zip has nothing to import
        XCTAssertEqual(PackFileKind.detect([0x67, 0x6C]), .unknown)
        XCTAssertEqual(PackFileKind.detect([UInt8]()), .unknown)
        XCTAssertEqual(PackFileKind.detect(Data([0x67, 0x6C, 0x54, 0x46])), .glb)
    }

    func testUniqueId() {
        let taken: Set<String> = ["hero", "hero_2"]
        XCTAssertEqual(PackRules.uniqueId("hero") { taken.contains($0) }, "hero_3")
        XCTAssertEqual(PackRules.uniqueId("mage") { taken.contains($0) }, "mage")
    }
}

final class AppSettingsTests: XCTestCase {

    func testDefaultsMatchTheAndroidApp() {
        let s = AppSettings()
        XCTAssertEqual(s.mode, .ar)
        XCTAssertTrue(s.watermarkEnabled)
        XCTAssertEqual(s.watermarkAnchor, .topLeft)
        XCTAssertEqual(s.watermarkWidth, 0.30)
        XCTAssertEqual(s.watermarkOpacity, 0.92)
        XCTAssertEqual(s.countdownSeconds, 0)
        XCTAssertEqual(s.maxDurationSeconds, 60)
        XCTAssertFalse(s.recordMicrophone)
        XCTAssertTrue(s.showPlanes)
        XCTAssertTrue(s.groundShadow)
        XCTAssertFalse(s.depthOcclusion)
        XCTAssertEqual(s.studioColorArgb, 0xFF00_B140)
        XCTAssertFalse(s.onboardingSeen)
    }

    func testSanitizeClampsEveryNumber() {
        var s = AppSettings()
        s.watermarkWidth = 5
        s.watermarkOpacity = -1
        s.countdownSeconds = 99
        s.maxDurationSeconds = -5
        s.studioCustomColor = 0x0012_3456
        let clean = s.sanitized()
        XCTAssertEqual(clean.watermarkWidth, AppSettings.watermarkWidthMax)
        XCTAssertEqual(clean.watermarkOpacity, AppSettings.watermarkOpacityMin)
        XCTAssertEqual(clean.countdownSeconds, 30)
        XCTAssertEqual(clean.maxDurationSeconds, 0)
        XCTAssertEqual(clean.studioCustomColor, 0xFF12_3456)
        s.watermarkWidth = .nan
        XCTAssertEqual(s.sanitized().watermarkWidth, 0.30)
    }

    func testStoredFormRoundTrips() {
        var s = AppSettings()
        s.mode = .studio
        s.lastCharacterId = "stage_dummy"
        s.watermarkAnchor = .bottomCenter
        s.watermarkWidth = 0.45
        s.watermarkOpacity = 0.5
        s.countdownSeconds = 5
        s.maxDurationSeconds = 0
        s.recordMicrophone = true
        s.safeZoneGuides = true
        s.showPlanes = false
        s.groundShadow = false
        s.depthOcclusion = true
        s.studioBackground = .custom
        s.studioCustomColor = 0xFFAA_BBCC
        s.onboardingSeen = true
        XCTAssertEqual(AppSettings(stored: s.stored), s)
        XCTAssertEqual(AppSettings(stored: s.stored).studioColorArgb, 0xFFAA_BBCC)
    }

    func testUnreadableStoredValuesKeepDefaults() {
        let s = AppSettings(stored: [
            AppSettings.Keys.mode: "HOLOGRAM",
            AppSettings.Keys.watermarkAnchor: 7,
            AppSettings.Keys.watermarkWidth: "wide",
            AppSettings.Keys.studioBackground: "PINK",
        ])
        XCTAssertEqual(s, AppSettings())
        XCTAssertEqual(AppSettings(stored: [:]), AppSettings())
        XCTAssertNil(AppSettings().stored[AppSettings.Keys.lastCharacterId])
    }
}

/// The folder that holds `ios/`, `android/` and `content/`, found from this file's own location.
func repositoryRoot(file: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: "\(file)")
    // .../ios/StageCore/Tests/StageCoreTests/<file>
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
}
