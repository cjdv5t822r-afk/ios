import StageCore
import SwiftUI

/// Fixed heights of the deck's rows, so nothing around the deck has to move when its content changes.
enum BottomDeckMetrics {
    static let handleHeight: CGFloat = 28
    static let chipsHeight: CGFloat = 48
    static let clipsHeight: CGFloat = 56
    static let captureBarHeight: CGFloat = 104

    /// Height of the open deck above the home-indicator inset.
    static let expandedHeight = handleHeight + chipsHeight + clipsHeight + captureBarHeight
}

/// Animation picker and capture controls along the bottom of the screen.
struct BottomDeck: View {
    /// The selected character, whose clips are shown.
    let actor: StageActor?
    /// No character is on the stage at all (as opposed to: none is selected).
    let stageIsEmpty: Bool
    @Binding var expanded: Bool
    /// A clip was tapped; `toggleLoop` is true for a long press.
    let onPlay: (_ clip: Clip, _ toggleLoop: Bool) -> Void
    let capture: CaptureController
    /// Recording limit for the progress ring, 0 for none.
    let maxDurationSeconds: Int
    /// Title of the backing track the next recording gets, or nil when it gets none.
    let musicTitle: String?
    /// False while a capture is running: the chip still shows the track but does not open the sheet.
    let musicEnabled: Bool
    let onRecord: () -> Void
    let onPhoto: () -> Void
    let onShareLast: (SavedCapture) -> Void
    let onMusic: () -> Void
    /// Home-indicator inset to keep clear at the bottom.
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            DeckHandle(expanded: $expanded)
            if expanded {
                AnimationRows(actor: actor, stageIsEmpty: stageIsEmpty, onPlay: onPlay)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let musicTitle {
                MusicChip(title: musicTitle, enabled: musicEnabled, action: onMusic)
            }
            CaptureBar(
                capture: capture, maxDurationSeconds: maxDurationSeconds,
                onRecord: onRecord, onPhoto: onPhoto, onShareLast: onShareLast
            )
        }
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.5), location: 0.3),
                    .init(color: .black.opacity(0.92), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }
}

private struct DeckHandle: View {
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BrandColors.text)
                .frame(width: 72, height: BottomDeckMetrics.handleHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(height: BottomDeckMetrics.handleHeight)
        .accessibilityLabel(expanded ? Strings.deckCollapse : Strings.deckExpand)
    }
}

private struct AnimationRows: View {
    let actor: StageActor?
    let stageIsEmpty: Bool
    let onPlay: (Clip, Bool) -> Void

    /// Filter per character: a new character starts on "Wszystkie" again.
    @State private var chosen: [Int: ClipCategory] = [:]

    private static let rowsHeight = BottomDeckMetrics.chipsHeight + BottomDeckMetrics.clipsHeight

    private var notice: String? {
        guard let actor else { return stageIsEmpty ? Strings.deckNoActor : Strings.deckNoSelection }
        switch actor.load {
        case .loading: return Strings.deckLoading
        case .failed: return Strings.loadFailed
        case .ready: return actor.clips.isEmpty ? Strings.deckNoClips : nil
        }
    }

    var body: some View {
        if let actor, notice == nil {
            rows(for: actor)
        } else {
            Text(notice ?? "")
                .font(.brandBodyMedium)
                .foregroundStyle(BrandColors.textMuted)
                .multilineTextAlignment(.center)
                .onCamera()
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .frame(height: AnimationRows.rowsHeight)
        }
    }

    private func rows(for actor: StageActor) -> some View {
        let clips = actor.clips
        let categories = ClipCategory.allCases.filter { category in clips.contains { $0.category == category } }
        let filter = chosen[actor.id].flatMap { categories.contains($0) ? $0 : nil }
        let shown = filter.map { wanted in clips.filter { $0.category == wanted } } ?? clips
        let current = actor.currentClip
        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PillChip(label: Strings.categoryAll, selected: filter == nil, onScene: true) {
                        chosen[actor.id] = nil
                    }
                    ForEach(categories, id: \.self) { category in
                        PillChip(label: Strings.category(category), selected: filter == category, onScene: true) {
                            chosen[actor.id] = category
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: BottomDeckMetrics.chipsHeight)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shown) { clip in
                        ClipButton(clip: clip, current: current, onPlay: onPlay)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: BottomDeckMetrics.clipsHeight)
            // A new character or filter is a new list: start it from the left again.
            .id("\(actor.id)-\(filter?.rawValue ?? "all")")
        }
        .frame(height: AnimationRows.rowsHeight)
    }
}

private struct ClipButton: View {
    let clip: Clip
    let current: Clip?
    let onPlay: (Clip, Bool) -> Void

    var body: some View {
        let playing = current.flatMap { $0.name == clip.name ? $0 : nil }
        let isCurrent = playing != nil
        // A long press plays the clip with the loop flag flipped; show what is really happening, not the default.
        let loops = playing?.loop ?? clip.loop
        let ink = isCurrent ? BrandColors.onGold : BrandColors.text
        let shape = RoundedRectangle(cornerRadius: BrandShapes.small)
        HStack(spacing: 6) {
            if loops {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.8))
            }
            Text(clip.label)
                .font(.brandLabelLarge)
                .foregroundStyle(ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 168)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(isCurrent ? BrandColors.gold : BrandColors.surfaceHigh.opacity(0.88), in: shape)
        .overlay(shape.stroke(isCurrent ? BrandColors.gold : Color.white.opacity(0.14), lineWidth: 1))
        .contentShape(shape)
        .onTapGesture { onPlay(clip, false) }
        .onLongPressGesture(minimumDuration: 0.45, perform: { onPlay(clip, true) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.label)
        .accessibilityValue(loops ? Strings.clipLoops : "")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onPlay(clip, false) }
        .accessibilityAction(named: Text(Strings.clipToggleLoop)) { onPlay(clip, true) }
    }
}

private struct CaptureBar: View {
    let capture: CaptureController
    let maxDurationSeconds: Int
    let onRecord: () -> Void
    let onPhoto: () -> Void
    let onShareLast: (SavedCapture) -> Void

    var body: some View {
        let recording = capture.isRecording
        let progress: Double = recording && maxDurationSeconds > 0
            ? min(max(Double(capture.elapsedMillis) / Double(maxDurationSeconds * 1_000), 0), 1)
            : 0
        HStack {
            LastCaptureButton(last: capture.lastCapture, saving: capture.isSaving, onShare: onShareLast)
            Spacer()
            RecordButton(
                recording: recording,
                countingDown: capture.countdown != nil,
                // A recording has to hold at least one frame before it can be stopped; a photo in flight blocks a start.
                enabled: recording ? capture.canStop : !capture.isTakingPhoto,
                progress: progress,
                action: onRecord
            )
            Spacer()
            PhotoButton(enabled: !capture.isTakingPhoto && capture.countdown == nil, action: onPhoto)
        }
        .padding(.horizontal, 40)
        .frame(height: BottomDeckMetrics.captureBarHeight)
    }
}

private struct RecordButton: View {
    let recording: Bool
    let countingDown: Bool
    let enabled: Bool
    let progress: Double
    let action: () -> Void

    private var description: String {
        if recording { return Strings.recordStop }
        return countingDown ? Strings.recordCancelCountdown : Strings.recordStart
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .padding(2)
                if progress > 0 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(BrandColors.gold, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2)
                }
                RoundedRectangle(cornerRadius: recording ? 8 : 30)
                    .fill(BrandColors.ember)
                    .frame(width: recording ? 30 : 60, height: recording ? 30 : 60)
                    .animation(.easeInOut(duration: 0.2), value: recording)
            }
            .frame(width: 80, height: 80)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
        .accessibilityLabel(description)
    }
}

private struct PhotoButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "camera.fill")
                .font(.system(size: 22))
                .foregroundStyle(BrandColors.text)
                .frame(width: 56, height: 56)
                .background(BrandColors.surfaceHigh.opacity(0.88), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : disabledAlpha)
        .accessibilityLabel(Strings.photo)
    }
}

/// Thumbnail of the newest capture; tapping it opens the share sheet.
private struct LastCaptureButton: View {
    let last: SavedCapture?
    let saving: Bool
    let onShare: (SavedCapture) -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        Button {
            if let last { onShare(last) }
        } label: {
            ZStack {
                BrandColors.surfaceHigh.opacity(0.88)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(BrandColors.text)
                }
                if saving {
                    Color.black.opacity(0.5)
                    ProgressView()
                        .controlSize(.small)
                        .tint(BrandColors.gold)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(last == nil)
        .opacity(last != nil || saving ? 1 : disabledAlpha)
        .accessibilityLabel(Strings.lastCapture)
        .task(id: last) {
            thumbnail = nil
            if let last { thumbnail = await CaptureSaver.thumbnail(for: last) }
        }
    }
}
