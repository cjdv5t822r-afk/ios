import XCTest
@testable import StageCore

// The character library: ports of CatalogRulesTest, NameOrderTest, LibraryMessagesTest and the rule-level parts of
// PackStoreTest, PackInstallerTest and HttpPackTransportTest of the Android app. The parts of those tests that
// drive a real download against a fake server have no counterpart here: the downloader lives in the app target.

private func repeated(_ text: String, _ count: Int) -> String {
    String(repeating: text, count: count)
}

/// A catalog as the packing tool writes it.
private func catalogJSON(_ packs: [RemotePack]) -> String {
    let entries = packs.map { pack -> String in
        let files = pack.files
            .map { #"{"name":"\#($0.name)","bytes":\#($0.bytes),"sha256":"\#($0.sha256)"}"# }
            .joined(separator: ",")
        let clips = pack.clips.map { String($0) } ?? "null"
        return #"{"id":"\#(pack.id)","name":"\#(pack.name)","version":"\#(pack.version)","clips":\#(clips),"bytes":\#(pack.bytes),"files":[\#(files)]}"#
    }
    return #"{"format":1,"updated":"2026-11-11T10:00:00Z","characters":[\#(entries.joined(separator: ","))]}"#
}

final class CatalogRulesTests: XCTestCase {

    private let manifest = RemoteFile(name: "character.json", bytes: 892, sha256: repeated("a", 64))
    private let model = RemoteFile(name: "model.glb", bytes: 242_564, sha256: repeated("b", 64))

    private var good: RemotePack {
        RemotePack(id: "stage_dummy", name: "Stage Dummy", version: "3f9a0c2b7d11", clips: 9, bytes: 243_456, files: [manifest, model])
    }

    private func pack(_ change: (inout RemotePack) -> Void) -> RemotePack {
        var pack = good
        change(&pack)
        return pack
    }

    private func file(_ file: RemoteFile, _ change: (inout RemoteFile) -> Void) -> RemoteFile {
        var file = file
        change(&file)
        return file
    }

    /// `good` with other files, and the total that goes with them.
    private func sized(_ files: [RemoteFile]) -> RemotePack {
        pack {
            $0.files = files
            $0.bytes = files.reduce(Int64(0)) { $0 + $1.bytes }
        }
    }

    func testAcceptsTheDocumentedEntry() {
        XCTAssertNil(CatalogRules.problem(of: good))
        XCTAssertEqual(CatalogRules.sanitize(good), good)
    }

    func testValidationTable() {
        let mb: Int64 = 1024 * 1024
        let many = (0..<33).map { RemoteFile(name: "f\($0).glb", bytes: 1, sha256: repeated("c", 64)) } + [manifest]
        let cases: [(RemotePack, PackProblem)] = [
            (pack { $0.id = "" }, .badId),
            (pack { $0.id = "Stage_Dummy" }, .badId),
            (pack { $0.id = "../etc" }, .badId),
            (pack { $0.id = "a/b" }, .badId),
            (pack { $0.id = "a b" }, .badId),
            (pack { $0.id = ".hidden" }, .badId),
            (pack { $0.id = repeated("x", 65) }, .badId),
            (pack { $0.files = []; $0.bytes = 0 }, .noFiles),
            (sized(many), .tooManyFiles),
            (sized([manifest, file(model) { $0.name = "../model.glb" }]), .badFileName),
            (sized([manifest, file(model) { $0.name = "sub/model.glb" }]), .badFileName),
            (sized([manifest, file(model) { $0.name = "sub\\model.glb" }]), .badFileName),
            (sized([manifest, file(model) { $0.name = ".." }]), .badFileName),
            (sized([manifest, file(model) { $0.name = ".remote-version" }]), .badFileName),
            (sized([manifest, file(model) { $0.name = "" }]), .badFileName),
            (sized([manifest, file(model) { $0.name = "model glb" }]), .badFileName),
            (sized([manifest, file(model) { $0.name = "C:model.glb" }]), .badFileName),
            (sized([manifest, model, model]), .duplicateFile),
            (sized([manifest, model, file(model) { $0.name = "MODEL.GLB" }]), .duplicateFile),
            (sized([model]), .noManifest),
            (sized([file(manifest) { $0.name = "Character.json" }, model]), .noManifest),
            (sized([manifest, file(model) { $0.sha256 = repeated("b", 63) }]), .badChecksum),
            (sized([manifest, file(model) { $0.sha256 = repeated("B", 64) }]), .badChecksum),
            (sized([manifest, file(model) { $0.sha256 = repeated("g", 64) }]), .badChecksum),
            (sized([manifest, file(model) { $0.sha256 = "" }]), .badChecksum),
            (pack { $0.files = [manifest, file(model) { $0.bytes = 0 }] }, .badSize),
            (pack { $0.files = [manifest, file(model) { $0.bytes = -5 }] }, .badSize),
            (sized([manifest, file(model) { $0.bytes = 200 * mb + 1 }]), .tooLarge),
            (sized([file(manifest) { $0.bytes = mb + 1 }, model]), .tooLarge),
            (sized([manifest, file(model) { $0.bytes = 200 * mb }, file(model) { $0.name = "b.glb"; $0.bytes = 50 * mb }]), .tooLarge),
            (pack { $0.bytes += 1 }, .sizeMismatch),
            (pack { $0.bytes = 0 }, .sizeMismatch),
        ]
        for (pack, problem) in cases {
            let what = "\(pack.id) \(pack.files.map(\.name))"
            XCTAssertEqual(CatalogRules.problem(of: pack), problem, what)
            XCTAssertNil(CatalogRules.sanitize(pack), what)
        }
    }

    func testSizeLimitsAreInclusive() {
        let mb: Int64 = 1024 * 1024
        let files = [
            file(manifest) { $0.bytes = mb },
            file(model) { $0.bytes = 200 * mb },
            file(model) { $0.name = "b.glb"; $0.bytes = 49 * mb },
        ]
        XCTAssertNil(CatalogRules.problem(of: pack { $0.files = files; $0.bytes = 250 * mb }))
    }

    func testFileNameSafety() {
        for name in ["model.glb", "character.json", "Body_01-v2.glb", "a", "tex.0.png"] {
            XCTAssertTrue(CatalogRules.isSafeFileName(name), name)
        }
        let unsafe = [
            "", ".", "..", ".hidden", "a/b", "a\\b", "/abs", "..\\x", "a:b", "a b", "a\u{0000}b", "ż.glb", "a%2fb",
            repeated("x", 65),
        ]
        for name in unsafe {
            XCTAssertFalse(CatalogRules.isSafeFileName(name), name)
        }
    }

    func testIdSafety() {
        for id in ["stage_dummy", "a", "warrior-2", "0", repeated("x", 64)] {
            XCTAssertTrue(CatalogRules.isSafeId(id), id)
        }
        for id in ["", "A", "a.b", "a/b", "..", "a b", "ż", repeated("x", 65)] {
            XCTAssertFalse(CatalogRules.isSafeId(id), id)
        }
    }

    func testVersionSafety() {
        for version in ["3f9a0c2b7d11", "1.0", "v2_final-3", repeated("x", 64)] {
            XCTAssertTrue(CatalogRules.isVersion(version), version)
        }
        for version in ["", "../../x", "not a version!", "a/b", repeated("x", 65)] {
            XCTAssertFalse(CatalogRules.isVersion(version), version)
        }
    }

    func testChecksumHelpers() {
        XCTAssertEqual(
            CatalogRules.sha256Hex("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            CatalogRules.sha256Hex([UInt8]()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(CatalogRules.hex([0, 1, 127, 128, 255] as [UInt8]), "00017f80ff")
        XCTAssertEqual(
            CatalogRules.sha256Hex([1, 2, 3] as [UInt8]), "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81"
        )
        XCTAssertTrue(CatalogRules.isSha256(CatalogRules.sha256Hex([1, 2, 3] as [UInt8])))
    }

    /// The hash is written out in this package; these lengths sit on both sides of its padding boundaries.
    /// Expected values from `sha256sum`.
    func testSha256PaddingBoundaries() {
        XCTAssertEqual(
            CatalogRules.sha256Hex(repeated("a", 56).utf8), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
        )
        XCTAssertEqual(
            CatalogRules.sha256Hex(repeated("a", 64).utf8), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
        )
        XCTAssertEqual(
            CatalogRules.sha256Hex(repeated("a", 1000).utf8), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
        )
    }

    func testPackVersionIsTheHashOfTheSortedListing() {
        func remoteFile(_ name: String, _ content: String) -> RemoteFile {
            RemoteFile(name: name, bytes: Int64(content.utf8.count), sha256: CatalogRules.sha256Hex(content.utf8))
        }
        let json = remoteFile("character.json", "a")
        let glb = remoteFile("model.glb", "b")
        // sha256("character.json:<sha256 of a>\nmodel.glb:<sha256 of b>\n"), computed with sha256sum.
        XCTAssertEqual(CatalogRules.packVersion([json, glb]), "66a17540ef35")
        XCTAssertEqual(CatalogRules.packVersion([glb, json]), "66a17540ef35")
        XCTAssertEqual(CatalogRules.packVersion([json, remoteFile("model.glb", "c")]), "a603e99d927f")
    }

    func testSanitizeCleansDisplayFieldsAndFillsInTheVersion() throws {
        let computed = CatalogRules.packVersion(good.files)
        XCTAssertEqual(computed, "0992207d32f6")
        XCTAssertEqual(CatalogRules.sanitize(pack { $0.version = "" })?.version, computed)
        XCTAssertEqual(CatalogRules.sanitize(pack { $0.version = "../../x" })?.version, computed)
        XCTAssertEqual(CatalogRules.sanitize(good)?.version, "3f9a0c2b7d11")

        let messy = try XCTUnwrap(CatalogRules.sanitize(pack {
            $0.name = "  Wo\njownik\u{0000} " + repeated("x", 200)
            $0.clips = -1
        }))
        XCTAssertEqual(messy.name.utf16.count, 80)
        XCTAssertTrue(messy.name.hasPrefix("Wojownik"))
        XCTAssertNil(messy.clips)
        XCTAssertNil(CatalogRules.sanitize(pack { $0.clips = 10_001 })?.clips)
        XCTAssertEqual(CatalogRules.sanitize(pack { $0.clips = 10_000 })?.clips, 10_000)

        XCTAssertEqual(good.displayName, "Stage Dummy")
        XCTAssertEqual(pack { $0.name = " " }.displayName, "stage dummy")
    }

    func testALabelIsNeverCutInsideOneCharacter() {
        // 79 letters and an emoji that takes two UTF-16 units: cutting at 80 would leave half of it.
        XCTAssertEqual(CatalogRules.cleanLabel(repeated("a", 79) + "\u{1F600}" + "tail"), repeated("a", 79))
        XCTAssertEqual(CatalogRules.cleanLabel(repeated("a", 78) + "\u{1F600}" + "tail"), repeated("a", 78) + "\u{1F600}")
        XCTAssertEqual(CatalogRules.cleanLabel(" \u{200B}\u{0000} "), "")
        // A right-to-left override would turn the rest of a row around.
        XCTAssertEqual(CatalogRules.cleanLabel("Wojownik\u{202E}\u{0007} x"), "Wojownik x")
        XCTAssertEqual(CatalogRules.cleanLabel(" Krótka nazwa "), "Krótka nazwa")
    }

    func testValidPacksKeepsTheFirstOfADuplicateIdAndDropsBadOnes() {
        let twin = pack { $0.name = "Second" }
        let other = pack { $0.id = "other" }
        let bad = pack { $0.id = "BAD" }
        XCTAssertEqual(CatalogRules.validPacks([good, bad, twin, other]), [good, other])
    }

    func testValidPacksIsCapped() {
        let many = (0..<(CatalogRules.maxPacks + 50)).map { index in pack { $0.id = "p\(index)" } }
        let kept = CatalogRules.validPacks(many)
        XCTAssertEqual(kept.count, 2000)
        XCTAssertEqual(kept.last?.id, "p1999")
    }

    func testParsesTheDocumentedCatalog() throws {
        let text = """
        { "format": 1, "updated": "2026-11-11T10:00:00Z", "generator": "pack-tool",
          "characters": [ { "id": "stage_dummy", "name": "Stage Dummy", "version": "3f9a0c2b7d11", "clips": 9,
              "bytes": 243456, "thumbnail": "x.png",
              "files": [ { "name": "character.json", "bytes": 892, "sha256": "\(repeated("a", 64))", "extra": 1 },
                         { "name": "model.glb", "bytes": 242564, "sha256": "\(repeated("b", 64))" } ] } ] }
        """
        let catalog = try XCTUnwrap(CatalogRules.parse(text))
        XCTAssertEqual(catalog.updated, "2026-11-11T10:00:00Z")
        XCTAssertEqual(catalog.characters, [good])
        XCTAssertEqual(CatalogRules.parse(catalogJSON([good]))?.characters, [good])
        XCTAssertEqual(CatalogRules.parse(data: Data(text.utf8)), catalog)
    }

    func testAnEmptyCatalogIsValid() {
        XCTAssertEqual(CatalogRules.parse(#"{ "format": 1, "characters": [] }"#)?.characters, [])
        XCTAssertEqual(CatalogRules.parse("{}")?.characters, [])
    }

    func testOptionalFieldsOfAnEntryMayBeLeftOutOrNull() throws {
        let files = #"[{"name":"character.json","bytes":892,"sha256":"\#(repeated("a", 64))"},{"name":"model.glb","bytes":242564,"sha256":"\#(repeated("b", 64))"}]"#
        let text = #"{ "characters": [ { "id": "stage_dummy", "name": null, "version": null, "clips": null, "bytes": 243456, "files": \#(files) } ] }"#
        let entry = try XCTUnwrap(CatalogRules.parse(text)?.characters.first)
        XCTAssertEqual(entry.name, "")
        XCTAssertEqual(entry.displayName, "stage dummy")
        XCTAssertNil(entry.clips)
        // A version that is left out is worked out from the files.
        XCTAssertEqual(entry.version, "0992207d32f6")
    }

    func testAMalformedEntryCostsOnlyItself() {
        let whole = catalogJSON([good])
        let entry = whole[whole.range(of: #""characters":["#)!.upperBound...].dropLast(2)
        let text = """
        { "format": 1, "characters": [
            { "id": "broken", "bytes": "many", "files": "none" },
            42,
            { "id": "half", "bytes": 1, "files": [ { "name": "character.json" } ] },
            \(entry)
        ] }
        """
        XCTAssertEqual(CatalogRules.parse(text)?.characters, [good])
    }

    func testUnusableDocumentsAreBadData() {
        let unusable = [
            "",
            "not json",
            "<html><body>404</body></html>",
            "[]",
            "\"catalog\"",
            #"{ "format": 2, "characters": [] }"#,
            #"{ "format": "one", "characters": [] }"#,
            #"{ "format": null, "characters": [] }"#,
            #"{ "format": 1, "characters": {} }"#,
            #"{ "format": 1, "characters": [ { "id": "BAD" } ] }"#,
            catalogJSON([pack { $0.bytes = 1 }]),
        ]
        for text in unusable {
            XCTAssertNil(CatalogRules.parse(text), text)
        }
    }

    func testProgressArithmetic() {
        XCTAssertEqual(PackProgress.fraction(receivedBytes: 0, totalBytes: 1000), 0)
        XCTAssertEqual(PackProgress.fraction(receivedBytes: 250, totalBytes: 1000), 0.25, accuracy: 1e-6)
        XCTAssertEqual(PackProgress.fraction(receivedBytes: 1000, totalBytes: 1000), 1)
        XCTAssertEqual(PackProgress.fraction(receivedBytes: 1500, totalBytes: 1000), 1)
        XCTAssertEqual(PackProgress.fraction(receivedBytes: -10, totalBytes: 1000), 0)
        XCTAssertEqual(PackProgress.fraction(receivedBytes: 10, totalBytes: 0), 0)
        XCTAssertEqual(PackProgress.fraction(receivedBytes: 10, totalBytes: -1), 0)
        // Two files of one pack: progress is counted over the whole pack, not per file.
        XCTAssertEqual(PackProgress.fraction(receivedBytes: 892 + 120_836, totalBytes: 243_456), 0.5, accuracy: 1e-6)
        XCTAssertEqual(PackProgress.fraction(receivedBytes: 249_750_000, totalBytes: 250_000_000), 0.999, accuracy: 1e-6)

        XCTAssertEqual(PackProgress.percent(0.009), 0)
        XCTAssertEqual(PackProgress.percent(0.01), 1)
        XCTAssertEqual(PackProgress.percent(0.999), 99)
        XCTAssertEqual(PackProgress.percent(1), 100)
        XCTAssertEqual(PackProgress.percent(7), 100)
        XCTAssertEqual(PackProgress.percent(-1), 0)
        XCTAssertEqual(PackProgress.percent(.nan), 0)
    }
}

final class NameOrderTests: XCTestCase {

    func testOrdersByThePolishAlphabet() {
        let names = ["Żuk", "zamek", "Źrebak", "Śnieg", "sowa", "Łoś", "lis", "Ćma", "cebula", "Ąkacja", "Ala", "Ósemka", "Owca"]
        XCTAssertEqual(
            NameOrder.sorted(names, by: { $0 }),
            ["Ala", "Ąkacja", "cebula", "Ćma", "lis", "Łoś", "Owca", "Ósemka", "sowa", "Śnieg", "zamek", "Źrebak", "Żuk"]
        )
    }

    func testPackNamesInPolishOrder() {
        let names = ["Zabójca", "Żołnierz", "Łucznik", "Świątynny strażnik", "Mag", "Szaman", "łowca", "Ćma", "Czarodziej"]
        XCTAssertEqual(
            NameOrder.sorted(names, by: { $0 }),
            ["Czarodziej", "Ćma", "łowca", "Łucznik", "Mag", "Szaman", "Świątynny strażnik", "Zabójca", "Żołnierz"]
        )
    }

    func testLetterCaseOnlyBreaksTies() {
        XCTAssertEqual(
            NameOrder.sorted(["Rycerz", "mag ognia", "Mag", "mag"], by: { $0 }),
            ["mag", "Mag", "mag ognia", "Rycerz"]
        )
    }

    func testEqualNamesKeepTheirOrder() {
        let items = [(name: "Mag", tag: 1), (name: "Ala", tag: 2), (name: "Mag", tag: 3), (name: "Mag", tag: 4)]
        XCTAssertEqual(NameOrder.sorted(items, by: { $0.name }).map { $0.tag }, [2, 1, 3, 4])
    }

    func testSearchIgnoresCaseAndDiacritics() {
        XCTAssertEqual(NameOrder.searchKey("Łucznik"), "lucznik")
        XCTAssertEqual(NameOrder.searchKey("Świątynny STRAŻNIK"), "swiatynny straznik")
        XCTAssertEqual(NameOrder.searchKey("Żółć gęślą jaźń"), "zolc gesla jazn")
        XCTAssertEqual(NameOrder.searchKey(""), "")
        XCTAssertTrue(NameOrder.searchKey("Żołnierz").contains(NameOrder.searchKey("zol")))
        XCTAssertTrue(NameOrder.searchKey("zolnierz").contains(NameOrder.searchKey("ŻOŁ")))
        XCTAssertFalse(NameOrder.searchKey("Żołnierz").contains(NameOrder.searchKey("mag")))
    }
}

final class LibraryTextTests: XCTestCase {

    func testEveryDownloadErrorHasItsOwnMessage() {
        let messages = DownloadError.allCases.map { LibraryMessages.downloadFailed("Wojownik", error: $0) }
        XCTAssertEqual(DownloadError.allCases.count, 6)
        XCTAssertEqual(Set(messages).count, DownloadError.allCases.count)
        let lead = "Nie udało się pobrać „Wojownik” — "
        for message in messages {
            XCTAssertTrue(message.hasPrefix(lead), message)
            XCTAssertFalse(message.dropFirst(lead.count).trimmingCharacters(in: .whitespaces).isEmpty, message)
        }
        XCTAssertEqual(
            LibraryMessages.downloadFailed("Wojownik", error: .offline),
            "Nie udało się pobrać „Wojownik” — brak połączenia z internetem"
        )
    }

    func testFinishedDownloads() {
        XCTAssertEqual(LibraryMessages.downloaded("Wojownik"), "Pobrano: Wojownik")
        XCTAssertEqual(LibraryMessages.downloadedStageFull("Wojownik"), "Pobrano: Wojownik. Scena jest pełna")
        XCTAssertEqual(
            LibraryMessages.updatedOnStage("Wojownik"),
            "Zaktualizowano: Wojownik. Nową wersję zobaczysz po ponownym dodaniu postaci"
        )
    }

    func testFileSizes() {
        XCTAssertEqual(LibraryFormat.fileSize(0), "0 B")
        XCTAssertEqual(LibraryFormat.fileSize(-5), "0 B")
        XCTAssertEqual(LibraryFormat.fileSize(999), "999 B")
        XCTAssertEqual(LibraryFormat.fileSize(1_000), "1 kB")
        XCTAssertEqual(LibraryFormat.fileSize(243_456), "243 kB")
        XCTAssertEqual(LibraryFormat.fileSize(999_499), "999 kB")
        // Where rounding would print "1000 kB" the next unit takes over.
        XCTAssertEqual(LibraryFormat.fileSize(999_500), "1,0 MB")
        XCTAssertEqual(LibraryFormat.fileSize(12_400_000), "12,4 MB")
        XCTAssertEqual(LibraryFormat.fileSize(999_949_999), "999,9 MB")
        XCTAssertEqual(LibraryFormat.fileSize(999_950_000), "1,0 GB")
        XCTAssertEqual(LibraryFormat.fileSize(Int64.max), "1000000,0 GB")
    }

    func testPolishPluralOfAnimations() {
        XCTAssertEqual(LibraryFormat.animations(0), "0 animacji")
        XCTAssertEqual(LibraryFormat.animations(1), "1 animacja")
        XCTAssertEqual(LibraryFormat.animations(3), "3 animacje")
        XCTAssertEqual(LibraryFormat.animations(5), "5 animacji")
        XCTAssertEqual(LibraryFormat.animations(12), "12 animacji")
        XCTAssertEqual(LibraryFormat.animations(22), "22 animacje")
        XCTAssertEqual(LibraryFormat.animations(104), "104 animacje")
        XCTAssertEqual(LibraryFormat.animations(112), "112 animacji")
    }

    func testCaptionOfALibraryRow() {
        XCTAssertEqual(LibraryFormat.remotePackCaption(bytes: 243_456, clips: 9), "243 kB • 9 animacji")
        XCTAssertEqual(LibraryFormat.remotePackCaption(bytes: 243_456, clips: nil), "243 kB")
        XCTAssertEqual(LibraryFormat.remotePackCaption(bytes: 243_456, clips: -1), "243 kB")
        XCTAssertEqual(LibraryFormat.remotePackCaption(bytes: 0, clips: 1), "1 animacja")
        XCTAssertEqual(LibraryFormat.remotePackCaption(bytes: 0, clips: nil), "")
    }
}

final class LibraryRulesTests: XCTestCase {

    private func remote(_ id: String, _ name: String, version: String = "aaaaaaaaaaaa") -> RemotePack {
        RemotePack(id: id, name: name, version: version)
    }

    func testEntriesAreListedByNameWithoutRepeatedIds() {
        let entries = LibraryRules.entries([
            remote("zolnierz", "Żołnierz"), remote("mag", "Mag"), remote("lucznik", "Łucznik"),
            remote("mag", "Mag po raz drugi"), remote("no_name", ""),
        ])
        XCTAssertEqual(entries.map(\.id), ["lucznik", "mag", "no_name", "zolnierz"])
        XCTAssertEqual(entries.map(\.searchKey), ["lucznik", "mag", "no name", "zolnierz"])
    }

    func testOnlyADownloadedCopyTakesAnEntryOffTheOffer() {
        let entries = LibraryRules.entries([remote("mag", "Mag"), remote("lucznik", "Łucznik"), remote("zolnierz", "Żołnierz")])
        XCTAssertEqual(LibraryRules.available(entries, downloadedIds: []).map(\.id), ["lucznik", "mag", "zolnierz"])
        XCTAssertEqual(LibraryRules.available(entries, downloadedIds: ["mag"]).map(\.id), ["lucznik", "zolnierz"])
        // What the creator typed narrows the offer, without letter case and diacritics.
        let needle = NameOrder.searchKey("ŁUCZ")
        XCTAssertEqual(LibraryRules.available(entries, downloadedIds: [], needleKey: needle).map(\.id), ["lucznik"])
        XCTAssertEqual(LibraryRules.available(entries, downloadedIds: ["lucznik"], needleKey: needle), [])
        XCTAssertTrue(LibraryRules.matches(name: "Świątynny strażnik", needleKey: NameOrder.searchKey("straz")))
        XCTAssertFalse(LibraryRules.matches(name: "Mag", needleKey: NameOrder.searchKey("straz")))
        XCTAssertTrue(LibraryRules.matches(name: "Mag", needleKey: ""))
    }

    func testAnUpdateWaitsWhenTheCatalogVersionDiffers() {
        XCTAssertTrue(LibraryRules.hasUpdate(installedVersion: "aaaaaaaaaaaa", remoteVersion: "bbbbbbbbbbbb"))
        XCTAssertFalse(LibraryRules.hasUpdate(installedVersion: "aaaaaaaaaaaa", remoteVersion: "aaaaaaaaaaaa"))
        // A downloaded pack whose version file could not be read differs from whatever the catalog offers.
        XCTAssertTrue(LibraryRules.hasUpdate(installedVersion: "", remoteVersion: "bbbbbbbbbbbb"))
        XCTAssertFalse(LibraryRules.hasUpdate(installedVersion: "aaaaaaaaaaaa", remoteVersion: ""))
        // A pack imported from a file is the creator's own model: the library never replaces it.
        XCTAssertFalse(LibraryRules.hasUpdate(installedVersion: nil, remoteVersion: "bbbbbbbbbbbb"))

        let entries = LibraryRules.entries([remote("mag", "Mag", version: "bbbbbbbbbbbb"), remote("lucznik", "Łucznik")])
        let updates = LibraryRules.updates(entries, installed: [
            (id: "mag", remoteVersion: "aaaaaaaaaaaa"),
            (id: "lucznik", remoteVersion: "aaaaaaaaaaaa"),
            (id: "own", remoteVersion: nil),
            (id: "gone", remoteVersion: "cccccccccccc"),
        ])
        XCTAssertEqual(Array(updates.keys), ["mag"])
        XCTAssertEqual(updates["mag"]?.version, "bbbbbbbbbbbb")
        XCTAssertEqual(LibraryRules.updates(entries, installed: [(id: "mag", remoteVersion: nil)]), [:])
    }

    func testTheSearchFieldComesWithALongListAndStaysUnderAQuery() {
        XCTAssertFalse(LibraryRules.showsSearch(query: "", installedCount: 3, availableCount: 5))
        XCTAssertTrue(LibraryRules.showsSearch(query: "", installedCount: 3, availableCount: 6))
        XCTAssertTrue(LibraryRules.showsSearch(query: "x", installedCount: 0, availableCount: 0))
    }
}

final class PackStoreRulesTests: XCTestCase {

    func testAnUnreadableVersionStillMarksADownloadedPack() {
        XCTAssertEqual(PackStoreRules.storedVersion("3f9a0c2b7d11\n"), "3f9a0c2b7d11")
        XCTAssertEqual(PackStoreRules.storedVersion("not a version!\n"), "")
        XCTAssertEqual(PackStoreRules.storedVersion(""), "")
        XCTAssertEqual(PackStoreRules.storedVersion(nil), "")
    }

    func testTheVersionFileCannotComeFromTheCatalog() {
        XCTAssertFalse(CatalogRules.isSafeFileName(PackStoreRules.versionFile))
        // Nor can a pack id collide with the folders the library keeps for itself.
        for prefix in [PackStoreRules.stagingPrefix, PackStoreRules.importPrefix, PackStoreRules.backupPrefix] {
            XCTAssertFalse(CatalogRules.isSafeId(prefix + "hero"))
        }
    }

    func testWhatTheImporterProducesIsAlwaysAPackId() {
        XCTAssertTrue(CatalogRules.isSafeId(PackRules.sanitizeId("Wojownik (kopia).glb")))
        let taken: Set<String> = ["hero", "hero_2"]
        XCTAssertTrue(CatalogRules.isSafeId(PackRules.uniqueId(PackRules.sanitizeId("HERO")) { taken.contains($0) }))
        XCTAssertEqual(PackRules.uniqueId(PackRules.sanitizeId("HERO")) { taken.contains($0) }, "hero_3")
    }

    func testCleanUpAfterAKilledProcess() {
        // A download and an import that were running, a pack caught mid-swap, and a swap that had already finished.
        let present: Set<String> = [".download-half-3", ".import-77", ".replaced-caught", ".replaced-done", "done", "hero"]
        func leftover(_ name: String) -> PackStoreRules.Leftover {
            PackStoreRules.leftover(named: name) { present.contains($0) }
        }
        XCTAssertEqual(leftover(".download-half-3"), .remove)
        XCTAssertEqual(leftover(".import-77"), .remove)
        XCTAssertEqual(leftover(".replaced-caught"), .restore(id: "caught"))
        XCTAssertEqual(leftover(".replaced-done"), .remove)
        XCTAssertEqual(leftover("done"), .keep)
        XCTAssertEqual(leftover("hero"), .keep)
        XCTAssertEqual(leftover("stray.txt"), .keep)
        // A backup whose name is not a pack id is nobody's pack.
        XCTAssertEqual(leftover(".replaced-../x"), .remove)
        XCTAssertEqual(leftover(".replaced-"), .remove)
    }

    func testEveryAttemptGetsAStagingFolderOfItsOwn() {
        let first = PackStoreRules.stagingName(packId: "hero", attempt: "1")
        let second = PackStoreRules.stagingName(packId: "hero", attempt: "2")
        XCTAssertEqual(first, ".download-hero-1")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(PackStoreRules.leftover(named: first) { _ in false }, .remove)
    }
}

final class PackServerRulesTests: XCTestCase {

    /// The address the app is built with. Only its text is used here; nothing is requested.
    private let defaultBase = "https://mon2farma.fra1.digitaloceanspaces.com/monastyr2ar"

    func testABaseWithAPathKeepsIt() throws {
        for written in [defaultBase, defaultBase + "/", defaultBase + "//", "  " + defaultBase + "/\n"] {
            let base = try XCTUnwrap(PackServerRules.normalizedBase(written), written)
            XCTAssertEqual(base, defaultBase)
            XCTAssertEqual(
                PackServerRules.catalogURL(base: base)?.absoluteString,
                "https://mon2farma.fra1.digitaloceanspaces.com/monastyr2ar/catalog.json"
            )
            XCTAssertEqual(
                PackServerRules.fileURL(base: base, packId: "stage_dummy", fileName: "model.glb")?.absoluteString,
                "https://mon2farma.fra1.digitaloceanspaces.com/monastyr2ar/characters/stage_dummy/model.glb"
            )
        }
        let url = try XCTUnwrap(PackServerRules.catalogURL(base: defaultBase))
        XCTAssertEqual(url.host, "mon2farma.fra1.digitaloceanspaces.com")
        XCTAssertEqual(url.path, "/monastyr2ar/catalog.json")
    }

    func testABaseWithoutAPath() throws {
        for written in ["http://192.168.0.10:8787", "http://192.168.0.10:8787/"] {
            let base = try XCTUnwrap(PackServerRules.normalizedBase(written), written)
            XCTAssertEqual(base, "http://192.168.0.10:8787")
            XCTAssertEqual(PackServerRules.catalogURL(base: base)?.absoluteString, "http://192.168.0.10:8787/catalog.json")
            XCTAssertEqual(
                PackServerRules.fileURL(base: base, packId: "hero", fileName: "character.json")?.absoluteString,
                "http://192.168.0.10:8787/characters/hero/character.json"
            )
        }
        XCTAssertEqual(PackServerRules.normalizedBase("https://packs.test/a/b/"), "https://packs.test/a/b")
    }

    func testWhatIsNotAnAddressIsRefused() {
        for written in ["", "   ", "no scheme at all", "packs.test", "ftp://packs.test", "file:///etc/hosts", "https://", "https://packs.test/?x=1", "https://packs.test/#top"] {
            XCTAssertNil(PackServerRules.normalizedBase(written), written)
        }
    }

    func testOnlyValidatedNamesBecomeAddresses() {
        let base = "https://packs.test"
        XCTAssertNil(PackServerRules.fileURL(base: base, packId: "../hero", fileName: "model.glb"))
        XCTAssertNil(PackServerRules.fileURL(base: base, packId: "hero", fileName: "../model.glb"))
        XCTAssertNil(PackServerRules.fileURL(base: base, packId: "hero", fileName: ".remote-version"))
        XCTAssertNil(PackServerRules.fileURL(base: base, packId: "hero", fileName: "a b.glb"))
    }

    func testPlainHttpIsRefusedUnlessTheBaseItselfIsHttp() throws {
        XCTAssertFalse(PackServerRules.allowsPlainHTTP(base: defaultBase))
        XCTAssertTrue(PackServerRules.allowsPlainHTTP(base: "http://127.0.0.1:8787"))
        XCTAssertTrue(PackServerRules.allowsPlainHTTP(base: "HTTP://localhost:8787"))

        let secure = try XCTUnwrap(URL(string: "https://packs.test/file"))
        let plain = try XCTUnwrap(URL(string: "http://127.0.0.1:8787/file"))
        XCTAssertTrue(PackServerRules.isAllowedScheme(secure, allowHTTP: false))
        XCTAssertFalse(PackServerRules.isAllowedScheme(plain, allowHTTP: false))
        XCTAssertTrue(PackServerRules.isAllowedScheme(plain, allowHTTP: true))
        for other in ["ftp://127.0.0.1/file", "file:///etc/hosts"] {
            XCTAssertFalse(PackServerRules.isAllowedScheme(try XCTUnwrap(URL(string: other)), allowHTTP: true), other)
        }
    }

    func testRedirectsStayOnTheHostAndNeverGoDownToHttp() throws {
        func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }
        let from = try url("https://packs.test/monastyr2ar/old")
        XCTAssertTrue(PackServerRules.isAllowedRedirect(from: from, to: try url("https://packs.test/moved/file"), allowHTTP: false))
        XCTAssertTrue(PackServerRules.isAllowedRedirect(from: from, to: try url("https://PACKS.test/moved/file"), allowHTTP: false))
        XCTAssertFalse(PackServerRules.isAllowedRedirect(from: from, to: try url("https://elsewhere.test/moved/file"), allowHTTP: false))
        XCTAssertFalse(PackServerRules.isAllowedRedirect(from: from, to: try url("http://packs.test/moved/file"), allowHTTP: false))
        // "localhost" may be the very same machine, but it is not the host the app was told to use.
        let local = try url("http://127.0.0.1:8787/away")
        XCTAssertTrue(PackServerRules.isAllowedRedirect(from: local, to: try url("http://127.0.0.1:8787/target"), allowHTTP: true))
        XCTAssertFalse(PackServerRules.isAllowedRedirect(from: local, to: try url("http://localhost:8787/target"), allowHTTP: true))
        XCTAssertEqual(PackServerRules.maxRedirects, 5)
    }

    func testAnAnnouncedSizeThatDisagreesIsRefused() {
        XCTAssertTrue(PackServerRules.announcedLengthMatches(announced: 100_000, listed: 100_000))
        XCTAssertTrue(PackServerRules.announcedLengthMatches(announced: -1, listed: 100_000))
        XCTAssertFalse(PackServerRules.announcedLengthMatches(announced: 150_000, listed: 100_000))
        XCTAssertFalse(PackServerRules.announcedLengthMatches(announced: 50_000, listed: 100_000))
        XCTAssertFalse(PackServerRules.announcedLengthMatches(announced: 0, listed: 100_000))
    }

    func testErrorMapping() {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed, .dataNotAllowed] {
            XCTAssertEqual(PackServerRules.fault(for: code), .offline, "\(code.rawValue)")
        }
        for code in [URLError.Code.badServerResponse, .cannotParseResponse, .httpTooManyRedirects, .redirectToNonExistentLocation, .appTransportSecurityRequiresSecureConnection, .zeroByteResource] {
            XCTAssertEqual(PackServerRules.fault(for: code), .server, "\(code.rawValue)")
        }
        XCTAssertEqual(PackServerRules.downloadError(for: .server), .server)
        XCTAssertEqual(PackServerRules.downloadError(for: .offline), .offline)
        XCTAssertEqual(PackServerRules.catalogError(for: .server), .server)
        XCTAssertEqual(PackServerRules.catalogError(for: .offline), .offline)
    }
}

/// The catalog tool promises to list only packs the app can install. Both sides read the same cases
/// (`tools/test/fixtures/manifest-cases.json`): `tools/test/catalog-check.mjs` runs them through the tool,
/// `ManifestRulesTest` of the Android app through its parser, this test through the parser of the iOS app.
///
/// Only the "accepted" half is checked here. The iOS parser is deliberately more forgiving than the Android one
/// (see `CharacterManifest.parse`), so it also reads most of the "refused" cases; that is harmless, because a
/// manifest the tool refuses never reaches the server.
final class ManifestCasesTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let id: String
            let manifest: String
        }

        let refused: [Case]
        let accepted: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = repositoryRoot().appendingPathComponent("tools/test/fixtures/manifest-cases.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("tools/ is not next to the package")
        }
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testWhatTheToolCataloguesTheAppCanRead() throws {
        let accepted = try fixture().accepted
        XCTAssertGreaterThanOrEqual(accepted.count, 3)
        for entry in accepted {
            let manifest = CharacterManifest.parse(entry.manifest, fallbackId: entry.id)
            XCTAssertNotNil(manifest, "\(entry.id): \(entry.manifest)")
            XCTAssertEqual(manifest?.id, entry.id)
            XCTAssertEqual(manifest?.model, "model.glb", entry.id)
        }
    }

    func testARefusedManifestNeverBreaksTheParser() throws {
        // Whatever the answer is, it is an answer: no case may trap.
        for entry in try fixture().refused {
            _ = CharacterManifest.parse(entry.manifest, fallbackId: entry.id)
        }
    }
}
