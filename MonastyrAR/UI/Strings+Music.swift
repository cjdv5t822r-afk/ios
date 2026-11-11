import Foundation
import StageCore

/// The texts of the music feature, the same wording as the music strings in `ui/Strings.kt`.
extension Strings {

    // Tool column
    static let toolMusic = "Muzyka"
    static let toolMusicDescription = "Wybierz muzykę do nagrania"

    // Stage overlays
    static let importingMusic = "Importowanie utworu…"
    static let addingMusic = "Dodawanie muzyki…"

    // Music sheet
    static let music = "Muzyka"
    static let musicHint = "Podkład trafia do nagranego filmu"
    static let musicNone = "Bez muzyki"
    static let musicNoneCaption = "Film bez podkładu"
    static let musicOriginBuiltIn = "wbudowana"
    static let musicOriginImported = "importowana"
    static let musicVolume = "Głośność"
    static let musicGuide = "Odtwarzaj podczas nagrywania"
    static let musicGuideCaption = "Słyszysz podkład z głośnika, żeby trafić w rytm. Do filmu trafia czysta ścieżka."
    static let importMusic = "Importuj utwór"
    static let musicNote =
        "Wbudowane podkłady są oryginalne i wolne do użycia. Importuj tylko muzykę, do której masz prawa."
    static let deleteMusic = "Usuń utwór"
    static let deleteMusicBody = "Utwór zostanie usunięty z aplikacji. Plik źródłowy pozostanie na telefonie."
    static let musicDeleteFailed = "Nie udało się usunąć utworu"

    // Settings sheet
    static let microphoneMusic = "Wyłączony, gdy wybrano muzykę"

    // Messages
    static let captureFailureMusic = "Nie udało się dodać muzyki — film zapisano bez dźwięku"

    static func musicImportError(_ error: MusicImportError) -> String {
        switch error {
        case .cannotRead: return "Nie udało się odczytać pliku"
        case .notAudio: return "Telefon nie potrafi odtworzyć tego pliku jako muzyki"
        case .tooLarge: return "Plik z muzyką jest za duży"
        case .storage: return "Brak miejsca lub błąd zapisu w pamięci telefonu"
        }
    }

    static func musicImportedMessage(_ title: String) -> String { "Zaimportowano: \(title)" }

    static func musicDeletedMessage(_ title: String) -> String { "Usunięto: \(title)" }

    /// What the music button and the chip by the record button say to VoiceOver.
    static func musicSelected(_ title: String) -> String { "\(music): \(title)" }

    /// Caption of a row in the music list: where the track comes from and, when known, how long it is.
    static func musicCaption(isBuiltIn: Bool, seconds: Float?) -> String {
        let origin = isBuiltIn ? musicOriginBuiltIn : musicOriginImported
        if let seconds, seconds > 0 { return "\(origin) • \(trackLength(seconds))" }
        return origin
    }

    static func musicPreviewDescription(_ title: String) -> String { "Odsłuchaj: \(title)" }

    static func musicStopDescription(_ title: String) -> String { "Zatrzymaj odsłuch: \(title)" }

    static func deleteMusicTitle(_ title: String) -> String { "Usunąć „\(title)”?" }

    static func deleteMusicDescription(_ title: String) -> String { "\(deleteMusic): \(title)" }

    /// Track length as `m:ss`.
    static func trackLength(_ seconds: Float) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(min(max(seconds, 0), 359_999).rounded())
        let rest = total % 60
        return String(total / 60) + ":" + (rest < 10 ? "0" : "") + String(rest)
    }
}
