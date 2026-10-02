import Foundation

enum ExternalURL {
    static func isValid(_ value: String) -> Bool {
        guard value.utf8.count <= 8_192,
              value.hasPrefix("https://"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = URLComponents(string: value),
              url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if DesktopLoginURL.matchesEndpoint(value) && !DesktopLoginURL.isValid(value) { return false }
        return url.port == nil || (1...65_535).contains(url.port!)
    }
}
