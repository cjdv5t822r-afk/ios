import CoreGraphics
import RealityKit
import UIKit

/// The small helper objects of the stage that are not characters: the contact shadow under each one, the placement
/// reticle and the tint of detected surfaces. Built once per scene, shared by every character.
@MainActor
final class StageProps {

    /// A one metre square on the floor; scale x / z to size it.
    let unitPlane: MeshResource
    let shadowMaterial: UnlitMaterial
    let reticleMaterial: UnlitMaterial
    let planeMaterial: UnlitMaterial

    /// How far above the floor the flat helpers sit, so they do not flicker against a detected plane.
    static let shadowLift: Float = 0.004
    static let planeLift: Float = 0.002
    static let reticleLift: Float = 0.006
    static let reticleDiameter: Float = 0.32

    private init(unitPlane: MeshResource, shadow: UnlitMaterial, reticle: UnlitMaterial, plane: UnlitMaterial) {
        self.unitPlane = unitPlane
        shadowMaterial = shadow
        reticleMaterial = reticle
        planeMaterial = plane
    }

    /// Creates the shared resources. Textures are generated in code, so the app ships no helper images.
    static func make() async throws -> StageProps {
        let options = TextureResource.CreateOptions(semantic: .color)
        let blob = try await TextureResource(image: softDiscImage(size: 128), withName: "stage.shadow", options: options)
        let ring = try await TextureResource(image: ringImage(size: 256), withName: "stage.reticle", options: options)

        // The textures hold the same value in every channel (white, premultiplied by its alpha), so they work both
        // as a colour map under a tint and as an opacity map, whichever channel the renderer reads for that.
        var shadow = UnlitMaterial(color: .black)
        shadow.color = .init(tint: .black, texture: .init(blob))
        shadow.blending = .transparent(opacity: .init(scale: 0.6, texture: .init(blob)))

        let gold = UIColor(red: 0xE8 / 255.0, green: 0xB2 / 255.0, blue: 0x4A / 255.0, alpha: 1)
        var reticle = UnlitMaterial(color: gold)
        reticle.color = .init(tint: gold, texture: .init(ring))
        reticle.blending = .transparent(opacity: .init(scale: 1, texture: .init(ring)))

        var plane = UnlitMaterial(color: gold)
        plane.blending = .transparent(opacity: 0.16)

        return StageProps(
            unitPlane: MeshResource.generatePlane(width: 1, depth: 1),
            shadow: shadow,
            reticle: reticle,
            plane: plane
        )
    }

    func makeShadow() -> ModelEntity {
        ModelEntity(mesh: unitPlane, materials: [shadowMaterial])
    }

    func makeReticle() -> ModelEntity {
        let entity = ModelEntity(mesh: unitPlane, materials: [reticleMaterial])
        entity.scale = SIMD3(StageProps.reticleDiameter, 1, StageProps.reticleDiameter)
        return entity
    }

    func makePlane() -> ModelEntity {
        ModelEntity(mesh: unitPlane, materials: [planeMaterial])
    }

    // MARK: generated images

    private static func bitmapContext(size: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.coderInvalidValue) }
        return context
    }

    /// White disc that fades to nothing at its rim.
    private static func softDiscImage(size: Int) throws -> CGImage {
        let context = try bitmapContext(size: size)
        let colors = [UIColor(white: 1, alpha: 1).cgColor, UIColor(white: 1, alpha: 0.55).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.45, 1]) else {
            throw CocoaError(.coderInvalidValue)
        }
        let center = CGPoint(x: size / 2, y: size / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(size) / 2, options: [])
        guard let image = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        return image
    }

    /// White ring with a dot in the middle.
    private static func ringImage(size: Int) throws -> CGImage {
        let context = try bitmapContext(size: size)
        let s = CGFloat(size)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(s * 0.06)
        context.strokeEllipse(in: CGRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84))
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: s * 0.45, y: s * 0.45, width: s * 0.10, height: s * 0.10))
        guard let image = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        return image
    }
}
