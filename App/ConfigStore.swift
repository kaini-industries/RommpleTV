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
