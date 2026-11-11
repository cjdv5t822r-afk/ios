import SwiftUI

/// Brand palette, taken from the logo; the same values as `ui/theme/Theme.kt`. The app is dark only: it is a
/// camera viewfinder.
enum BrandColors {
    static let gold = Color(rgb: 0xE8B24A)
    static let goldDeep = Color(rgb: 0x4A3712)
    static let ember = Color(rgb: 0xB3261E)
    static let emberSoft = Color(rgb: 0xFFB4AB)
    static let emberDeep = Color(rgb: 0x5C1410)
    static let background = Color(rgb: 0x0B0C10)
    static let surface = Color(rgb: 0x16171C)
    static let surfaceHigh = Color(rgb: 0x22242B)
    static let outline = Color(rgb: 0x3A3C45)
    static let text = Color(rgb: 0xF3EEE6)
    static let textMuted = Color(rgb: 0xA9A39A)

    /// Ink for text and icons sitting on gold.
    static let onGold = Color(rgb: 0x1A1305)

    /// Translucent black behind controls that float over the camera feed.
    static let scrim = Color.black.opacity(0.55)
}

extension Color {
    /// An opaque sRGB colour from `0xRRGGBB`.
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Corner radii of the shape scale (Material's small / medium / large on Android).
enum BrandShapes {
    static let small: CGFloat = 12
    static let medium: CGFloat = 16
    static let large: CGFloat = 20
}

/// Type scale: the Material roles the Android screens use, as system fonts.
extension Font {
    static let brandTitleLarge = Font.system(size: 22, weight: .semibold)
    static let brandTitleMedium = Font.system(size: 16, weight: .semibold)
    static let brandTitleSmall = Font.system(size: 14, weight: .semibold)
    static let brandBodyLarge = Font.system(size: 16)
    static let brandBodyMedium = Font.system(size: 14)
    static let brandBodySmall = Font.system(size: 12)
    static let brandLabelLarge = Font.system(size: 14, weight: .semibold)
    static let brandLabelMedium = Font.system(size: 12, weight: .medium)
    static let brandLabelSmall = Font.system(size: 11, weight: .medium)
}

/// Alpha of a control that cannot be used right now.
let disabledAlpha: Double = 0.38

extension View {
    /// Keeps a caption readable when it sits directly on the camera feed.
    func onCamera() -> some View {
        shadow(color: .black, radius: 3)
    }
}
