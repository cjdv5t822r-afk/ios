import StageCore
import SwiftUI

/// Height of the bar below the status-bar inset.
let topBarHeight: CGFloat = 56

/// Brand mark, AR / Studio switch and the settings gear, floating over the top of the stage.
struct StageTopBar: View {
    /// Nil hides the brand mark (missing asset, or the watermark preview already sits in that corner).
    let logo: UIImage?
    let mode: StageMode
    /// False while a capture is running: neither the mode nor the settings may change under it.
    let enabled: Bool
    let onModeChange: (StageMode) -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if let logo {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 112, maxHeight: 32, alignment: .leading)
                        .accessibilityLabel(Strings.appName)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            ModeToggle(mode: mode, enabled: enabled, onModeChange: onModeChange)

            HStack {
                Spacer(minLength: 0)
                Button(action: onSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(BrandColors.text)
                        .frame(width: 44, height: 44)
                        .background(BrandColors.scrim, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : disabledAlpha)
                .accessibilityLabel(Strings.settings)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(height: topBarHeight)
    }
}

private struct ModeToggle: View {
    let mode: StageMode
    let enabled: Bool
    let onModeChange: (StageMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(Strings.modeAR, description: Strings.modeARDescription, value: .ar)
            segment(Strings.modeStudio, description: Strings.modeStudioDescription, value: .studio)
        }
        .padding(3)
        .background(BrandColors.scrim, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        .opacity(enabled ? 1 : disabledAlpha)
    }

    private func segment(_ label: String, description: String, value: StageMode) -> some View {
        let selected = mode == value
        return Button {
            onModeChange(value)
        } label: {
            Text(label)
                .font(.brandLabelLarge)
                .foregroundStyle(selected ? BrandColors.onGold : BrandColors.text)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minWidth: 64, minHeight: 38)
                .background(selected ? BrandColors.gold : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(description)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
