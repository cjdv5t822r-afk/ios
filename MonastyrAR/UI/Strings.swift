import Foundation
import StageCore

/// Every piece of text the creator can see or hear (VoiceOver), in one place. Polish, the same wording as
/// `ui/Strings.kt` except where Android and iOS call things differently (the photo library).
enum Strings {
    static let appName = "Monastyr AR"

    // Top bar
    static let modeAR = "AR"
    static let modeStudio = "Studio"
    static let modeARDescription = "Tryb AR"
    static let modeStudioDescription = "Tryb Studio"
    static let settings = "Ustawienia"

    // Tool column
    static let toolCharacter = "Postać"
    static let toolCharacterDescription = "Wybierz postać"
    static let toolFaceMe = "Do mnie"
    static let toolFaceMeDescription = "Obróć postać przodem do mnie"
    static let toolRealSize = "1:1"
    static let toolRealSizeDescription = "Rzeczywisty rozmiar"
    static let toolSizePresets = "Wybierz rozmiar"
    static let toolPause = "Pauza"
    static let toolPauseDescription = "Wstrzymaj animację"
    static let toolResume = "Wznów"
    static let toolResumeDescription = "Wznów animację"
    static let toolSpeed = "Tempo"
    static let toolAll = "Wszyscy"
    static let toolAllDescription = "Steruj wszystkimi postaciami naraz"
    static let toolRemove = "Usuń"
    static let toolRemoveDescription = "Usuń postać ze sceny"
    static let sizeFigurine = "Figurka 0,15x"
    static let sizeReal = "Rzeczywisty 1:1"
    static let sizeGiant = "Gigant 3x"

    // Deck
    static let categoryAll = "Wszystkie"
    static let deckNoActor = "Dodaj postać, aby zobaczyć animacje"
    static let deckNoSelection = "Dotknij postaci, aby ją wybrać"
    static let deckNoClips = "Ten model nie ma animacji"
    static let deckLoading = "Wczytywanie animacji…"
    static let deckCollapse = "Zwiń animacje"
    static let deckExpand = "Rozwiń animacje"
    static let clipLoops = "w pętli"
    static let clipToggleLoop = "Odtwórz z odwróconą pętlą"
    static let recordStart = "Nagrywaj"
    static let recordStop = "Zatrzymaj nagrywanie"
    static let recordCancelCountdown = "Anuluj odliczanie"
    static let photo = "Zrób zdjęcie"
    static let lastCapture = "Udostępnij ostatnie nagranie"

    // Stage overlays
    static let loading = "Wczytywanie…"
    static let loadFailed = "Nie udało się wczytać modelu"
    /// iOS only: the model shows but its skeleton could not be built, so it stands still.
    static let animationUnavailable = "Tego modelu nie da się animować na iOS"
    static let importing = "Importowanie modelu…"
    static let checkingAR = "Sprawdzanie AR…"
    static let safeZone = "bezpieczna strefa"
    static let recording = "Nagrywanie"
    static let countdownCancel = "Dotknij, aby anulować"

    // Camera permission card
    static let cameraNeeded = "Tryb AR potrzebuje dostępu do aparatu"
    static let cameraNeededBody = "Obraz z aparatu zostaje na telefonie. Bez niego możesz nagrywać w trybie Studio."
    static let allow = "Zezwól"

    // Onboarding
    static let onboardingTitle = "Scena jest Twoja"
    static let onboardingPlace = "Wybierz postać i postaw ją na scenie"
    static let onboardingGestures = "Szczypnij, obróć i przeciągnij, aby ją ustawić"
    static let onboardingRecord = "Nagraj film lub zrób zdjęcie — logo doda się samo"
    static let onboardingDismiss = "Zaczynamy"

    // Character sheet
    static let characters = "Postacie"
    static let charactersHintAR = "Wybierz postać, a potem dotknij podłoża"
    static let charactersHintStudio = "Wybierz postać, aby dodać ją do sceny"
    static let packImported = "importowana"
    static let packOnStage = "na scenie"
    static let packArmed = "czeka na postawienie"
    static let stageFull = "Maksymalnie 5 postaci na scenie"
    static let importModel = "Importuj model (GLB lub ZIP)"
    static let importNote =
        "Aplikacja wczytuje modele GLB ze szkieletem i animacjami. Używaj tylko modeli, do których masz prawa."
    static let deletePack = "Usuń postać"
    static let deletePackBody = "Model zostanie usunięty z aplikacji. Plik źródłowy pozostanie na telefonie."
    static let delete = "Usuń"
    static let cancel = "Anuluj"
    static let deleteFailed = "Nie udało się usunąć postaci"

    // Settings sheet
    static let sectionWatermark = "Znak wodny"
    static let watermarkShow = "Pokazuj logo na nagraniach"
    static let watermarkPosition = "Położenie"
    static let watermarkSize = "Rozmiar"
    static let watermarkOpacity = "Krycie"
    static let sectionRecording = "Nagrywanie"
    static let countdown = "Odliczanie"
    static let maxDuration = "Limit czasu"
    static let microphone = "Mikrofon"
    static let microphoneCaption = "Nagrywa dźwięk z otoczenia razem z filmem"
    static let microphoneBlocked = "Brak dostępu do mikrofonu. Włącz go w ustawieniach systemu."
    static let safeZoneGuides = "Linie bezpiecznej strefy"
    static let safeZoneGuidesCaption = "Pokazują, gdzie aplikacje wideo zasłaniają kadr. Nie trafiają do nagrania."
    static let sectionAR = "AR"
    static let showPlanes = "Pokaż wykryte powierzchnie"
    static let groundShadow = "Cień pod postacią"
    static let depthOcclusion = "Zasłanianie przez otoczenie"
    static let depthOcclusionCaption = "Wymaga telefonu z obsługą głębi"
    static let sectionStudio = "Studio"
    static let studioBackground = "Tło"

    // Messages
    /// Android says "Zapisano w Galerii"; on an iPhone the place is the Zdjęcia app.
    static let saved = "Zapisano w Zdjęciach"
    static let share = "Udostępnij"
    static let arUnsupported = "To urządzenie nie obsługuje AR — włączono tryb Studio"

    static func arHint(_ hint: ArHint) -> String? {
        switch hint {
        case .none: return nil
        case .starting: return "Uruchamianie AR…"
        case .findSurface: return "Poruszaj telefonem, aby wykryć podłoże"
        case .tapToPlace: return "Dotknij podłoża, aby postawić postać"
        case .tooDark: return "Za ciemno"
        case .tooFast: return "Za szybki ruch"
        case .lowDetail: return "Skieruj aparat na powierzchnię z detalami"
        case .cameraBusy: return "Aparat jest zajęty"
        }
    }

    static func category(_ category: ClipCategory) -> String {
        switch category {
        case .idle: return "Stanie"
        case .move: return "Ruch"
        case .attack: return "Atak"
        case .emote: return "Emotki"
        case .other: return "Inne"
        }
    }

    static func captureFailure(_ failure: CaptureFailure) -> String {
        switch failure {
        case .notReady: return "Scena nie jest jeszcze gotowa"
        case .noVideo: return "Nagranie było zbyt krótkie"
        case .noPhoto: return "Nie udało się zrobić zdjęcia"
        case .storage: return "Nie udało się zapisać pliku"
        case .noLibraryAccess: return "Brak dostępu do Zdjęć. Nagranie możesz udostępnić przyciskiem obok spustu."
        case .music: return captureFailureMusic
        }
    }

    static func importError(_ error: ImportError) -> String {
        switch error {
        case .cannotRead: return "Nie udało się odczytać pliku"
        case .notAModel: return "To nie jest plik GLB ani ZIP"
        case .tooLarge: return "Plik jest za duży (limit 200 MB)"
        case .zipWithoutModel: return "W archiwum ZIP nie ma modelu GLB"
        case .badManifest: return "Paczka ma błędny plik character.json"
        case .storage: return "Brak miejsca lub błąd zapisu w pamięci telefonu"
        }
    }

    static func imported(_ name: String) -> String { "Zaimportowano: \(name)" }

    static func importedStageFull(_ name: String) -> String { "Zaimportowano: \(name). Scena jest pełna" }

    static func deleted(_ name: String) -> String { "Usunięto: \(name)" }

    static func deletePackTitle(_ name: String) -> String { "Usunąć „\(name)”?" }

    static func deletePackDescription(_ name: String) -> String { "\(deletePack): \(name)" }

    static func loadFailedMessage(_ name: String) -> String { "\(loadFailed): \(name)" }

    static func countdownChoice(_ seconds: Int) -> String { seconds == 0 ? "Brak" : "\(seconds) s" }

    static func maxDurationChoice(_ seconds: Int) -> String { seconds == 0 ? "Bez limitu" : "\(seconds) s" }

    static func studioBackgroundName(_ background: StudioBackground) -> String {
        switch background {
        case .green: return "Zielony"
        case .blue: return "Niebieski"
        case .black: return "Czarny"
        case .white: return "Biały"
        case .custom: return "Własny"
        }
    }

    static func anchor(_ anchor: WatermarkAnchor) -> String {
        switch anchor {
        case .topLeft: return "U góry po lewej"
        case .topCenter: return "U góry na środku"
        case .topRight: return "U góry po prawej"
        case .bottomLeft: return "Na dole po lewej"
        case .bottomCenter: return "Na dole na środku"
        case .bottomRight: return "Na dole po prawej"
        }
    }

    /// `1x`, `0,5x`: the decimal comma is the Polish one.
    static func speed(_ value: Float) -> String {
        let tenths = Int((value * 10).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)x" : "\(tenths / 10),\(tenths % 10)x"
    }

    static func speedDescription(_ value: Float) -> String { "\(toolSpeed) \(speed(value))" }

    static func percent(_ fraction: Float) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// Recording length as `mm:ss`.
    static func elapsed(millis: Int) -> String {
        let seconds = max(millis / 1_000, 0)
        let minutes = seconds / 60
        let rest = seconds % 60
        return (minutes < 10 ? "0" : "") + String(minutes) + ":" + (rest < 10 ? "0" : "") + String(rest)
    }

    static func version(_ name: String) -> String { "\(appName) • wersja \(name)" }
}
