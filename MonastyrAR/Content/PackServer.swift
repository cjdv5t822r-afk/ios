import Foundation
import StageCore

/// Where the character library lives. The address is kept in one place, the `PacksBaseURL` property of the
/// Info.plist (set in `project.yml`); under it the server holds `catalog.json` and `characters/<id>/<file>`.
enum PackServer {

    /// Info.plist key of the address, and the name of the launch argument that overrides it.
    static let key = "PacksBaseURL"

    /// The base address without a trailing slash, read once at start. Nil when the app was built without one.
    ///
    /// A developer can point the app at a local test server (`tools/serve-packs.mjs`) without touching the
    /// sources by passing the launch argument `-PacksBaseURL http://192.168.0.10:8787`: `UserDefaults` reads
    /// launch arguments before anything stored. Plain HTTP only gets through App Transport Security for local
    /// addresses (`NSAllowsLocalNetworking`), and the downloader takes it only when the base itself is HTTP.
    static let baseURL: String? = {
        if let override = UserDefaults.standard.string(forKey: key),
           let base = PackServerRules.normalizedBase(override) {
            return base
        }
        guard let configured = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        return PackServerRules.normalizedBase(configured)
    }()
}
