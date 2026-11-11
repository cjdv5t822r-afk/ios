import CoreGraphics
import Foundation
import StageCore
import UIKit

/// The brand logo shipped in the app bundle (`branding/logo.webp`, the repository's `content/branding`), decoded once.
enum BrandLogo {
    static let resourcePath = "branding/logo.webp"

    /// Nil when the file is missing or cannot be decoded; callers then simply show no logo.
    static let image: UIImage? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(resourcePath, isDirectory: false) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }()
}

/// Draws the watermark into every captured photo and video frame.
///
/// The recorder reads it on its own queue for each frame while the settings change on the main thread, so the
/// settings are pushed in through `apply` and guarded by a lock. Placement comes from `WatermarkLayout`, the same
/// maths the on-screen preview uses.
final class LogoOverlay: @unchecked Sendable {

    private let logo: CGImage?
    private let lock = NSLock()
    private var enabled = true
    private var anchor = WatermarkAnchor.topLeft
    private var widthFraction: Float = 0.30
    private var opacity: Float = 0.92

    init(logo: CGImage?) {
        self.logo = logo
    }

    func apply(_ settings: AppSettings) {
        lock.lock()
        enabled = settings.watermarkEnabled
        anchor = settings.watermarkAnchor
        widthFraction = settings.watermarkWidth
        opacity = settings.watermarkOpacity
        lock.unlock()
    }

    /// Where the logo goes in a frame of the given pixel size, measured from the top-left corner, and how opaque it
    /// is; nil when no logo is to be drawn.
    func placement(frameWidth: Int, frameHeight: Int) -> (image: CGImage, rect: CGRect, opacity: CGFloat)? {
        guard let logo, logo.height > 0, frameWidth > 0, frameHeight > 0 else { return nil }
        lock.lock()
        let isEnabled = enabled
        let currentAnchor = anchor
        let fraction = widthFraction
        let alpha = opacity
        lock.unlock()
        guard isEnabled else { return nil }
        let r = WatermarkLayout.place(
            frameWidth: Float(frameWidth),
            frameHeight: Float(frameHeight),
            logoAspect: Float(logo.width) / Float(logo.height),
            anchor: currentAnchor,
            widthFraction: fraction
        )
        let rect = CGRect(x: CGFloat(r.left), y: CGFloat(r.top), width: CGFloat(r.width), height: CGFloat(r.height))
        return (logo, rect, CGFloat(min(max(alpha, 0), 1)))
    }

    /// Draws the logo into a bitmap context that covers a whole frame and has Core Graphics' own orientation
    /// (origin in the bottom-left corner), as a context made over a pixel buffer has.
    func draw(in context: CGContext, width: Int, height: Int) {
        guard let placed = placement(frameWidth: width, frameHeight: height) else { return }
        var rect = placed.rect
        rect.origin.y = CGFloat(height) - rect.maxY
        context.saveGState()
        context.interpolationQuality = .high
        context.setAlpha(placed.opacity)
        context.draw(placed.image, in: rect)
        context.restoreGState()
    }
}
