import Foundation

/// Where the logo sits inside the 9:16 frame. Pure maths shared by the on-screen preview (SwiftUI) and the capture
/// overlay (Core Graphics), so what the creator sees is what lands in the file. Port of `capture/WatermarkLayout.kt`.
public enum WatermarkLayout {

    /// Frame-relative margins that keep the logo clear of the short-video platforms' own UI.
    public static let sideMargin: Float = 0.05
    public static let topMargin: Float = 0.085
    public static let bottomMargin: Float = 0.20

    /// Pixel rectangle inside a frame, measured from the frame's top-left corner.
    public struct Rect: Equatable, Sendable {
        public var left: Float
        public var top: Float
        public var width: Float
        public var height: Float

        public init(left: Float, top: Float, width: Float, height: Float) {
            self.left = left
            self.top = top
            self.width = width
            self.height = height
        }

        public var right: Float { left + width }
        public var bottom: Float { top + height }
    }

    /// - Parameter logoAspect: logo width / height
    public static func place(
        frameWidth: Float,
        frameHeight: Float,
        logoAspect: Float,
        anchor: WatermarkAnchor,
        widthFraction: Float
    ) -> Rect {
        let aspect = logoAspect > 0 ? logoAspect : 1
        let maxWidth = frameWidth * (1 - 2 * sideMargin)
        let fraction = min(max(widthFraction, AppSettings.watermarkWidthMin), AppSettings.watermarkWidthMax)
        let w = min(frameWidth * fraction, maxWidth)
        let h = w / aspect
        let left: Float
        switch anchor {
        case .topLeft, .bottomLeft: left = frameWidth * sideMargin
        case .topCenter, .bottomCenter: left = (frameWidth - w) / 2
        case .topRight, .bottomRight: left = frameWidth * (1 - sideMargin) - w
        }
        let top: Float
        switch anchor {
        case .topLeft, .topCenter, .topRight: top = frameHeight * topMargin
        case .bottomLeft, .bottomCenter, .bottomRight: top = frameHeight * (1 - bottomMargin) - h
        }
        return Rect(left: left, top: top, width: w, height: h)
    }
}
