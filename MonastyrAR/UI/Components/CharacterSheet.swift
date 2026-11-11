import StageCore
import SwiftUI
import UniformTypeIdentifiers

/// "Postacie": the character library. Lists the characters that are in the app (tap one to put it on the stage,
/// delete it, update it) and the ones the library offers for download, and imports a model from a file.
/// Port of `ui/components/CharacterSheet.kt`.
struct CharacterSheet: View {
    /// The characters in the app, downloaded and imported.
    let packs: [CharacterPack]
    /// What the library offers and the downloads in flight. The catalog is read here; the downloads are read by
    /// the rows, so that a progress tick redraws one row and not the sheet.
    let library: PackLibrary
    let mode: StageMode
    /// Ids of the packs that have a character on the stage.
    let onStageIds: Set<String>
    /// AR only: the pack waiting for a tap on a surface.
    let armedId: String?
    /// False when the stage is full; the list is then shown but cannot be picked from.
    let canAddMore: Bool
    /// A picked file is being copied in right now.
    let importing: Bool
    /// A pack was tapped; returns true when it was accepted (the sheet then closes).
    let onChoose: (CharacterPack) -> Bool
    let onRefresh: () -> Void
    let onDownload: (RemotePack) -> Void
    let onCancelDownload: (String) -> Void
    /// A failed download is to be started again.
    let onRetryDownload: (RemotePack) -> Void
    /// A file was picked in the Files browser.
    let onImport: (URL) -> Void
    let onDelete: (CharacterPack) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickingFile = false
    @State private var deleting: CharacterPack?
    @State private var query = ""

    var body: some View {
        let catalog = library.catalog
        // A refresh takes the catalog through loading. The list seen last stays up meanwhile.
        let offered: [LibraryEntry]? = isFailed(catalog) ? nil : library.entries
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !needle.isEmpty
        // Compared without letter case and diacritics: a creator types "lucznik" and means "Łucznik".
        let needleKey = NameOrder.searchKey(needle)
        // Only a downloaded copy takes an entry off the offer. A pack imported from a file that happens to have
        // the same id is another character: the entry stays, and downloading it moves the import to a free id.
        let downloadedIds = Set(packs.filter(\.isDownloaded).map(\.id))
        let available = LibraryRules.available(offered ?? [], downloadedIds: downloadedIds)
        let availableShown = LibraryRules.available(offered ?? [], downloadedIds: downloadedIds, needleKey: needleKey)
        let installedShown = packs.filter { LibraryRules.matches(name: $0.name, needleKey: needleKey) }
        let updates = LibraryRules.updates(offered ?? [], installed: packs.map { (id: $0.id, remoteVersion: $0.remoteVersion) })
        let showSearch = LibraryRules.showsSearch(query: query, installedCount: packs.count, availableCount: available.count)

        VStack(alignment: .leading, spacing: 0) {
            header(catalog: catalog)
            if showSearch {
                LibrarySearchField(query: $query)
                    .padding(.top, 12)
            }
            if !canAddMore {
                stageFullNotice
                    .padding(.top, 12)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if !installedShown.isEmpty {
                        LibrarySectionHeader(title: Strings.libraryInstalled(installedShown.count))
                        ForEach(installedShown) { pack in
                            InstalledPackRow(
                                pack: pack,
                                onStage: onStageIds.contains(pack.id),
                                armed: pack.id == armedId,
                                enabled: canAddMore,
                                update: updates[pack.id],
                                library: library,
                                onTap: {
                                    if onChoose(pack) { dismiss() }
                                },
                                onDelete: { deleting = pack },
                                onDownload: onDownload,
                                onCancelDownload: onCancelDownload,
                                onRetryDownload: onRetryDownload
                            )
                        }
                    }
                    if searching && installedShown.isEmpty && availableShown.isEmpty {
                        LibraryNote(text: Strings.libraryNoResults(needle))
                    }
                    availableSection(catalog: catalog, offered: offered, shown: availableShown, searching: searching)
                }
                .padding(.vertical, 4)
            }
            .scrollDismissesKeyboard(.immediately)
            .padding(.top, 12)

            // Under the list and not at its end, where a few hundred characters would bury it. A typed query
            // leaves the room to its results; the keyboard has taken half of the sheet by then.
            if !searching {
                importFooter
            }
        }
        .foregroundStyle(BrandColors.text)
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 20)
        // Opening the library is the moment to ask what the server offers now: the list fetched when the app
        // started may be hours old, and downloading from an outdated one fails. A fetch that is already running
        // is joined.
        .onAppear { onRefresh() }
        .onChange(of: query) { _, typed in
            if typed.count > LibraryRules.maxQueryLength {
                query = String(typed.prefix(LibraryRules.maxQueryLength))
            }
        }
        // Any file may be picked; what it is gets decided by its first bytes, never by its name.
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                // The copy can take a while and its result is a message, which the sheet would cover.
                dismiss()
                onImport(url)
            }
        }
        .alert(
            deleting.map { Strings.deletePackTitle($0.name) } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { pack in
            Button(Strings.delete, role: .destructive) { onDelete(pack) }
            Button(Strings.cancel, role: .cancel) {}
        } message: { pack in
            Text(pack.isDownloaded ? Strings.deleteDownloadedPackBody : Strings.deletePackBody)
        }
    }

    // MARK: pieces

    private func isFailed(_ catalog: CatalogState) -> Bool {
        if case .failed = catalog { return true }
        return false
    }

    private func header(catalog: CatalogState) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.characters)
                    .font(.brandTitleLarge)
                Text(mode == .ar ? Strings.charactersHintAR : Strings.charactersHintStudio)
                    .font(.brandBodyMedium)
                    .foregroundStyle(BrandColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(BrandColors.text)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(catalog == .loading)
            .opacity(catalog == .loading ? disabledAlpha : 1)
            .accessibilityLabel(Strings.libraryRefresh)
        }
    }

    /// "Do pobrania": what the library still offers, or why that cannot be shown.
    @ViewBuilder
    private func availableSection(
        catalog: CatalogState,
        offered: [LibraryEntry]?,
        shown: [RemotePack],
        searching: Bool
    ) -> some View {
        if case .failed(let error) = catalog {
            LibrarySectionHeader(title: Strings.libraryAvailable)
            LibraryFailureCard(error: error, onRetry: onRefresh)
        } else if let offered {
            if !shown.isEmpty {
                LibrarySectionHeader(title: Strings.libraryAvailableCount(shown.count), busy: isRefreshing(catalog))
                ForEach(shown) { pack in
                    RemotePackRow(
                        pack: pack,
                        library: library,
                        onDownload: onDownload,
                        onCancelDownload: onCancelDownload,
                        onRetryDownload: onRetryDownload
                    )
                }
            } else if searching {
                // A query that matches nothing here is answered by the "no results" line above.
                EmptyView()
            } else if offered.isEmpty {
                LibraryNote(text: Strings.libraryEmpty)
            } else {
                LibraryNote(text: Strings.libraryAllDownloaded)
            }
        } else {
            LibrarySectionHeader(title: Strings.libraryAvailable)
            LibraryLoadingRow()
        }
    }

    /// The catalog on show is being fetched again behind the rows.
    private func isRefreshing(_ catalog: CatalogState) -> Bool {
        if case .ready = catalog { return false }
        return true
    }

    private var stageFullNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
            Text(Strings.stageFull)
                .font(.brandBodyMedium)
            Spacer(minLength: 0)
        }
        .foregroundStyle(BrandColors.gold)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(BrandColors.goldDeep, in: RoundedRectangle(cornerRadius: BrandShapes.small))
    }

    /// Under the list: bring in a model from a file, and whose models those may be.
    private var importFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    Text(importing ? Strings.importing : Strings.importModel)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(FilledBrandButtonStyle())
            .disabled(importing)
            .padding(.top, 16)

            Text(Strings.importNote)
                .font(.brandBodySmall)
                .foregroundStyle(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }
}
