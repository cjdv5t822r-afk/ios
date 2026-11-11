import RealityKit
import StageCore
import SwiftUI

/// The 3D view of the stage as a SwiftUI view: the camera feed with the characters on detected floors in AR, or
/// the characters in front of one solid colour in Studio. It draws only the scene and fills the space it is given.
///
/// Give it `.id(mode)`: a controller serves one mode, so a mode switch has to rebuild the view.
struct StageView: UIViewRepresentable {
    let mode: StageMode
    let state: StageState
    let capture: CaptureController
    let settings: AppSettings

    /// Called once when it turns out that no AR session can run here after all.
    let onArUnavailable: () -> Void

    /// A hardware capture button (volume key) was pressed.
    let onShutter: () -> Void

    func makeCoordinator() -> StageController {
        StageController(
            mode: mode, state: state, capture: capture, settings: settings,
            onArUnavailable: onArUnavailable, onShutter: onShutter
        )
    }

    func makeUIView(context: Context) -> ARView {
        context.coordinator.start()
        return context.coordinator.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.apply(settings: settings)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: StageController) {
        coordinator.stop()
    }
}
