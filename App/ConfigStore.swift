import Foundation
import RommpleTVKit

enum ConfigStore {
    // UserDefaults sits in tvOS's small guaranteed-persistent slice — right
    // place for a URL + token, wrong place for anything bigger.
    static func load() -> RommConfig? {
        let d = UserDefaults.standard
        guard let urlString = d.string(forKey: "romm.baseURL"),
              let url = URL(string: urlString),
              let token = d.string(forKey: "romm.token"), !token.isEmpty
        else { return nil }
        return RommConfig(baseURL: url, token: token)
    }
    /// Stored configuration, falling back to whatever the build baked in.
    ///
    /// Baking a URL and token into a development build avoids typing them on a
    /// television with a Siri Remote. It is a shortcut, not the intended end
    /// state — a real auth flow (the TV displaying a code that a phone
    /// authorizes, since the Apple TV has no camera to scan one) belongs on the
    /// polish list. Values come from `scripts/gen-local-config.sh` and are empty
    /// in any build without an untracked `Config/local.env` and `.romm.token`.
    ///
    /// Note that a baked build re-seeds itself on the next launch after a reset;
    /// the reset still works, it just does not survive relaunch.
    static func loadOrSeedFromBakedDefaults() -> RommConfig? {
        if let stored = load() { return stored }
        guard !LocalConfig.defaultBaseURL.isEmpty, !LocalConfig.defaultToken.isEmpty,
              save(baseURL: LocalConfig.defaultBaseURL, token: LocalConfig.defaultToken)
        else { return nil }
        return load()
    }

    @discardableResult
    static func save(baseURL: String, token: String) -> Bool {
        var normalized = baseURL
        if normalized.hasSuffix("/") { normalized.removeLast() }  // path-building appends its own
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil,
              !token.isEmpty
        else { return false }
        let d = UserDefaults.standard
        d.set(normalized, forKey: "romm.baseURL")
        d.set(token, forKey: "romm.token")
        return true
    }
    static func reset() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "romm.baseURL")
        d.removeObject(forKey: "romm.token")
    }
}
