import Foundation

/// Message texts about downloads from the pack server. Port of `content/LibraryMessages.kt`.
public enum LibraryMessages {

    public static func downloaded(_ name: String) -> String { "Pobrano: \(name)" }

    public static func downloadedStageFull(_ name: String) -> String { "Pobrano: \(name). Scena jest pełna" }

    /// A newer version arrived while the character stands on the stage, where it keeps the version it has.
    public static func updatedOnStage(_ name: String) -> String {
        "Zaktualizowano: \(name). Nową wersję zobaczysz po ponownym dodaniu postaci"
    }

    public static func downloadFailed(_ name: String, error: DownloadError) -> String {
        "Nie udało się pobrać „\(name)” — \(reason(error))"
    }

    private static func reason(_ error: DownloadError) -> String {
        switch error {
        case .offline: return "brak połączenia z internetem"
        case .server: return "serwer z postaciami zwrócił błąd"
        case .checksum: return "pobrane pliki są uszkodzone, spróbuj ponownie"
        case .noSpace: return "za mało miejsca w pamięci telefonu"
        case .tooLarge: return "paczka jest większa, niż podaje katalog"
        case .storage: return "błąd zapisu w pamięci telefonu"
        }
    }
}

/// Numbers as the library rows show them. The same arithmetic as `ui/Strings.kt`.
public enum LibraryFormat {

    /// Beyond any real size, and small enough that the arithmetic below cannot overflow.
    private static let largestSize: Int64 = 1_000_000_000_000_000

    /// `243 kB`, `12,4 MB`: decimal units, as the system's storage screens count them, and the Polish decimal comma.
    public static func fileSize(_ bytes: Int64) -> String {
        let size = min(max(bytes, 0), largestSize)
        // Each limit is where rounding would otherwise print 1000 of the smaller unit.
        if size < 1_000 { return "\(size) B" }
        if size < 999_500 { return "\((size + 500) / 1_000) kB" }
        if size < 999_950_000 { return "\(oneDecimal(size, unit: 1_000_000)) MB" }
        return "\(oneDecimal(size, unit: 1_000_000_000)) GB"
    }

    /// `1 animacja`, `3 animacje`, `5 animacji`, `12 animacji`, `22 animacje`.
    public static func animations(_ count: Int) -> String {
        let noun: String
        if count == 1 {
            noun = "animacja"
        } else if (2...4).contains(count % 10) && !(12...14).contains(count % 100) {
            noun = "animacje"
        } else {
            noun = "animacji"
        }
        return "\(count) \(noun)"
    }

    /// Caption of a library row: how much there is to download and, when the catalog says so, how many clips.
    public static func remotePackCaption(bytes: Int64, clips: Int?) -> String {
        var parts: [String] = []
        if bytes > 0 { parts.append(fileSize(bytes)) }
        if let clips, clips >= 0 { parts.append(animations(clips)) }
        return parts.joined(separator: " • ")
    }

    /// `size` in `unit`s, rounded to one decimal place.
    private static func oneDecimal(_ size: Int64, unit: Int64) -> String {
        let tenths = (size * 10 + unit / 2) / unit
        return "\(tenths / 10),\(tenths % 10)"
    }
}
