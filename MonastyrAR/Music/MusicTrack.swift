import Foundation

/// A backing track for recordings. Port of `music/MusicTrack.kt`.
struct MusicTrack: Equatable, Identifiable, Sendable {
    /// Stable between launches: the manifest id of a built-in track, `import:<file name>` of an imported one.
    let id: String
    let title: String
    /// The audio file: inside the app bundle (built-in) or in the app's own music folder (imported).
    let url: URL
    /// Length of one pass through the track, when it is known.
    let seconds: Float?
    let isBuiltIn: Bool
}
