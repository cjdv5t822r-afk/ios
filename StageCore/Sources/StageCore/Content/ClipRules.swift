import Foundation

/// Naming rules that turn raw clip names into categories, loop defaults and labels.
/// Keep in sync with `ClipRules.kt` and `tools/pack-character.mjs` (same keyword lists, same order).
public enum ClipRules {

    // Attack is tested before move so "run_attack" counts as an attack. English and Polish keywords.
    // The Kotlin source writes these as regex alternations of plain words; "contains any of" is the same test.
    private static let rules: [(ClipCategory, [String])] = [
        (.attack, [
            "attack", "atk", "combo", "slash", "skill", "strike", "hit", "punch", "kick", "shoot", "cast", "spell",
            "stab", "swing", "atak", "cios", "uderz", "ciecie", "cięcie", "umiej",
        ]),
        (.idle, ["idle", "wait", "stand", "breath", "rest", "stanie", "czeka", "bezczyn", "postoj", "postój"]),
        (.move, ["walk", "run", "sprint", "move", "step", "jog", "chod", "chód", "bieg", "krok", "marsz"]),
        (.emote, [
            "dance", "wave", "cheer", "emot", "laugh", "clap", "bow", "jump", "taunt", "congrat", "joy", "kiss",
            "cry", "sad", "angry", "greet", "victory", "pose", "taniec", "tanc", "tańc", "macha", "wiwat", "skok",
            "uklon", "ukłon", "smiech", "śmiech", "rados", "radoś", "brawo", "placz", "płacz",
        ]),
    ]
    private static let loopHints = ["dance", "cheer", "loop", "taniec", "tanc", "tańc", "wiwat"]

    public static func categoryOf(_ clipName: String) -> ClipCategory {
        let n = clipName.lowercased()
        for (category, keywords) in rules where keywords.contains(where: { n.contains($0) }) {
            return category
        }
        return .other
    }

    public static func loopsByDefault(_ clipName: String, category: ClipCategory) -> Bool {
        if category == .idle || category == .move { return true }
        let n = clipName.lowercased()
        return loopHints.contains { n.contains($0) }
    }

    /// `Attack_Slash` -> `Attack Slash`, `walkCycle` -> `walk Cycle`.
    public static func prettyLabel(_ name: String) -> String {
        let label = name
            .replacingOccurrences(of: "[_\\-.]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? name : label
    }

    private static let categoryOrder: [ClipCategory] = [.idle, .move, .attack, .emote, .other]

    /// Merges the clips found in the GLB with the manifest. Manifest entries win; clips the manifest does not
    /// mention are categorised by name. Manifest order is kept, unlisted clips follow grouped by category.
    public static func buildClips(manifest: CharacterManifest, raw: [RawClip]) -> [Clip] {
        var overrides: [String: AnimationEntry] = [:]
        var manifestOrder: [String: Int] = [:]
        for (i, entry) in manifest.animations.enumerated() {
            overrides[entry.clip] = entry
            manifestOrder[entry.clip] = i
        }
        let clips: [Clip] = raw.compactMap { r in
            let o = overrides[r.name]
            if o?.hidden == true { return nil }
            let category = o?.category ?? categoryOf(r.name)
            let label: String
            if let custom = o?.label, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                label = custom
            } else {
                label = prettyLabel(r.name)
            }
            return Clip(
                index: r.index,
                name: r.name,
                label: label,
                category: category,
                loop: o?.loop ?? loopsByDefault(r.name, category: category),
                durationSeconds: r.durationSeconds
            )
        }
        func key(_ c: Clip) -> (Int, Int, Int) {
            (manifestOrder[c.name] ?? Int.max, categoryOrder.firstIndex(of: c.category) ?? categoryOrder.count, c.index)
        }
        return clips.sorted { key($0) < key($1) }
    }

    /// The clip a character rests in: the manifest's choice, else the first idle clip, else nothing.
    public static func defaultClip(manifest: CharacterManifest, clips: [Clip]) -> Clip? {
        if let wanted = manifest.defaultAnimation, let match = clips.first(where: { $0.name == wanted }) {
            return match
        }
        return clips.first { $0.category == .idle }
    }
}
