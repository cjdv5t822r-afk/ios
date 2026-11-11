import AVFoundation
import Photos
import SwiftUI
import UIKit

/// What kind of file a capture is.
enum CaptureKind: Equatable {
    case video
    case photo

    var fileExtension: String {
        switch self {
        case .video: return "mp4"
        case .photo: return "jpg"
        }
    }
}

/// A capture the app keeps a copy of (for the thumbnail and the share sheet) and has offered to the photo library.
struct SavedCapture: Equatable, Identifiable {
    /// The app's own copy, in its caches folder.
    let fileURL: URL
    let kind: CaptureKind
    let displayName: String

    var id: URL { fileURL }
}

/// Puts capture files where the creator finds them: the system photo library, with add-only access.
///
/// Add-only access cannot create or look into albums, so unlike on Android (`Movies/MonastyrAR`) the captures land
/// in the library's main view. The app keeps its own copy of the newest capture so it can be shared without ever
/// reading the library.
enum CaptureSaver {

    static let filePrefix = "MonastyrAR"

    enum Outcome {
        /// In the library, and kept as `capture`.
        case saved(SavedCapture)
        /// Kept as `capture` (it can still be shared), but the library refused: no permission.
        case keptWithoutLibraryAccess(SavedCapture)
        /// The file is gone or could not be moved.
        case failed
    }

    private static var capturesDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("captures", isDirectory: true)
    }

    /// Moves `source` into the app's captures folder under a dated name, then adds it to the photo library.
    static func publish(_ source: URL, kind: CaptureKind) async -> Outcome {
        let kept = await Task.detached(priority: .userInitiated) { () -> SavedCapture? in
            let fm = FileManager.default
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0 else { return nil }
            let directory = capturesDirectory
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                // Only the newest capture is kept; the library holds the rest.
                for old in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: old)
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let name = "\(filePrefix)_\(formatter.string(from: Date())).\(kind.fileExtension)"
                let target = directory.appendingPathComponent(name, isDirectory: false)
                try fm.moveItem(at: source, to: target)
                return SavedCapture(fileURL: target, kind: kind, displayName: name)
            } catch {
                return nil
            }
        }.value
        guard let capture = kept else { return .failed }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .keptWithoutLibraryAccess(capture) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: capture.kind == .video ? .video : .photo, fileURL: capture.fileURL, options: nil)
            }
            return .saved(capture)
        } catch {
            return .keptWithoutLibraryAccess(capture)
        }
    }

    /// A small picture of a capture for the button next to the shutter.
    static func thumbnail(for capture: SavedCapture, maxPixels: CGFloat = 192) async -> UIImage? {
        switch capture.kind {
        case .photo:
            return await Task.detached(priority: .utility) { () -> UIImage? in
                guard let image = UIImage(contentsOfFile: capture.fileURL.path) else { return nil }
                return image.preparingThumbnail(of: fitted(image.size, into: maxPixels))
            }.value
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: capture.fileURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            guard let frame = try? await generator.image(at: .zero) else { return nil }
            return UIImage(cgImage: frame.image)
        }
    }

    private static func fitted(_ size: CGSize, into maxPixels: CGFloat) -> CGSize {
        let longest = max(size.width, size.height, 1)
        let scale = min(1, maxPixels / longest)
        return CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }
}

/// The system share sheet for a capture: TikTok, Instagram, AirDrop and whatever else takes a video or a photo.
struct ShareSheet: UIViewControllerRepresentable {
    let capture: SavedCapture

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [capture.fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
