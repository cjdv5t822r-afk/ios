import StageCore
import SwiftUI

/// One choice out of a few, as a pill. Gold when chosen.
struct PillChip: View {
    let label: String
    let selected: Bool
    var enabled = true
    /// The chip floats over the camera feed and needs a darker, translucent resting state.
    var onScene = false
    /// A colour sample shown before the label, for choices that are colours.
    var swatch: Color?
    let action: () -> Void

    private var container: Color {
        if selected { return BrandColors.gold }
        return onScene ? BrandColors.scrim : BrandColors.surfaceHigh
    }

    private var border: Color {
        if selected { return BrandColors.gold }
        return onScene ? Color.white.opacity(0.22) : BrandColors.outline
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let swatch {
                    Circle()
                        .fill(swatch)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(BrandColors.outline, lineWidth: 1))
                }
                Text(label)
                    .font(.brandLabelLarge)
                    .foregroundStyle(selected ? BrandColors.onGold : BrandColors.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(container, in: Capsule())
            .overlay(Capsule().stroke(border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : disabledAlpha)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A rounded strip floating over the scene; the base of the hint, busy, error and recording pills.
private struct StagePill<Content: View>: View {
    var container: Color = BrandColors.scrim
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(container, in: Capsule())
    }
}

/// A short line of guidance floating over the scene.
struct HintPill: View {
    let text: String

    var body: some View {
        StagePill {
            Text(text)
                .font(.brandLabelLarge)
                .foregroundStyle(BrandColors.text)
                .multilineTextAlignment(.center)
        }
    }
}

struct BusyPill: View {
    let text: String

    var body: some View {
        StagePill {
            ProgressView()
                .controlSize(.small)
                .tint(BrandColors.gold)
            Text(text)
                .font(.brandLabelLarge)
                .foregroundStyle(BrandColors.text)
        }
    }
}

struct ErrorPill: View {
    let text: String

    var body: some View {
        StagePill(container: BrandColors.ember.opacity(0.92)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white)
            Text(text)
                .font(.brandLabelLarge)
                .foregroundStyle(.white)
        }
    }
}

/// Red dot and running time, shown while a video is being recorded.
struct RecordingPill: View {
    let elapsedMillis: Int
    @State private var dimmed = false

    var body: some View {
        let time = Strings.elapsed(millis: elapsedMillis)
        StagePill(container: Color.black.opacity(0.7)) {
            Circle()
                .fill(BrandColors.ember)
                .frame(width: 10, height: 10)
                .opacity(dimmed ? 0.25 : 1)
            Text(time)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Strings.recording) \(time)")
        .onAppear {
            withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: true)) { dimmed = true }
        }
    }
}

/// The seconds left before a capture starts. Tapping it calls the capture off.
struct CountdownOverlay: View {
    let seconds: Int
    let onCancel: () -> Void

    var body: some View {
        Button(action: onCancel) {
            VStack(spacing: 0) {
                Text(String(seconds))
                    .font(.system(size: 112, weight: .black))
                    .foregroundStyle(.white)
                    .onCamera()
                Text(Strings.countdownCancel)
                    .font(.brandLabelMedium)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .onCamera()
            }
            .frame(width: 220, height: 220)
            .background(Color.black.opacity(0.35), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.recordCancelCountdown)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Dims the parts of the frame the video platforms cover and outlines what stays visible.
struct SafeZoneGuides: View {
    /// Fractions of the 9:16 frame that short-video apps cover with their own buttons and captions.
    private static let top: CGFloat = 0.14
    private static let bottom: CGFloat = 0.25
    private static let right: CGFloat = 0.14

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let top = size.height * SafeZoneGuides.top
            let bottom = size.height * (1 - SafeZoneGuides.bottom)
            let right = size.width * (1 - SafeZoneGuides.right)
            let band = Color.black.opacity(0.28)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: size.width, height: top))
                    path.addRect(CGRect(x: 0, y: bottom, width: size.width, height: size.height - bottom))
                    path.addRect(CGRect(x: right, y: top, width: size.width - right, height: bottom - top))
                }
                .fill(band)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: top))
                    path.addLine(to: CGPoint(x: size.width, y: top))
                    path.move(to: CGPoint(x: 0, y: bottom))
                    path.addLine(to: CGPoint(x: size.width, y: bottom))
                    path.move(to: CGPoint(x: right, y: top))
                    path.addLine(to: CGPoint(x: right, y: bottom))
                }
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                Text(Strings.safeZone)
                    .font(.brandLabelSmall)
                    .foregroundStyle(Color.white.opacity(0.8))
                    .onCamera()
                    .padding(.leading, 8)
                    .padding(.top, top + 4)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The logo exactly where the recorder will bake it in: the same `WatermarkLayout` maths, fed with the size of
/// the stage box this fills.
struct WatermarkPreview: View {
    let logo: UIImage
    let settings: AppSettings

    var body: some View {
        GeometryReader { proxy in
            let rect = WatermarkLayout.place(
                frameWidth: Float(proxy.size.width),
                frameHeight: Float(proxy.size.height),
                logoAspect: logo.size.height > 0 ? Float(logo.size.width / logo.size.height) : 1,
                anchor: settings.watermarkAnchor,
                widthFraction: settings.watermarkWidth
            )
            Image(uiImage: logo)
                .resizable()
                .interpolation(.high)
                .frame(width: CGFloat(rect.width), height: CGFloat(rect.height))
                .opacity(Double(min(max(settings.watermarkOpacity, 0), 1)))
                .position(x: CGFloat(rect.left + rect.width / 2), y: CGFloat(rect.top + rect.height / 2))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A message along the bottom of the screen, with an optional action; the app's snackbar.
struct MessageBar: View {
    let text: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.brandBodyMedium)
                .foregroundStyle(BrandColors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .font(.brandLabelLarge)
                    .foregroundStyle(BrandColors.gold)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(BrandColors.surfaceHigh, in: RoundedRectangle(cornerRadius: BrandShapes.small))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
