import CoreFoundation
import Darwin
import Foundation

struct ExitAssessment {
    let timeZone: TimeZone
    let languages: [String]
    let pageData: [String: Any]

    var encodedPageData: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: pageData, options: .sortedKeys) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func lookup(proxyURL: String, profileURL: URL) -> ExitAssessment? {
        guard let location = requestJSON(
            "https://ipwho.is/?fields=ip,success,country_code,timezone", proxyURL: proxyURL
        ), boolean(location["success"]) == true,
              let ip = location["ip"] as? String, validIP(ip),
              let country = location["country_code"] as? String,
              country.count == 2, country.utf8.allSatisfy({ (65...90).contains($0) }),
              let languages = languagePreferences(for: country),
              let zone = location["timezone"] as? [String: Any],
              let identifier = zone["id"] as? String,
              let timeZone = TimeZone(identifier: identifier)
        else { return nil }

        let now = (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        let cacheURL = profileURL.appendingPathComponent("Claude Chrome Exit.latest.json")
        if let cache = readCache(cacheURL),
           cache["schema"] as? Int == 1,
           cache["ip"] as? String == ip,
           cache["exitCountryCode"] as? String == country,
           cache["exitTimeZone"] as? String == identifier,
           let checkedAt = number(cache["checkedAt"]),
           checkedAt.rounded(.down) == checkedAt,
           checkedAt <= now,
           now - checkedAt < (cache["status"] as? String == "unknown" ? 60_000 : 1_800_000),
           cache["status"] as? String == "unknown" ||
               (["ok", "warning"].contains(cache["status"] as? String ?? "") && validDetections(cache["detections"]) != nil) {
            var updated = cache
            updated["exitLanguage"] = languages[0]
            updated["exitLanguages"] = languages
            return ExitAssessment(timeZone: timeZone, languages: languages, pageData: updated)
        }

        var assessment: [String: Any] = [
            "schema": 1, "ip": ip, "checkedAt": now, "status": "unknown",
            "exitCountryCode": country, "exitTimeZone": identifier,
            "exitLanguage": languages[0], "exitLanguages": languages,
        ]
        if let response = requestJSON("https://proxycheck.io/v3/\(ip)?ver=24-June-2026", proxyURL: proxyURL),
           let status = response["status"] as? String, status == "ok" || status == "warning",
           let record = response[ip] as? [String: Any],
           let detections = validDetections(record["detections"]),
           let network = record["network"] as? [String: Any],
           let networkType = network["type"] as? String, !networkType.isEmpty,
           let provider = network["provider"] as? String, !provider.isEmpty,
           let geography = record["location"] as? [String: Any],
           let code = geography["country_code"] as? String,
           let timeZoneID = geography["timezone"] as? String,
           TimeZone(identifier: timeZoneID) != nil {
            assessment["status"] = status
            assessment["countryCode"] = code
            assessment["timeZone"] = timeZoneID
            assessment["networkType"] = String(networkType.prefix(64))
            assessment["provider"] = String(provider.prefix(128))
            assessment["detections"] = detections
        }
        writeCache(assessment, to: cacheURL)
        return ExitAssessment(timeZone: timeZone, languages: languages, pageData: assessment)
    }

    private static func languagePreferences(for country: String) -> [String]? {
        let language = Locale.Language(identifier: Locale.Language(identifier: "und_\(country)").maximalIdentifier)
        guard let code = language.languageCode?.identifier, code != "und",
              let script = language.script?.identifier
        else { return nil }
        let defaultScript = Locale.Language(identifier: Locale.Language(identifier: code).maximalIdentifier).script?.identifier
        let fallback = code + (script == defaultScript ? "" : "-\(script)")
        return ["\(fallback)-\(country)", fallback]
    }

    private static func requestJSON(_ url: String, proxyURL: String) -> [String: Any]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-q", "--proxy", proxyURL, "--noproxy", "", "--proto", "=https",
            "--connect-timeout", "4", "--max-time", "8", "--max-filesize", "32768",
            "--fail", "--silent", "--show-error", url,
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty, data.count <= 32_768 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func validDetections(_ value: Any?) -> [String: Any]? {
        guard let object = value as? [String: Any] else { return nil }
        var result: [String: Any] = [:]
        for name in ["hosting", "proxy", "vpn", "tor", "compromised", "scraper", "anonymous"] {
            guard let value = boolean(object[name]) else { return nil }
            result[name] = value
        }
        for name in ["risk", "confidence"] {
            guard let value = number(object[name]), (0...100).contains(value) else { return nil }
            result[name] = value
        }
        return result
    }

    private static func validIP(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }

    private static func readCache(_ url: URL) -> [String: Any]? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              (status.st_mode & 0o777) == 0o600,
              status.st_size > 0, status.st_size <= 32_768,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeCache(_ value: [String: Any], to url: URL) {
        var status = stat()
        if Darwin.lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) != S_IFREG { return }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys), data.count <= 32_768 else { return }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {}
    }
}
