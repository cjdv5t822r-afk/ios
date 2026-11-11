import Foundation

/// A catalog entry as the library list holds it: with the key the search compares.
public struct LibraryEntry: Equatable, Identifiable, Sendable {
    public let pack: RemotePack
    public let searchKey: String

    public init(pack: RemotePack) {
        self.pack = pack
        searchKey = NameOrder.searchKey(pack.displayName)
    }

    public var id: String { pack.id }
}

/// What the character library shows, worked out from the catalog and the packs on the phone.
/// The same decisions as `ui/components/CharacterSheet.kt` makes.
public enum LibraryRules {

    /// With more entries than this the list gets a search field.
    public static let searchThreshold = 8

    public static let maxQueryLength = 64

    /// The catalog as the list shows it: by name, in Polish order. An id becomes a row identity, so a catalog
    /// that repeats one gets only its first entry into the list.
    public static func entries(_ catalog: [RemotePack]) -> [LibraryEntry] {
        var seen = Set<String>()
        let unique = catalog.filter { seen.insert($0.id).inserted }
        return NameOrder.sorted(unique, by: { $0.displayName }).map { LibraryEntry(pack: $0) }
    }

    /// The entries still on offer. Only a downloaded copy takes an entry off the offer: a pack imported from a
    /// file that happens to have the same id is another character, so `downloadedIds` must not include it.
    /// - Parameter needleKey: `NameOrder.searchKey` of what the creator typed; empty for no search
    public static func available(_ entries: [LibraryEntry], downloadedIds: Set<String>, needleKey: String = "") -> [RemotePack] {
        var offered: [RemotePack] = []
        for entry in entries where !downloadedIds.contains(entry.id) {
            if needleKey.isEmpty || entry.searchKey.contains(needleKey) {
                offered.append(entry.pack)
            }
        }
        return offered
    }

    /// Whether `name` is among the results of a search for `needleKey`.
    public static func matches(name: String, needleKey: String) -> Bool {
        needleKey.isEmpty || NameOrder.searchKey(name).contains(needleKey)
    }

    /// Whether a pack on the phone has a newer version waiting in the catalog.
    /// - Parameter installedVersion: the catalog version it was downloaded as; nil for a pack imported from a
    ///   file, which is the creator's own model and is never replaced by the library
    public static func hasUpdate(installedVersion: String?, remoteVersion: String) -> Bool {
        guard let installedVersion else { return false }
        return !remoteVersion.isEmpty && remoteVersion != installedVersion
    }

    /// The catalog entry that updates each downloaded pack, by pack id.
    public static func updates(
        _ entries: [LibraryEntry],
        installed: [(id: String, remoteVersion: String?)]
    ) -> [String: RemotePack] {
        var offered: [String: RemotePack] = [:]
        for entry in entries where offered[entry.id] == nil {
            offered[entry.id] = entry.pack
        }
        var updates: [String: RemotePack] = [:]
        for pack in installed {
            guard let remote = offered[pack.id],
                  hasUpdate(installedVersion: pack.remoteVersion, remoteVersion: remote.version)
            else { continue }
            updates[pack.id] = remote
        }
        return updates
    }

    /// The field does not go away under a query, whatever happens to the lists meanwhile.
    public static func showsSearch(query: String, installedCount: Int, availableCount: Int) -> Bool {
        !query.isEmpty || installedCount + availableCount > searchThreshold
    }
}

/// The on-disk layout of the packs folder, shared by the importer and the library (see `content/PackStore.kt`).
/// Who owns a pack folder is told by one file:
///  - a folder with `versionFile` was downloaded and belongs to the library, which may replace it with a newer
///    download of the same id;
///  - a folder without it was imported from a file and is never replaced by anyone.
public enum PackStoreRules {
    /// Holds the catalog version a downloaded pack was installed from.
    public static let versionFile = ".remote-version"

    /// `.download-<id>-<n>`: files of a download that is still running, one folder per attempt.
    public static let stagingPrefix = ".download-"

    /// `.import-<n>`: a picked file while the importer copies and checks it.
    public static let importPrefix = ".import-"

    /// `.replaced-<id>`: the previous copy of a downloaded pack while its replacement is being moved in.
    public static let backupPrefix = ".replaced-"

    /// The version a downloaded pack counts as having, from the text of its version file. A version file that
    /// cannot be read (`nil`) or holds something odd gives an empty version: the pack stays the library's, and
    /// differs from whatever the catalog offers.
    public static func storedVersion(_ text: String?) -> String {
        guard let text else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return CatalogRules.isVersion(trimmed) ? trimmed : ""
    }

    /// What the clean-up at start does with one entry of the packs folder.
    public enum Leftover: Equatable, Sendable {
        /// A pack, or something else that is none of the library's business.
        case keep
        /// Staging of a download or an import that a killed process left behind.
        case remove
        /// A pack that was caught between "old copy moved away" and "new copy moved in": it gets its id back.
        case restore(id: String)
    }

    /// - Parameter isTaken: whether an entry of that name exists in the packs folder
    public static func leftover(named name: String, isTaken: (String) -> Bool) -> Leftover {
        if name.hasPrefix(stagingPrefix) || name.hasPrefix(importPrefix) { return .remove }
        guard name.hasPrefix(backupPrefix) else { return .keep }
        let id = String(name.dropFirst(backupPrefix.count))
        if !CatalogRules.isSafeId(id) || isTaken(id) { return .remove }
        return .restore(id: id)
    }

    /// Name of the staging folder of one download attempt.
    public static func stagingName(packId: String, attempt: String) -> String {
        "\(stagingPrefix)\(packId)-\(attempt)"
    }
}

/// Whose fault a failed request is.
public enum NetworkFault: Equatable, Sendable {
    /// The server answered, but not with the file.
    case server
    /// The server could not be reached.
    case offline
}

/// Addresses on the pack server and what the downloader accepts from it (see `content/PackTransport.kt`).
public enum PackServerRules {

    public static let maxRedirects = 5

    /// `text` as a base address: trimmed, without trailing slashes. Nil when it is not an `http(s)://host`
    /// address or carries a query or a fragment.
    public static func normalizedBase(_ text: String) -> String? {
        var base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard let url = URL(string: base),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty,
              url.query == nil, url.fragment == nil
        else { return nil }
        return base
    }

    /// Plain HTTP is accepted only when the configured base address is itself HTTP, which is the local test
    /// server of a developer.
    public static func allowsPlainHTTP(base: String) -> Bool {
        base.lowercased().hasPrefix("http://")
    }

    public static func catalogURL(base: String) -> URL? {
        URL(string: "\(base)/catalog.json")
    }

    /// Nil unless the id and the file name are the plain, URL-safe text the catalog rules demand.
    public static func fileURL(base: String, packId: String, fileName: String) -> URL? {
        guard CatalogRules.isSafeId(packId), CatalogRules.isSafeFileName(fileName) else { return nil }
        return URL(string: "\(base)/characters/\(packId)/\(fileName)")
    }

    public static func isAllowedScheme(_ url: URL, allowHTTP: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || (allowHTTP && scheme == "http")
    }

    /// Redirects are held to the rules: never to another host, and never from HTTPS down to HTTP.
    public static func isAllowedRedirect(from: URL, to: URL, allowHTTP: Bool) -> Bool {
        guard isAllowedScheme(to, allowHTTP: allowHTTP),
              let fromHost = from.host?.lowercased(), !fromHost.isEmpty,
              let toHost = to.host?.lowercased()
        else { return false }
        return fromHost == toHost
    }

    /// The size a response announces must be the size the catalog lists. A length other than the listed one,
    /// longer or shorter, means this is not the file the catalog describes: most often a pack that was replaced
    /// on the server after the catalog was fetched.
    /// - Parameter announced: negative when the server did not say
    public static func announcedLengthMatches(announced: Int64, listed: Int64) -> Bool {
        announced < 0 || announced == listed
    }

    /// A failed request with nothing wrong on the server's side means the phone could not reach it.
    public static func fault(for code: URLError.Code) -> NetworkFault {
        switch code {
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData,
             .httpTooManyRedirects, .redirectToNonExistentLocation, .dataLengthExceedsMaximum, .zeroByteResource,
             .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection, .userAuthenticationRequired,
             .resourceUnavailable, .fileDoesNotExist, .noPermissionsToReadFile:
            return .server
        default:
            return .offline
        }
    }

    public static func catalogError(for fault: NetworkFault) -> CatalogError {
        fault == .server ? .server : .offline
    }

    public static func downloadError(for fault: NetworkFault) -> DownloadError {
        fault == .server ? .server : .offline
    }
}
