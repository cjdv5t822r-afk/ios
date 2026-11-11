import Foundation
import StageCore

/// Persists `AppSettings` in `UserDefaults`, under the same key names the Android app uses in its DataStore.
/// Reads and writes are small and synchronous; the view model debounces the writes.
struct SettingsRepository {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        var stored: [String: Any] = [:]
        for key in AppSettings.Keys.all {
            if let value = defaults.object(forKey: key) { stored[key] = value }
        }
        return AppSettings(stored: stored)
    }

    func save(_ settings: AppSettings) {
        let stored = settings.stored
        for key in AppSettings.Keys.all {
            if let value = stored[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
