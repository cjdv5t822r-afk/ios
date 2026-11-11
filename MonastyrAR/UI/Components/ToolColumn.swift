import StageCore
import SwiftUI

/// The live controls on the right edge of the stage. They stay usable while recording: the creator directs the
/// characters with them during a take.
struct ToolColumn: View {
    /// A character is selected (needed by the buttons that act on exactly one character).
    let hasSelection: Bool
    /// At least one character would receive pause / speed commands.
    let hasTargets: Bool
    let paused: Bool
    let speed: Float
    /// Two or more characters are on the stage, so "everyone at once" means something.
    let showAll: Bool
    let applyToAll: Bool
    /// Title of the backing track the next recording gets, or nil when it gets none.
    let musicTitle: String?
    /// False while a capture is running: the track may not change under it.
    let musicEnabled: Bool
    let onCharacters: () -> Void
    let onMusic: () -> Void
    let onFaceCamera: () -> Void
    let onScale: (Float) -> Void
    let onTogglePaused: () -> Void
    let onCycleSpeed: () -> Void
    let onToggleAll: () -> Void
    let onRemove: () -> Void

    @State private var presetsOpen = false

    /// Scale presets behind a long press on "1:1": a desk figurine, real size, a giant.
    private static let sizePresets = [
        SizePreset(label: Strings.sizeFigurine, scale: StageMath.sizePresets[0]),
        SizePreset(label: Strings.sizeReal, scale: StageMath.sizePresets[1]),
        SizePreset(label: Strings.sizeGiant, scale: StageMath.sizePresets[2]),
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ToolButton(caption: Strings.toolCharacter, description: Strings.toolCharacterDescription, action: onCharacters) {
                    Image(systemName: "person.fill")
                }
                ToolButton(
                    caption: Strings.toolMusic,
                    description: musicTitle.map { Strings.musicSelected($0) } ?? Strings.toolMusicDescription,
                    enabled: musicEnabled, active: musicTitle != nil, action: onMusic
                ) {
                    Image(systemName: "music.note")
                }
                ToolButton(
                    caption: Strings.toolFaceMe, description: Strings.toolFaceMeDescription,
                    enabled: hasSelection, action: onFaceCamera
                ) {
                    Image(systemName: "figure.wave")
                }
                ToolButton(
                    caption: Strings.toolRealSize, description: Strings.toolRealSizeDescription,
                    enabled: hasSelection, longPressLabel: Strings.toolSizePresets,
                    onLongPress: { presetsOpen = true },
                    action: { onScale(1) }
                ) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .confirmationDialog(Strings.toolSizePresets, isPresented: $presetsOpen, titleVisibility: .visible) {
                    ForEach(ToolColumn.sizePresets) { preset in
                        Button(preset.label) { onScale(preset.scale) }
                    }
                    Button(Strings.cancel, role: .cancel) {}
                }
                ToolButton(
                    caption: paused ? Strings.toolResume : Strings.toolPause,
                    description: paused ? Strings.toolResumeDescription : Strings.toolPauseDescription,
                    enabled: hasTargets, active: paused, action: onTogglePaused
                ) {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                }
                ToolButton(
                    caption: Strings.toolSpeed, description: Strings.speedDescription(speed),
                    enabled: hasTargets, action: onCycleSpeed
                ) {
                    Text(Strings.speed(speed))
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if showAll {
                    ToolButton(
                        caption: Strings.toolAll, description: Strings.toolAllDescription,
                        active: applyToAll, isToggle: true, action: onToggleAll
                    ) {
                        Image(systemName: "person.3.fill")
                    }
                }
                ToolButton(
                    caption: Strings.toolRemove, description: Strings.toolRemoveDescription,
                    enabled: hasSelection, action: onRemove
                ) {
                    Image(systemName: "trash.fill")
                }
            }
        }
        .frame(width: 60)
    }
}

/// What a long press does, offered as a named action to people who cannot long-press.
private struct LongPressAccessibility: ViewModifier {
    let label: String?
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let label, let action {
            content.accessibilityAction(named: Text(label), action)
        } else {
            content
        }
    }
}

private struct SizePreset: Identifiable {
    let label: String
    let scale: Float

    var id: String { label }
}

/// A round button with a tiny caption under it. The glyph inherits its colour: gold ink on a gold disc when
/// `active`, light on a dark translucent disc otherwise.
private struct ToolButton<Glyph: View>: View {
    let caption: String
    let description: String
    var enabled = true
    var active = false
    var isToggle = false
    var longPressLabel: String?
    var onLongPress: (() -> Void)?
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        VStack(spacing: 2) {
            glyph()
                .font(.system(size: 18))
                .foregroundStyle(active ? BrandColors.onGold : BrandColors.text)
                .frame(width: 46, height: 46)
                .background(active ? BrandColors.gold : BrandColors.scrim, in: Circle())
                .overlay(Circle().stroke(active ? BrandColors.gold : Color.white.opacity(0.2), lineWidth: 1))
            Text(caption)
                .font(.brandLabelSmall)
                .foregroundStyle(BrandColors.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .onCamera()
        }
        .frame(width: 60)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : disabledAlpha)
        .onTapGesture {
            if enabled { action() }
        }
        .onLongPressGesture(minimumDuration: 0.45, perform: {
            if enabled { onLongPress?() }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .accessibilityAddTraits(traits)
        .accessibilityAction { if enabled { action() } }
        .modifier(LongPressAccessibility(label: longPressLabel, action: enabled ? onLongPress : nil))
    }

    private var traits: AccessibilityTraits {
        var traits: AccessibilityTraits = .isButton
        if isToggle && active { traits.insert(.isSelected) }
        return traits
    }
}
