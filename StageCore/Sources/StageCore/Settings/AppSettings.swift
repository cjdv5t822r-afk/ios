import Foundation

public enum StageMode: String, CaseIterable, Sendable {
    case ar = "AR"
    case studio = "STUDIO"
}

/// Corner / edge of the 9:16 frame the logo is pinned to. Raw values are the names the Android app stores.
public enum WatermarkAnchor: String, CaseIterable, Sendable {
    case topLeft = "TOP_LEFT"
    case topCenter = "TOP_CENTER"
    case topRight = "TOP_RIGHT"
    case bottomLeft = "BOTTOM_LEFT"
    case bottomCenter = "BOTTOM_CENTER"
    case bottomRight = "BOTTOM_RIGHT"

    public var isTop: Bool { self == .topLeft || self == .topCenter || self == .topRight }
}

/// Solid backgrounds for Studio mode. `argb` is sRGB; `custom` uses `AppSettings.studioCustomColor`.
public enum StudioBackground: String, CaseIterable, Sendable {
    case green = "GREEN"
    case blue = "BLUE"
    case black = "BLACK"
    case white = "WHITE"
    case custom = "CUSTOM"

    public var argb: UInt32 {
        switch self {
        case .green: return 0xFF00_B140
        case .blue: return 0xFF00_47BB
        case .black: return 0xFF00_0000
        case .white: return 0xFFFF_FFFF
        case .custom: return 0xFF20_2020
        }
    }
}

/// Everything the creator can change in "Ustawienia". Same fields, defaults and limits as `settings/AppSettings.kt`.
public struct AppSettings: Equatable, Sendable {
    public var mode: StageMode = .ar
    public var lastCharacterId: String?

    // watermark
    public var watermarkEnabled = true
    public var watermarkAnchor: WatermarkAnchor = .topLeft
    /// Logo width as a fraction of the frame width, 0.12...0.6.
    public var watermarkWidth: Float = 0.30
    /// 0.2...1
    public var watermarkOpacity: Float = 0.92

    // recording
    /// 0 = start immediately, otherwise seconds counted down before recording / photo.
    public var countdownSeconds = 0
    /// 0 = no limit.
    public var maxDurationSeconds = 60
    public var recordMicrophone = false
    public var safeZoneGuides = false

    // music
    /// Id of the track written into recordings, or nil for none. A recording with music has no microphone sound.
    public var musicTrackId: String?
    /// Loudness of the music in the recording and from the speaker, 0.1...1.
    public var musicVolume: Float = 0.8
    /// Play the track through the speaker while recording, to move in time with it.
    public var musicGuide = true

    // AR look
    public var showPlanes = true
    public var groundShadow = true
    public var depthOcclusion = false

    // studio look
    public var studioBackground: StudioBackground = .green
    public var studioCustomColor: UInt32 = StudioBackground.custom.argb

    public var onboardingSeen = false

    public init() {}

    public var studioColorArgb: UInt32 {
        studioBackground == .custom ? studioCustomColor : studioBackground.argb
    }

    public static let watermarkWidthMin: Float = 0.12
    public static let watermarkWidthMax: Float = 0.60
    public static let watermarkOpacityMin: Float = 0.20
    public static let musicVolumeMin: Float = 0.10
    public static let countdownChoices = [0, 3, 5, 10]
    public static let maxDurationChoices = [15, 30, 60, 0]

    /// The same settings with every number forced into its allowed range.
    public func sanitized() -> AppSettings {
        var s = self
        s.watermarkWidth = AppSettings.clamp(watermarkWidth, AppSettings.watermarkWidthMin, AppSettings.watermarkWidthMax, fallback: 0.30)
        s.watermarkOpacity = AppSettings.clamp(watermarkOpacity, AppSettings.watermarkOpacityMin, 1, fallback: 0.92)
        s.countdownSeconds = min(max(countdownSeconds, 0), 30)
        s.maxDurationSeconds = min(max(maxDurationSeconds, 0), 600)
        if let id = musicTrackId, id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s.musicTrackId = nil }
        s.musicVolume = AppSettings.clamp(musicVolume, AppSettings.musicVolumeMin, 1, fallback: 0.8)
        s.studioCustomColor = studioCustomColor | 0xFF00_0000
        return s
    }

    private static func clamp(_ value: Float, _ low: Float, _ high: Float, fallback: Float) -> Float {
        value.isFinite ? min(max(value, low), high) : fallback
    }
}

// MARK: - Persistence

/// Key / value form of the settings, for `UserDefaults`. The key names are the ones the Android app uses in its
/// DataStore, so a settings dump means the same thing on both platforms.
public extension AppSettings {

    enum Keys {
        public static let mode = "mode"
        public static let lastCharacterId = "last_character"
        public static let watermarkEnabled = "wm_enabled"
        public static let watermarkAnchor = "wm_anchor"
        public static let watermarkWidth = "wm_width"
        public static let watermarkOpacity = "wm_opacity"
        public static let countdownSeconds = "countdown"
        public static let maxDurationSeconds = "max_duration"
        public static let recordMicrophone = "mic"
        public static let safeZoneGuides = "guides"
        public static let musicTrackId = "music_track"
        public static let musicVolume = "music_volume"
        public static let musicGuide = "music_guide"
        public static let showPlanes = "planes"
        public static let groundShadow = "shadow"
        public static let depthOcclusion = "occlusion"
        public static let studioBackground = "studio_bg"
        public static let studioCustomColor = "studio_custom"
        public static let onboardingSeen = "onboarding_seen"

        public static let all = [
            mode, lastCharacterId, watermarkEnabled, watermarkAnchor, watermarkWidth, watermarkOpacity,
            countdownSeconds, maxDurationSeconds, recordMicrophone, safeZoneGuides, showPlanes, groundShadow,
            depthOcclusion, studioBackground, studioCustomColor, onboardingSeen,
            musicTrackId, musicVolume, musicGuide,
        ]
    }

    /// Reads settings from stored values. Missing or unreadable entries keep their defaults; the result is sanitized.
    init(stored: [String: Any]) {
        self.init()
        func string(_ key: String) -> String? { stored[key] as? String }
        func number(_ key: String) -> NSNumber? {
            // A Bool is an NSNumber too; that is fine for the Bool keys and harmless for the others.
            stored[key] as? NSNumber
        }
        if let v = string(Keys.mode).flatMap(StageMode.init(rawValue:)) { mode = v }
        lastCharacterId = string(Keys.lastCharacterId)
        if let v = number(Keys.watermarkEnabled) { watermarkEnabled = v.boolValue }
        if let v = string(Keys.watermarkAnchor).flatMap(WatermarkAnchor.init(rawValue:)) { watermarkAnchor = v }
        if let v = number(Keys.watermarkWidth) { watermarkWidth = v.floatValue }
        if let v = number(Keys.watermarkOpacity) { watermarkOpacity = v.floatValue }
        if let v = number(Keys.countdownSeconds) { countdownSeconds = v.intValue }
        if let v = number(Keys.maxDurationSeconds) { maxDurationSeconds = v.intValue }
        if let v = number(Keys.recordMicrophone) { recordMicrophone = v.boolValue }
        if let v = number(Keys.safeZoneGuides) { safeZoneGuides = v.boolValue }
        musicTrackId = string(Keys.musicTrackId)
        if let v = number(Keys.musicVolume) { musicVolume = v.floatValue }
        if let v = number(Keys.musicGuide) { musicGuide = v.boolValue }
        if let v = number(Keys.showPlanes) { showPlanes = v.boolValue }
        if let v = number(Keys.groundShadow) { groundShadow = v.boolValue }
        if let v = number(Keys.depthOcclusion) { depthOcclusion = v.boolValue }
        if let v = string(Keys.studioBackground).flatMap(StudioBackground.init(rawValue:)) { studioBackground = v }
        if let v = number(Keys.studioCustomColor) { studioCustomColor = UInt32(truncatingIfNeeded: v.int64Value) }
        if let v = number(Keys.onboardingSeen) { onboardingSeen = v.boolValue }
        self = sanitized()
    }

    /// Values to store. `lastCharacterId` and `musicTrackId` are absent when nil, so the caller removes those keys.
    var stored: [String: Any] {
        let s = sanitized()
        var out: [String: Any] = [
            Keys.mode: s.mode.rawValue,
            Keys.watermarkEnabled: s.watermarkEnabled,
            Keys.watermarkAnchor: s.watermarkAnchor.rawValue,
            Keys.watermarkWidth: s.watermarkWidth,
            Keys.watermarkOpacity: s.watermarkOpacity,
            Keys.countdownSeconds: s.countdownSeconds,
            Keys.maxDurationSeconds: s.maxDurationSeconds,
            Keys.recordMicrophone: s.recordMicrophone,
            Keys.safeZoneGuides: s.safeZoneGuides,
            Keys.musicVolume: s.musicVolume,
            Keys.musicGuide: s.musicGuide,
            Keys.showPlanes: s.showPlanes,
            Keys.groundShadow: s.groundShadow,
            Keys.depthOcclusion: s.depthOcclusion,
            Keys.studioBackground: s.studioBackground.rawValue,
            Keys.studioCustomColor: Int64(s.studioCustomColor),
            Keys.onboardingSeen: s.onboardingSeen,
        ]
        if let id = s.lastCharacterId { out[Keys.lastCharacterId] = id }
        if let id = s.musicTrackId { out[Keys.musicTrackId] = id }
        return out
    }
}
