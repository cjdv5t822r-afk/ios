import StageCore
import SwiftUI

/// Heading of a section of the library.
struct LibrarySectionHeader: View {
    let title: String
    /// The section is being refreshed behind what it shows.
    var busy = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.brandTitleSmall)
                .foregroundStyle(BrandColors.gold)
                .accessibilityAddTraits(.isHeader)
            if busy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(BrandColors.gold)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// "Szukaj postaci": narrows both sections of the library to the names that contain the query.
struct LibrarySearchField: View {
    @Binding var query: String

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(BrandColors.textMuted)
                .accessibilityHidden(true)
            TextField("", text: $query, prompt: Text(Strings.librarySearch))
                .font(.brandBodyLarge)
                .foregroundStyle(BrandColors.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // The list filters as the creator types; "search" on the keyboard only has to put the keyboard away.
                .submitLabel(.search)
                .onSubmit { focused = false }
                .focused($focused)
                .accessibilityLabel(Strings.librarySearch)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(BrandColors.textMuted)
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.librarySearchClear)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, query.isEmpty ? 14 : 6)
        .frame(minHeight: 48)
        .background(BrandColors.surfaceHigh, in: Capsule())
        .overlay(Capsule().stroke(focused ? BrandColors.gold : BrandColors.outline, lineWidth: 1))
    }
}

/// A character that is in the app: tap it to put it on the stage.
struct InstalledPackRow: View {
    let pack: CharacterPack
    let onStage: Bool
    let armed: Bool
    /// False when the stage is full; the row is then shown but cannot be picked.
    let enabled: Bool
    /// The newer version of this pack the library offers, or nil when there is none.
    let update: RemotePack?
    /// Read here, in the row, so that a progress tick redraws the one row it belongs to and not the whole sheet.
    let library: PackLibrary
    let onTap: () -> Void
    let onDelete: () -> Void
    let onDownload: (RemotePack) -> Void
    let onCancelDownload: (String) -> Void
    let onRetryDownload: (RemotePack) -> Void

    var body: some View {
        let name = pack.name
        // A download under the id of an imported pack belongs to the library's own row.
        let download: DownloadState? = pack.isDownloaded ? library.downloads[pack.id] : nil
        // Retrying needs the library's entry, so a failure is only shown while there is one to retry with.
        let failure: DownloadError? = update == nil ? nil : failedError(download)

        PackRowFrame(
            name: name,
            caption: caption(failure: failure),
            captionColor: captionColor(failure: failure),
            installed: true,
            highlighted: armed || onStage,
            dimmed: !enabled,
            onTap: onTap
        ) {
            if case .running(let fraction)? = download {
                // No delete button meanwhile: the pack is about to be replaced on disk.
                DownloadProgress(fraction: fraction, name: name, onCancel: { onCancelDownload(pack.id) })
            } else {
                if let update {
                    if failure != nil {
                        RetryButton(onRetry: { onRetryDownload(update) })
                    } else {
                        PillChip(label: Strings.packUpdate, selected: false, action: { onDownload(update) })
                            .accessibilityLabel(Strings.updatePackDescription(name))
                    }
                }
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(BrandColors.textMuted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.deletePackDescription(name))
            }
        }
    }

    /// Where the pack is on the stage, if it is there.
    private var status: String? {
        if armed { return Strings.packArmed }
        return onStage ? Strings.packOnStage : nil
    }

    private func caption(failure: DownloadError?) -> String {
        if let failure { return Strings.downloadError(failure) }
        let origin = pack.isDownloaded ? Strings.packDownloaded : Strings.packImported
        if let status { return "\(origin) • \(status)" }
        return origin
    }

    private func captionColor(failure: DownloadError?) -> Color {
        if failure != nil { return BrandColors.emberSoft }
        return status == nil ? BrandColors.textMuted : BrandColors.gold
    }
}

/// A character the library offers and the app does not have yet.
struct RemotePackRow: View {
    let pack: RemotePack
    /// Read here, in the row; see `InstalledPackRow`.
    let library: PackLibrary
    let onDownload: (RemotePack) -> Void
    let onCancelDownload: (String) -> Void
    let onRetryDownload: (RemotePack) -> Void

    var body: some View {
        let name = pack.displayName
        let download = library.downloads[pack.id]
        let failure = failedError(download)

        PackRowFrame(
            name: name,
            caption: caption(failure: failure),
            captionColor: failure == nil ? BrandColors.textMuted : BrandColors.emberSoft,
            installed: false,
            highlighted: false,
            dimmed: false,
            onTap: nil
        ) {
            switch download {
            case .running(let fraction)?:
                DownloadProgress(fraction: fraction, name: name, onCancel: { onCancelDownload(pack.id) })
            case .failed?:
                RetryButton(onRetry: { onRetryDownload(pack) })
            case nil:
                Button {
                    onDownload(pack)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 18))
                        .foregroundStyle(BrandColors.gold)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.downloadPackDescription(name))
            }
        }
    }

    private func caption(failure: DownloadError?) -> String {
        if let failure { return Strings.downloadError(failure) }
        return Strings.remotePackCaption(bytes: pack.bytes, clips: pack.clips)
    }
}

/// Stands in for the library's rows while the catalog is on its way.
struct LibraryLoadingRow: View {
    var body: some View {
        BusyPill(text: Strings.libraryLoading)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}

/// Stands in for the library's rows when the catalog could not be fetched: why, and a way to try again.
struct LibraryFailureCard: View {
    let error: CatalogError
    let onRetry: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BrandShapes.medium)
        VStack(spacing: 12) {
            ErrorPill(text: Strings.catalogError(error))
            Button(action: onRetry) {
                Text(Strings.libraryRetry)
                    .lineLimit(1)
                    .frame(minHeight: 48)
            }
            .buttonStyle(OutlinedBrandButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(BrandColors.surfaceHigh, in: shape)
        .overlay(shape.stroke(BrandColors.outline, lineWidth: 1))
    }
}

/// One quiet line where a section has nothing to list.
struct LibraryNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.brandBodyMedium)
            .foregroundStyle(BrandColors.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
    }
}

/// The error of a failed download; nil for one that is running or is not there at all.
private func failedError(_ download: DownloadState?) -> DownloadError? {
    if case .failed(let error)? = download { return error }
    return nil
}

/// The look every pack row shares: a round badge with the initial, the name over a caption, and whatever
/// actions the row offers on the right. Gold badge and border when `highlighted`.
private struct PackRowFrame<Actions: View>: View {
    let name: String
    let caption: String
    let captionColor: Color
    /// The pack is in the app; one that is only on offer gets a muted badge.
    let installed: Bool
    let highlighted: Bool
    /// The row cannot be picked right now; its actions stay at full strength.
    let dimmed: Bool
    /// What a tap on the row does, or nil for a row that only has its actions.
    let onTap: (() -> Void)?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BrandShapes.medium)
        HStack(spacing: 0) {
            if let onTap {
                Button(action: onTap) { label }
                    .buttonStyle(.plain)
                    .disabled(dimmed)
                    .opacity(dimmed ? disabledAlpha : 1)
            } else {
                label
            }
            actions()
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(minHeight: 64)
        .background(BrandColors.surfaceHigh, in: shape)
        .overlay(shape.stroke(highlighted ? BrandColors.gold.opacity(0.7) : BrandColors.outline, lineWidth: 1))
    }

    private var badgeInk: Color {
        if highlighted { return BrandColors.onGold }
        return installed ? BrandColors.gold : BrandColors.textMuted
    }

    private var badgeFill: Color {
        if highlighted { return BrandColors.gold }
        return installed ? BrandColors.goldDeep : BrandColors.surface
    }

    private var label: some View {
        HStack(spacing: 12) {
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(badgeInk)
                .frame(width: 40, height: 40)
                .background(badgeFill, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.brandTitleMedium)
                    .foregroundStyle(BrandColors.text)
                    .lineLimit(1)
                if !caption.isEmpty {
                    Text(caption)
                        .font(.brandBodySmall)
                        .foregroundStyle(captionColor)
                        // Room for a failure reason next to its retry button on a narrow phone.
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
    }
}

/// How far a download is, with the button that calls it off.
private struct DownloadProgress: View {
    let fraction: Float
    let name: String
    let onCancel: () -> Void

    var body: some View {
        // The fraction is worked out from sizes a server declared, so it is not trusted to be a number inside 0...1.
        let shown: Float = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        let percent = Strings.percent(shown)
        ZStack {
            Circle()
                .stroke(BrandColors.outline, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(shown))
                .stroke(BrandColors.gold, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percent)
                .font(.brandLabelSmall)
                .foregroundStyle(BrandColors.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 40, height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.downloadingPack)
        .accessibilityValue(percent)

        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BrandColors.textMuted)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.cancelDownloadDescription(name))
    }
}

private struct RetryButton: View {
    let onRetry: () -> Void

    var body: some View {
        Button(action: onRetry) {
            Text(Strings.downloadRetry)
                .font(.brandLabelLarge)
                .foregroundStyle(BrandColors.gold)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
