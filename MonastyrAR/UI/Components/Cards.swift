import SwiftUI

/// Shown in place of the AR view while the camera permission is missing.
struct CameraPermissionCard: View {
    let onAllow: () -> Void
    let onStudio: () -> Void

    var body: some View {
        StageCard {
            Image(systemName: "arkit")
                .font(.system(size: 26))
                .foregroundStyle(BrandColors.gold)
                .frame(width: 56, height: 56)
                .background(BrandColors.goldDeep, in: Circle())
                .frame(maxWidth: .infinity)
            Text(Strings.cameraNeeded)
                .font(.brandTitleMedium)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
            Text(Strings.cameraNeededBody)
                .font(.brandBodyMedium)
                .foregroundStyle(BrandColors.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            HStack(spacing: 12) {
                Button(action: onStudio) {
                    Text(Strings.modeStudioDescription)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(OutlinedBrandButtonStyle())
                Button(action: onAllow) {
                    Text(Strings.allow)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(FilledBrandButtonStyle())
            }
            .padding(.top, 20)
        }
    }
}

/// First-run tips: how to get a character on the stage, how to move it, how to record.
struct OnboardingCard: View {
    let onDismiss: () -> Void

    var body: some View {
        StageCard {
            Text(Strings.onboardingTitle)
                .font(.brandTitleMedium)
            tip("person.fill", Strings.onboardingPlace)
            tip("arrow.up.left.and.arrow.down.right", Strings.onboardingGestures)
            tip("video.fill", Strings.onboardingRecord)
            Button(action: onDismiss) {
                Text(Strings.onboardingDismiss)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(FilledBrandButtonStyle())
            .padding(.top, 18)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(BrandColors.gold)
                .frame(width: 20)
            Text(text)
                .font(.brandBodyMedium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }
}

/// Shown on the stage while no character is installed: where characters come from, and the way there.
struct FirstCharacterCard: View {
    let onOpenLibrary: () -> Void

    var body: some View {
        StageCard {
            Text(Strings.firstCharacterTitle)
                .font(.brandTitleMedium)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Text(Strings.firstCharacterBody)
                .font(.brandBodyMedium)
                .foregroundStyle(BrandColors.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            Button(action: onOpenLibrary) {
                Text(Strings.openLibrary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(FilledBrandButtonStyle())
            .padding(.top, 14)
        }
    }
}

private struct StageCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BrandShapes.large)
        VStack(alignment: .leading, spacing: 0) { content() }
            .foregroundStyle(BrandColors.text)
            .padding(20)
            .frame(maxWidth: 340)
            .background(BrandColors.surface.opacity(0.96), in: shape)
            .overlay(shape.stroke(BrandColors.outline, lineWidth: 1))
            // Claims every touch that lands on the card, so none of them moves the character underneath.
            .contentShape(shape)
            .onTapGesture {}
    }
}

/// The primary button: gold, dark ink.
struct FilledBrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brandLabelLarge)
            .foregroundStyle(BrandColors.onGold)
            .padding(.horizontal, 16)
            .background(BrandColors.gold.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

/// The secondary button: outline only.
struct OutlinedBrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brandLabelLarge)
            .foregroundStyle(BrandColors.gold)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0), in: Capsule())
            .overlay(Capsule().stroke(BrandColors.outline, lineWidth: 1))
    }
}
