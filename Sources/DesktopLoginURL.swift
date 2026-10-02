import Foundation

enum DesktopLoginURL {
    static func matchesEndpoint(_ value: String) -> Bool {
        guard let url = URLComponents(string: value),
              let host = url.host?.lowercased() else { return false }
        return (host == "claude.com" && url.percentEncodedPath == "/cai/login/app-google-auth") ||
            (host == "claude.ai" && url.percentEncodedPath == "/login/app-google-auth")
    }

    static func isValid(_ value: String) -> Bool {
        guard value.utf8.count <= 1_024,
              value.range(of: #"^https://(?:claude\.com/cai|claude\.ai)/login/app-google-auth\?"#, options: .regularExpression) != nil,
              matchesEndpoint(value),
              let url = URLComponents(string: value),
              url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.fragment == nil,
              let items = url.queryItems else { return false }
        var values: [String: String] = [:]
        for item in items {
            guard item.name == "hop_nonce" || item.name == "open_in_browser",
                  let value = item.value,
                  values[item.name] == nil else { return false }
            values[item.name] = value
        }
        guard let nonce = values["hop_nonce"],
              nonce.range(of: #"^[A-Za-z0-9_-]{32}$"#, options: .regularExpression) != nil
        else { return false }
        return values["open_in_browser"] == nil || values["open_in_browser"] == "1"
    }
}
