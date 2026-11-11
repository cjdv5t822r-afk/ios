import Foundation

public enum ClipCategory: String, CaseIterable, Sendable {
    case idle, move, attack, emote, other
}

/// One entry of `animations` in `character.json`: overrides for a single clip.
public struct AnimationEntry: Equatable, Sendable {
    /// Clip name exactly as stored in the GLB.
    public var clip: String
    public var label: String?
    public var category: ClipCategory?
    public var loop: Bool?
    /// Hide a clip from the UI (helper poses, broken exports).
    public var hidden: Bool

    public init(clip: String, label: String? = nil, category: ClipCategory? = nil, loop: Bool? = nil, hidden: Bool = false) {
        self.clip = clip
        self.label = label
        self.category = category
        self.loop = loop
        self.hidden = hidden
    }
}

/// `character.json` of a character pack. Written by `tools/pack-character.mjs`, hand-editable.
/// Every field is optional, so a pack can be as small as `{}` next to a `model.glb`.
/// Same schema as `content/CharacterPack.kt`.
public struct CharacterManifest: Equatable, Sendable {
    public var format: Int
    /// Left out or blank in a manifest that leaves the id to the pack's folder, as the catalog tool allows.
    public var id: String
    public var name: String
    /// GLB file name inside the pack folder.
    public var model: String
    /// Multiplier applied to the model's own units. Ignored when `heightMeters` is set.
    public var scale: Float
    /// If set, the model is scaled so its rest-pose bounding box is this tall.
    public var heightMeters: Float?
    /// Extra yaw in degrees for models that do not face +Z.
    public var rotationY: Float
    /// Raw clip name played when the character appears and after every one-shot clip.
    public var defaultAnimation: String?
    /// Overrides per clip. Clips not listed here still show up, categorised by `ClipRules`.
    public var animations: [AnimationEntry]

    public init(
        format: Int = 1,
        id: String,
        name: String = "",
        model: String = CharacterManifest.defaultModelFile,
        scale: Float = 1,
        heightMeters: Float? = nil,
        rotationY: Float = 0,
        defaultAnimation: String? = nil,
        animations: [AnimationEntry] = []
    ) {
        self.format = format
        self.id = id
        self.name = name
        self.model = model
        self.scale = scale
        self.heightMeters = heightMeters
        self.rotationY = rotationY
        self.defaultAnimation = defaultAnimation
        self.animations = animations
    }

    public static let defaultModelFile = "model.glb"
    public static let fileName = "character.json"

    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ClipRules.prettyLabel(id) : name
    }
}

/// One animation clip of a loaded model, as read from the GLB (before manifest overrides).
public struct RawClip: Equatable, Sendable {
    /// Index in the model's animation list.
    public var index: Int
    public var name: String
    public var durationSeconds: Float

    public init(index: Int, name: String, durationSeconds: Float) {
        self.index = index
        self.name = name
        self.durationSeconds = durationSeconds
    }
}

/// A clip ready for the UI: the GLB data merged with the manifest overrides and the naming rules.
public struct Clip: Equatable, Identifiable, Sendable {
    public var index: Int
    public var name: String
    public var label: String
    public var category: ClipCategory
    public var loop: Bool
    public var durationSeconds: Float

    public init(index: Int, name: String, label: String, category: ClipCategory, loop: Bool, durationSeconds: Float) {
        self.index = index
        self.name = name
        self.label = label
        self.category = category
        self.loop = loop
        self.durationSeconds = durationSeconds
    }

    public var id: Int { index }

    /// The same clip with the loop flag flipped (long press on a clip button).
    public func togglingLoop() -> Clip {
        var c = self
        c.loop.toggle()
        return c
    }
}

// MARK: - JSON

public extension CharacterManifest {

    /// Parses a `character.json`. A missing manifest (`text == nil`) gives a default one; a broken manifest gives nil
    /// (the pack is skipped rather than shown with wrong data).
    ///
    /// A little more tolerant than the Android parser (kotlinx with `isLenient` + `coerceInputValues`, which only
    /// forgives `null` and unknown category names): here a value of the wrong kind also falls back to the field's
    /// default, category names ignore case, and JSON5 (comments, trailing commas) is accepted. A hand-edited
    /// manifest that loads here can therefore still be refused on Android. Unknown keys are ignored on both.
    /// No field is required (a missing or blank `id` becomes `fallbackId`), but every `animations` entry needs
    /// its `clip`.
    ///
    /// A downloaded manifest is the server's text as much as the catalog is, and it is what the lists show once
    /// the pack is installed: the name and the clip labels go through `CatalogRules.cleanLabel`.
    static func parse(_ text: String?, fallbackId: String) -> CharacterManifest? {
        guard let text else { return CharacterManifest(id: fallbackId) }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        guard let data = text.data(using: .utf8),
              var manifest = try? decoder.decode(CharacterManifest.self, from: data)
        else { return nil }
        if manifest.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manifest.model = defaultModelFile
        }
        // The model must be a plain file name inside the pack folder.
        if manifest.model.contains("/") || manifest.model.contains("\\") || manifest.model.hasPrefix(".") {
            return nil
        }
        if manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manifest.id = fallbackId
        }
        manifest.name = CatalogRules.cleanLabel(manifest.name)
        for index in manifest.animations.indices {
            // The clip name is the key into the model and stays as it is.
            if let label = manifest.animations[index].label {
                manifest.animations[index].label = CatalogRules.cleanLabel(label)
            }
        }
        return manifest
    }

    /// Pretty-printed JSON with default values left out, as the Android app writes it.
    func jsonText() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{ \"id\": \"\(id)\" }"
        }
        return text
    }
}

extension CharacterManifest: Codable {

    private enum CodingKeys: String, CodingKey {
        case format, id, name, model, scale, heightMeters, rotationY, defaultAnimation, animations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A manifest may leave its id to the folder the pack is in; `parse` fills it in.
        self.init(id: c.lenientString(.id) ?? "")
        if let v = c.lenientNumber(.format), abs(v) < 1e9 { format = Int(v) }
        if let v = c.lenientString(.name) { name = v }
        if let v = c.lenientString(.model) { model = v }
        // A number too large for a Float would become infinity; it is treated like any other value of the wrong kind.
        if let v = c.lenientNumber(.scale), Float(v).isFinite { scale = Float(v) }
        if let v = c.lenientNumber(.heightMeters), Float(v).isFinite { heightMeters = Float(v) }
        if let v = c.lenientNumber(.rotationY), Float(v).isFinite { rotationY = Float(v) }
        defaultAnimation = c.lenientString(.defaultAnimation)
        if c.contains(.animations), (try? c.decodeNil(forKey: .animations)) != true {
            // A list that is there must be a list of well-formed entries; anything else is a broken manifest.
            animations = try c.decode([AnimationEntry].self, forKey: .animations)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if format != 1 { try c.encode(format, forKey: .format) }
        try c.encode(id, forKey: .id)
        if !name.isEmpty { try c.encode(name, forKey: .name) }
        if model != CharacterManifest.defaultModelFile { try c.encode(model, forKey: .model) }
        // Written as the shortest decimal that reads back to the same Float (1.8, not 1.7999999523162842).
        func shortest(_ value: Float) -> Double { Double(String(value)) ?? Double(value) }
        if scale != 1 { try c.encode(shortest(scale), forKey: .scale) }
        try c.encodeIfPresent(heightMeters.map(shortest), forKey: .heightMeters)
        if rotationY != 0 { try c.encode(shortest(rotationY), forKey: .rotationY) }
        try c.encodeIfPresent(defaultAnimation, forKey: .defaultAnimation)
        if !animations.isEmpty { try c.encode(animations, forKey: .animations) }
    }
}

extension AnimationEntry: Codable {

    private enum CodingKeys: String, CodingKey {
        case clip, label, category, loop, hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let clip = c.lenientString(.clip) else {
            throw DecodingError.keyNotFound(
                CodingKeys.clip, .init(codingPath: c.codingPath, debugDescription: "an animation entry needs its clip")
            )
        }
        self.init(clip: clip)
        label = c.lenientString(.label)
        // An unknown category name is treated like no category at all, and the naming rules decide.
        category = c.lenientString(.category).flatMap { ClipCategory(rawValue: $0.lowercased()) }
        loop = c.lenientBool(.loop)
        hidden = c.lenientBool(.hidden) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clip, forKey: .clip)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(category?.rawValue, forKey: .category)
        try c.encodeIfPresent(loop, forKey: .loop)
        if hidden { try c.encode(hidden, forKey: .hidden) }
    }
}

private extension KeyedDecodingContainer {

    /// A string, or a number / boolean written where a string was expected. Nil for null, a missing key or a container.
    func lenientString(_ key: Key) -> String? {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let b = try? decode(Bool.self, forKey: key) { return b ? "true" : "false" }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let d = try? decode(Double.self, forKey: key) { return String(d) }
        return nil
    }

    /// A finite number, or a string that holds one.
    func lenientNumber(_ key: Key) -> Double? {
        if let d = try? decode(Double.self, forKey: key) { return d.isFinite ? d : nil }
        if let s = try? decode(String.self, forKey: key),
           let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), d.isFinite {
            return d
        }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let b = try? decode(Bool.self, forKey: key) { return b }
        if let s = try? decode(String.self, forKey: key) {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }
}
