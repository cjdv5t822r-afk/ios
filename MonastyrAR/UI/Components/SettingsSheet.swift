import StageCore
import SwiftUI

/// "Ustawienia". Every control writes through `onChange` at once; there is nothing to confirm.
struct SettingsSheet: View {
    let settings: AppSettings
    let versionName: String
    /// The microphone permission was refused, so the switch cannot stay on.
    let microphoneBlocked: Bool
    /// A backing track goes into the recordings, which then leave the microphone out.
    let musicSelected: Bool
    let onChange: (@escaping (inout AppSettings) -> Void) -> Void
    /// The microphone switch was flipped (the caller owns the permission request).
    let onMicrophoneChange: (Bool) -> Void

    /// Top row, then bottom row: the picker is a miniature of the frame.
    private static let anchorRows: [[WatermarkAnchor]] = [
        [.topLeft, .topCenter, .topRight],
        [.bottomLeft, .bottomCenter, .bottomRight],
    ]

    private static let studioBackgrounds: [StudioBackground] = [.green, .blue, .black, .white]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Strings.settings)
                    .font(.brandTitleLarge)

                sectionHeader("star.fill", Strings.sectionWatermark)
                switchRow(Strings.watermarkShow, isOn: settings.watermarkEnabled) { on in
                    onChange { $0.watermarkEnabled = on }
                }
                VStack(alignment: .leading, spacing: 0) {
                    fieldLabel(Strings.watermarkPosition)
                    anchorPicker
                    sliderRow(
                        Strings.watermarkSize, value: settings.watermarkWidth,
                        range: AppSettings.watermarkWidthMin...AppSettings.watermarkWidthMax
                    ) { value in
                        onChange { $0.watermarkWidth = value }
                    }
                    sliderRow(
                        Strings.watermarkOpacity, value: settings.watermarkOpacity,
                        range: AppSettings.watermarkOpacityMin...1
                    ) { value in
                        onChange { $0.watermarkOpacity = value }
                    }
                }
                .disabled(!settings.watermarkEnabled)
                .opacity(settings.watermarkEnabled ? 1 : disabledAlpha)

                sectionHeader("video.fill", Strings.sectionRecording)
                fieldLabel(Strings.countdown)
                choiceRow(AppSettings.countdownChoices, selected: settings.countdownSeconds, label: Strings.countdownChoice) { seconds in
                    onChange { $0.countdownSeconds = seconds }
                }
                fieldLabel(Strings.maxDuration)
                choiceRow(AppSettings.maxDurationChoices, selected: settings.maxDurationSeconds, label: Strings.maxDurationChoice) { seconds in
                    onChange { $0.maxDurationSeconds = seconds }
                }
                switchRow(
                    Strings.microphone,
                    caption: microphoneNote,
                    captionIsWarning: microphoneBlocked && !musicSelected,
                    // The stored choice is kept; it comes back as soon as the music is taken off.
                    isOn: settings.recordMicrophone && !musicSelected,
                    onToggle: onMicrophoneChange
                )
                .disabled(musicSelected)
                switchRow(Strings.safeZoneGuides, caption: Strings.safeZoneGuidesCaption, isOn: settings.safeZoneGuides) { on in
                    onChange { $0.safeZoneGuides = on }
                }

                sectionHeader("arkit", Strings.sectionAR)
                switchRow(Strings.showPlanes, isOn: settings.showPlanes) { on in
                    onChange { $0.showPlanes = on }
                }
                switchRow(Strings.groundShadow, isOn: settings.groundShadow) { on in
                    onChange { $0.groundShadow = on }
                }
                switchRow(Strings.depthOcclusion, caption: Strings.depthOcclusionCaption, isOn: settings.depthOcclusion) { on in
                    onChange { $0.depthOcclusion = on }
                }

                sectionHeader("theatermasks.fill", Strings.sectionStudio)
                fieldLabel(Strings.studioBackground)
                choiceRow(
                    SettingsSheet.studioBackgrounds, selected: settings.studioBackground,
                    label: Strings.studioBackgroundName, swatch: { Color(rgb: $0.argb & 0x00FF_FFFF) }
                ) { background in
                    onChange { $0.studioBackground = background }
                }

                Divider()
                    .overlay(BrandColors.outline)
                    .padding(.top, 28)
                Text(Strings.version(versionName))
                    .font(.brandBodySmall)
                    .foregroundStyle(BrandColors.textMuted)
                    .padding(.top, 14)
            }
            .foregroundStyle(BrandColors.text)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: rows

    /// What stands under the microphone switch: why it is off, or what it does.
    private var microphoneNote: String {
        if musicSelected { return Strings.microphoneMusic }
        return microphoneBlocked ? Strings.microphoneBlocked : Strings.microphoneCaption
    }

    private func sectionHeader(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
            Text(title)
                .font(.brandTitleSmall)
        }
        .foregroundStyle(BrandColors.gold)
        .padding(.top, 28)
        .padding(.bottom, 6)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.brandBodyLarge)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    private func switchRow(
        _ label: String,
        caption: String? = nil,
        captionIsWarning: Bool = false,
        isOn: Bool,
        onToggle: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: onToggle)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.brandBodyLarge)
                if let caption {
                    Text(caption)
                        .font(.brandBodySmall)
                        .foregroundStyle(captionIsWarning ? BrandColors.emberSoft : BrandColors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.trailing, 16)
        }
        .tint(BrandColors.gold)
        .frame(minHeight: 56)
        .padding(.vertical, 6)
    }

    private func sliderRow(
        _ label: String,
        value: Float,
        range: ClosedRange<Float>,
        onValueChange: @escaping (Float) -> Void
    ) -> some View {
        // The real value (logo width as a share of the frame, opacity), not the thumb's position along the track.
        let shown = min(max(value, range.lowerBound), range.upperBound)
        let percent = Strings.percent(shown)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.brandBodyLarge)
                Spacer()
                Text(percent)
                    .font(.brandBodyMedium)
                    .foregroundStyle(BrandColors.textMuted)
                    .accessibilityHidden(true)
            }
            Slider(value: Binding(get: { shown }, set: onValueChange), in: range)
                .tint(BrandColors.gold)
                .accessibilityLabel(label)
                .accessibilityValue(percent)
        }
        .padding(.top, 12)
    }

    private func choiceRow<T: Hashable>(
        _ choices: [T],
        selected: T,
        label: @escaping (T) -> String,
        swatch: ((T) -> Color)? = nil,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { choice in
                    PillChip(label: label(choice), selected: choice == selected, swatch: swatch?(choice)) {
                        onSelect(choice)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    /// Six cells laid out like the frame itself; each shows where the logo would sit.
    private var anchorPicker: some View {
        VStack(spacing: 8) {
            ForEach(SettingsSheet.anchorRows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { anchor in
                        anchorCell(anchor)
                    }
                }
            }
        }
    }

    private func anchorCell(_ anchor: WatermarkAnchor) -> some View {
        let isSelected = anchor == settings.watermarkAnchor
        let shape = RoundedRectangle(cornerRadius: BrandShapes.small)
        return Button {
            onChange { $0.watermarkAnchor = anchor }
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? BrandColors.gold : BrandColors.textMuted.opacity(0.5))
                .frame(width: 22, height: 10)
                .padding(9)
                .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: SettingsSheet.alignment(of: anchor))
                .background(BrandColors.surfaceHigh, in: shape)
                .overlay(shape.stroke(isSelected ? BrandColors.gold : BrandColors.outline, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.anchor(anchor))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func alignment(of anchor: WatermarkAnchor) -> Alignment {
        switch anchor {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }
}
