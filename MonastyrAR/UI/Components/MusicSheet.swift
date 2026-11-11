import StageCore
import SwiftUI
import UniformTypeIdentifiers

/// "Muzyka": choose the backing track for the next recordings, listen to it, import one, delete an imported one.
/// Every control writes through at once; there is nothing to confirm. Port of `ui/components/MusicSheet.kt`.
struct MusicSheet: View {
    let tracks: [MusicTrack]
    let settings: AppSettings
    /// Plays the previews; a preview still playing is stopped when the sheet closes.
    let player: MusicPlayer
    /// A picked file is being copied in right now.
    let importing: Bool
    /// A row was tapped; nil stands for "Bez muzyki".
    let onSelect: (MusicTrack?) -> Void
    let onChange: (@escaping (inout AppSettings) -> Void) -> Void
    /// A file was picked in the Files browser.
    let onImport: (URL) -> Void
    let onDelete: (MusicTrack) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickingFile = false
    @State private var deleting: MusicTrack?

    var body: some View {
        let selectedId = settings.musicTrackId
        let playingId = player.playingId
        VStack(alignment: .leading, spacing: 0) {
            Text(Strings.music)
                .font(.brandTitleLarge)
            Text(Strings.musicHint)
                .font(.brandBodyMedium)
                .foregroundStyle(BrandColors.textMuted)
                .padding(.top, 2)
            ScrollView {
                LazyVStack(spacing: 8) {
                    MusicRow(
                        title: Strings.musicNone, caption: Strings.musicNoneCaption, symbol: "speaker.slash.fill",
                        selected: selectedId == nil, onTap: { onSelect(nil) }
                    ) {
                        Color.clear.frame(width: 8, height: 1)
                    }
                    ForEach(tracks) { track in
                        MusicRow(
                            title: track.title,
                            caption: Strings.musicCaption(isBuiltIn: track.isBuiltIn, seconds: track.seconds),
                            symbol: "music.note",
                            selected: track.id == selectedId,
                            onTap: { onSelect(track) }
                        ) {
                            previewButton(track, playing: track.id == playingId)
                            if !track.isBuiltIn {
                                deleteButton(track)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        volumeRow
                        guideRow
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.top, 12)

            Button {
                pickingFile = true
            } label: {
                HStack(spacing: 10) {
                    if importing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(BrandColors.onGold)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text(importing ? Strings.importingMusic : Strings.importMusic)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(FilledBrandButtonStyle())
            .disabled(importing)
            .padding(.top, 16)

            Text(Strings.musicNote)
                .font(.brandBodySmall)
                .foregroundStyle(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .foregroundStyle(BrandColors.text)
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 20)
        // Audio files only; whether the phone can really play the picked one is decided by opening it.
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                // Same as a model: the result is a message, and the stage shows the progress meanwhile.
                dismiss()
                onImport(url)
            }
        }
        .alert(
            deleting.map { Strings.deleteMusicTitle($0.title) } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { track in
            Button(Strings.delete, role: .destructive) {
                // The player must let go of the file before it is removed.
                if track.id == player.playingId { player.stop() }
                onDelete(track)
            }
            Button(Strings.cancel, role: .cancel) {}
        } message: { _ in
            Text(Strings.deleteMusicBody)
        }
        .onDisappear {
            player.stopPreview()
        }
    }

    // MARK: pieces

    private func previewButton(_ track: MusicTrack, playing: Bool) -> some View {
        Button {
            if playing {
                player.stop()
            } else {
                player.preview(track, volume: settings.musicVolume)
            }
        } label: {
            Image(systemName: playing ? "stop.fill" : "play.fill")
                .font(.system(size: 16))
                .foregroundStyle(playing ? BrandColors.gold : BrandColors.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            playing ? Strings.musicStopDescription(track.title) : Strings.musicPreviewDescription(track.title)
        )
    }

    private func deleteButton(_ track: MusicTrack) -> some View {
        Button {
            deleting = track
        } label: {
            Image(systemName: "trash.fill")
                .font(.system(size: 16))
                .foregroundStyle(BrandColors.textMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.deleteMusicDescription(track.title))
    }

    /// "Głośność": how loud the track is in the recording and from the speaker. A preview that is playing follows
    /// the slider as it moves.
    private var volumeRow: some View {
        let range = AppSettings.musicVolumeMin...Float(1)
        let shown = min(max(settings.musicVolume, range.lowerBound), range.upperBound)
        let percent = Strings.percent(shown)
        let value = Binding<Float>(
            get: { shown },
            set: { level in
                onChange { $0.musicVolume = level }
                player.setVolume(level)
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Strings.musicVolume)
                    .font(.brandBodyLarge)
                Spacer()
                Text(percent)
                    .font(.brandBodyMedium)
                    .foregroundStyle(BrandColors.textMuted)
                    .accessibilityHidden(true)
            }
            Slider(value: value, in: range)
                .tint(BrandColors.gold)
                .accessibilityLabel(Strings.musicVolume)
                .accessibilityValue(percent)
        }
        .padding(.top, 12)
    }

    /// "Odtwarzaj podczas nagrywania": the guide from the speaker during a take.
    private var guideRow: some View {
        let isOn = Binding<Bool>(
            get: { settings.musicGuide },
            set: { on in onChange { $0.musicGuide = on } }
        )
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.musicGuide)
                    .font(.brandBodyLarge)
                Text(Strings.musicGuideCaption)
                    .font(.brandBodySmall)
                    .foregroundStyle(BrandColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 16)
        }
        .tint(BrandColors.gold)
        .frame(minHeight: 56)
        .padding(.vertical, 6)
    }
}

/// One choice in the list: a round badge, two lines of text and whatever `actions` the row offers on the right.
/// Gold badge and border when `selected`.
private struct MusicRow<Actions: View>: View {
    let title: String
    let caption: String
    let symbol: String
    let selected: Bool
    let onTap: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BrandShapes.medium)
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(selected ? BrandColors.onGold : BrandColors.gold)
                        .frame(width: 40, height: 40)
                        .background(selected ? BrandColors.gold : BrandColors.goldDeep, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.brandTitleMedium)
                            .foregroundStyle(BrandColors.text)
                            .lineLimit(1)
                        Text(caption)
                            .font(.brandBodySmall)
                            .foregroundStyle(BrandColors.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            actions()
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(minHeight: 64)
        .background(BrandColors.surfaceHigh, in: shape)
        .overlay(shape.stroke(selected ? BrandColors.gold.opacity(0.7) : BrandColors.outline, lineWidth: 1))
    }
}
