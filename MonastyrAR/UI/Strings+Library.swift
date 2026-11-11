import Foundation
import StageCore

/// Texts of the character library: the "Postacie" sheet, its rows and the card that leads to it.
/// The same wording as the library strings of `ui/Strings.kt`.
extension Strings {

    // First character card
    static let firstCharacterTitle = "Pobierz pierwszą postać"
    static let firstCharacterBody = "Postacie pobierasz z biblioteki — wybierz, co chcesz mieć na scenie."
    static let openLibrary = "Otwórz bibliotekę"
    static let downloadingPack = "Pobieranie postaci…"

    // Character sheet (the library)
    static let libraryRefresh = "Odśwież bibliotekę"
    static let librarySearch = "Szukaj postaci"
    static let librarySearchClear = "Wyczyść wyszukiwanie"
    static let libraryAvailable = "Do pobrania"
    static let libraryLoading = "Wczytywanie biblioteki…"
    static let libraryRetry = "Spróbuj ponownie"
    static let libraryAllDownloaded = "Wszystkie postacie z biblioteki są już pobrane"
    static let libraryEmpty = "Biblioteka jest pusta"
    static let packDownloaded = "pobrana"
    static let packUpdate = "Aktualizuj"
    static let downloadRetry = "Ponów"
    static let deleteDownloadedPackBody =
        "Model zostanie usunięty z aplikacji. Możesz go potem pobrać ponownie z biblioteki."

    static func libraryInstalled(_ count: Int) -> String { "Pobrane (\(count))" }

    static func libraryAvailableCount(_ count: Int) -> String { "\(libraryAvailable) (\(count))" }

    static func libraryNoResults(_ query: String) -> String { "Brak postaci pasujących do „\(query)”" }

    static func catalogError(_ error: CatalogError) -> String {
        switch error {
        case .offline: return "Brak połączenia z internetem"
        case .server: return "Serwer biblioteki nie odpowiada"
        case .badData: return "Biblioteka ma nieprawidłowy format"
        }
    }

    /// Why a download failed, short enough for the row of the pack it belongs to.
    static func downloadError(_ error: DownloadError) -> String {
        switch error {
        case .offline: return "Brak połączenia z internetem"
        case .server: return "Błąd serwera biblioteki"
        case .checksum: return "Pobrany plik jest uszkodzony"
        case .noSpace: return "Za mało miejsca w telefonie"
        case .tooLarge: return "Plik jest większy, niż podaje biblioteka"
        case .storage: return "Błąd zapisu w pamięci telefonu"
        }
    }

    /// Caption of a library row: how much there is to download and, when the catalog says so, how many clips.
    static func remotePackCaption(bytes: Int64, clips: Int?) -> String {
        LibraryFormat.remotePackCaption(bytes: bytes, clips: clips)
    }

    static func downloadPackDescription(_ name: String) -> String { "Pobierz: \(name)" }

    static func updatePackDescription(_ name: String) -> String { "\(packUpdate): \(name)" }

    static func cancelDownloadDescription(_ name: String) -> String { "Anuluj pobieranie: \(name)" }
}
