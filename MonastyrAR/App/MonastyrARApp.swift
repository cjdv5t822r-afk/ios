import SwiftUI

/// Monastyr AR for iOS: an AR "character stage" for recording short vertical videos with the brand logo in
/// every frame. The whole app is one screen.
@main
struct MonastyrARApp: App {
    @State private var viewModel = StageViewModel()

    var body: some Scene {
        WindowGroup {
            StageScreen(viewModel: viewModel)
                // The UI is dark in every mode: it is a camera viewfinder.
                .preferredColorScheme(.dark)
                .tint(BrandColors.gold)
                .statusBarHidden(false)
                .persistentSystemOverlays(.hidden)
        }
    }
}
