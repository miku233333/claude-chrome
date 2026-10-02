import AppKit
import Darwin
import Foundation
import Network
import Security

private let appName = "Claude Chrome"
private let applicationURL = Bundle.main.bundleURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let chromeBinary = applicationURL
    .appendingPathComponent("Contents/MacOS/Google Chrome").path
private let guardBinary = applicationURL
    .appendingPathComponent("Contents/Helpers/Claude Chrome Guard.app/Contents/MacOS/Claude Chrome Guard").path
private let defaultProxyURL = "http://127.0.0.1:17897"
private let defaultTargetURL = "https://claude.ai"
private let oauthTargetPaths = [
    "claude.com": "/cai/oauth/authorize",
    "platform.claude.com": "/oauth/authorize",
]
private let oauthRequiredQueryItems: Set<String> = [
    "client_id", "code", "code_challenge", "code_challenge_method",
    "redirect_uri", "response_type", "scope", "state",
]
private let oauthOptionalQueryItems: Set<String> = ["login_hint", "login_method", "orgUUID"]

final class AppDelegate: NSObject {
    private lazy var profileURL = resolveProfileURL()
    private lazy var proxyURL = resolveProxyURL()
    private var launchPending = false
    private var browserProcess: Process?
    private var browserTimeZone: String?
    private var browserLanguages: [String]?
    fileprivate var keepRunning = true

    func start() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let targetURL: String
        let external: Bool
        if arguments.isEmpty {
            targetURL = defaultTargetURL
            external = false
        } else if arguments.count == 2,
                  arguments[0] == "--login-url",
                  (validOAuthURL(arguments[1]) || DesktopLoginURL.isValid(arguments[1])) {
            targetURL = arguments[1]
            external = false
        } else if arguments.count == 2,
                  arguments[0] == "--external-url",
                  ExternalURL.isValid(arguments[1]) {
            targetURL = arguments[1]
            external = true
        } else {
            showError("登入網址無法確認。")
            return
        }
        openLoginBrowser(targetURL: targetURL, external: external)
    }

    private func openLoginBrowser(targetURL: String, external: Bool) {
        guard !launchPending else { return }
        guard FileManager.default.isExecutableFile(atPath: chromeBinary) else {
            showError("找不到內置瀏覽器核心，請重新建置 Claude Chrome。")
            return
        }
        guard let profileURL, let proxyURL else { return }

        guard proxyIsListening(proxyURL) else {
            showError("本機代理 \(proxyURL) 未啟動。請先啟動代理並確認能連外，再重新開啟 Claude Chrome。")
            return
        }
        guard let startPage = Bundle(url: applicationURL)?.url(forResource: "Start", withExtension: "html") else {
            showError("找不到環境檢查頁。")
            return
        }

        launchPending = true
        DispatchQueue.global(qos: .userInitiated).async {
            let assessment = ExitAssessment.lookup(proxyURL: proxyURL, profileURL: profileURL)
            DispatchQueue.main.async {
                self.launchPending = false
                guard let assessment, let encodedAssessment = assessment.encodedPageData else {
                    self.showError("無法取得出口 IP 與時區。請確認本機代理能連外，稍後重新開啟 Claude Chrome。")
                    return
                }
                let timeZone = assessment.timeZone
                var page = URLComponents(url: startPage, resolvingAgainstBaseURL: false)!
                var parameters = URLComponents()
                parameters.queryItems = [
                    URLQueryItem(name: "timezone", value: timeZone.identifier),
                    URLQueryItem(name: "assessment", value: encodedAssessment),
                    URLQueryItem(name: "target", value: targetURL),
                    URLQueryItem(name: "external", value: external ? "1" : "0"),
                ]
                page.percentEncodedFragment = parameters.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                guard let pageURL = page.url else {
                    self.showError("無法建立環境檢查頁網址。")
                    return
                }
                let languages = assessment.languages
                let arguments = self.browserArguments(profileURL: profileURL, proxyURL: proxyURL, pageURL: pageURL, language: languages[0])
                guard let mode = self.profileLaunchMode(
                    profileURL,
                    expectedArguments: arguments,
                    homepageURL: pageURL,
                    timeZone: timeZone,
                    languages: languages
                ) else { return }
                self.launchBrowser(arguments: arguments, timeZone: timeZone, languages: languages, mode: mode)
            }
        }
    }

    private enum BrowserLaunchMode {
        case cold
        case reuse
    }

    private func launchBrowser(arguments: [String], timeZone: TimeZone, languages: [String], mode: BrowserLaunchMode) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: chromeBinary)
        process.arguments = mode == .reuse
            ? arguments.filter { $0 != "--new-window" }
            : arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TZ"] = timeZone.identifier
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if mode == .cold {
            process.terminationHandler = { [weak self] terminatedProcess in
                DispatchQueue.main.async {
                    guard let self, self.browserProcess === terminatedProcess else { return }
                    self.browserProcess = nil
                    self.browserTimeZone = nil
                    self.browserLanguages = nil
                    self.keepRunning = false
                }
            }
        }

        do {
            try process.run()
            if mode == .cold {
                browserProcess = process
                browserTimeZone = timeZone.identifier
                browserLanguages = languages
            } else {
                keepRunning = false
            }
        } catch {
            showError("登入瀏覽器暫時無法開啟。")
        }
    }

    private func browserArguments(profileURL: URL, proxyURL: String, pageURL: URL, language: String) -> [String] {
        [
            "--user-data-dir=\(profileURL.path)",
            "--proxy-server=\(proxyURL)",
            "--webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--disable-sync",
            "--lang=\(language)",
            "--no-first-run",
            "--no-default-browser-check",
            "--new-window",
            pageURL.absoluteString,
        ]
    }

    private func resolveProxyURL() -> String? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude Chrome/config.json")
        var status = stat()
        if Darwin.lstat(configURL.path, &status) != 0 {
            if errno == ENOENT { return defaultProxyURL }
            showError("代理設定無法確認。")
            return nil
        }

        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size > 0,
              status.st_size <= 4_096,
              let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary.keys.count == 1,
              let value = dictionary["proxyURL"] as? String,
              validProxyURL(value)
        else {
            showError("代理設定格式不正確。請檢查 ~/Library/Application Support/Claude Chrome/config.json 的 proxyURL 是否為本機 HTTP 代理及連接埠。")
            return nil
        }
        return value
    }

    private func validProxyURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "http" || components.scheme == "https",
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1",
              let port = components.port,
              (1...65_535).contains(port),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else { return false }
        return true
    }

    private func validOAuthURL(_ value: String) -> Bool {
        guard value.utf8.count <= 8_192,
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              let expectedPath = oauthTargetPaths[host],
              components.percentEncodedPath == expectedPath,
              let items = components.queryItems
        else { return false }

        var values: [String: [String]] = [:]
        for item in items {
            guard let value = item.value else { return false }
            values[item.name, default: []].append(value)
        }
        let names = Set(values.keys)
        guard oauthRequiredQueryItems.isSubset(of: names),
              names.isSubset(of: oauthRequiredQueryItems.union(oauthOptionalQueryItems)),
              values.values.allSatisfy({ $0.count == 1 }),
              values["code"] == ["true"],
              values["response_type"] == ["code"],
              values["code_challenge_method"] == ["S256"],
              let clientID = values["client_id"]?.first,
              UUID(uuidString: clientID) != nil,
              let challenge = values["code_challenge"]?.first,
              challenge.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
              let state = values["state"]?.first,
              state.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
              let scope = values["scope"]?.first,
              !scope.isEmpty,
              scope.utf8.count <= 2_048,
              let redirect = values["redirect_uri"]?.first,
              validOAuthRedirect(redirect)
        else { return false }

        return oauthOptionalQueryItems.allSatisfy { name in
            guard let value = values[name]?.first else { return true }
            return !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    private func validOAuthRedirect(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "http",
              components.host?.lowercased() == "localhost",
              let port = components.port,
              (1...65_535).contains(port),
              components.user == nil,
              components.password == nil,
              components.percentEncodedPath == "/callback",
              components.query == nil,
              components.fragment == nil
        else { return false }
        return true
    }

    private func resolveProfileURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = home.appendingPathComponent(".local/share/claude-network-guard/chrome-login-profile", isDirectory: true)
        let preferred = home.appendingPathComponent("Library/Application Support/Claude Chrome/Profile", isDirectory: true)

        switch pathState(at: legacy.path) {
        case .present:
            return validateProfileDirectory(legacy) ? legacy : nil
        case .error:
            showError("登入瀏覽器資料夾無法確認。")
            return nil
        case .missing:
            break
        }

        switch pathState(at: preferred.path) {
        case .present:
            return validateProfileDirectory(preferred) ? preferred : nil
        case .error:
            showError("登入瀏覽器資料夾無法確認。")
            return nil
        case .missing:
            do {
                try FileManager.default.createDirectory(
                    at: preferred,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: preferred.path)
            } catch {
                showError("無法建立登入瀏覽器資料夾。")
                return nil
            }
            return validateProfileDirectory(preferred) ? preferred : nil
        }
    }

    private enum PathState {
        case missing
        case present
        case error
    }

    private func pathState(at path: String) -> PathState {
        var status = stat()
        if Darwin.lstat(path, &status) == 0 { return .present }
        return errno == ENOENT ? .missing : .error
    }

    private func validateProfileDirectory(_ url: URL) -> Bool {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              (status.st_mode & 0o777) == 0o700
        else {
            showError("登入瀏覽器資料夾權限不正確。")
            return false
        }
        return true
    }

    private func profileLaunchMode(
        _ profileURL: URL,
        expectedArguments: [String],
        homepageURL: URL,
        timeZone: TimeZone,
        languages: [String]
    ) -> BrowserLaunchMode? {
        let lockPath = profileURL.appendingPathComponent("SingletonLock").path
        var fileStatus = stat()
        if Darwin.lstat(lockPath, &fileStatus) != 0 {
            if errno == ENOENT {
                guard browserProcess?.isRunning != true else {
                    showError("Claude Chrome 正在啟動，請稍後重試。")
                    return nil
                }
                return configureProfile(profileURL, languages: languages) ? .cold : nil
            }
            showError("登入瀏覽器狀態無法確認。")
            return nil
        }

        guard (fileStatus.st_mode & S_IFMT) == S_IFLNK,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lockPath),
              let pid = trailingPID(in: target)
        else {
            showError("登入瀏覽器正由其他啟動方式使用。")
            return nil
        }

        guard processIsAlive(pid) else {
            guard browserProcess?.isRunning != true else {
                showError("Claude Chrome 的啟動狀態無法確認，請完全結束後重試。")
                return nil
            }
            return configureProfile(profileURL, languages: languages) ? .cold : nil
        }
        let requiredArguments = Array(expectedArguments.dropLast())
        guard let expectedHomepage = expectedArguments.last,
              expectedHomepage == homepageURL.absoluteString,
              let invocation = processInvocation(for: pid)
        else {
            showError("Claude Chrome 的瀏覽器設定無法確認。")
            return nil
        }
        let positionalArguments = invocation.arguments.dropFirst().filter { !$0.hasPrefix("--") }
        let launchedByThisGuard = browserProcess?.isRunning == true &&
            browserProcess?.processIdentifier == pid &&
            browserTimeZone == timeZone.identifier &&
            browserLanguages == languages
        let launchedByInstalledGuard = managedGuardIsParent(of: pid) &&
            profileLanguagesMatch(profileURL, languages: languages)
        guard launchedByThisGuard || launchedByInstalledGuard,
              invocation.executable == chromeBinary,
              invocation.arguments.first == chromeBinary,
              requiredArguments.allSatisfy({ expected in
                  invocation.arguments.filter({ $0 == expected }).count == 1
              }),
              invocation.arguments.filter({ $0.hasPrefix("--app") }).isEmpty,
              positionalArguments.count == 1,
              let actualHomepage = positionalArguments.first,
              sameStartPageBase(actualHomepage, homepageURL.absoluteString),
              startPageTimeZoneMatches(actualHomepage, timeZone: timeZone),
              invocation.arguments.dropFirst().allSatisfy({ argument in
                  let isGuarded = argument.hasPrefix("--proxy-") ||
                      argument.hasPrefix("--no-proxy-server") ||
                      argument.hasPrefix("--user-data-dir") ||
                      argument.hasPrefix("--webrtc-ip-handling-policy") ||
                      argument.hasPrefix("--app") ||
                      argument.hasPrefix("--new-window") ||
                      argument.hasPrefix("--lang") ||
                      argument.hasPrefix("--disable-sync")
                  if !argument.hasPrefix("--") {
                      return sameStartPageBase(argument, homepageURL.absoluteString)
                  }
                  return !isGuarded || requiredArguments.contains(argument)
              })
        else {
            showError("請先完全結束 Claude Chrome 的瀏覽器，再重新開啟以套用出口時區、語言及設定。")
            return nil
        }

        return .reuse
    }

    private func startPageTimeZoneMatches(_ value: String, timeZone: TimeZone) -> Bool {
        guard let fragment = URLComponents(string: value)?.percentEncodedFragment else { return false }
        var parameters = URLComponents()
        parameters.percentEncodedQuery = fragment
        let timeZones = parameters.queryItems?.filter { $0.name == "timezone" } ?? []
        return timeZones.count == 1 && timeZones[0].value == timeZone.identifier
    }

    private func sameStartPageBase(_ actual: String, _ expected: String) -> Bool {
        guard var actualComponents = URLComponents(string: actual),
              var expectedComponents = URLComponents(string: expected),
              actualComponents.scheme == "file",
              expectedComponents.scheme == "file"
        else { return false }
        actualComponents.fragment = nil
        expectedComponents.fragment = nil
        return actualComponents.url?.standardizedFileURL == expectedComponents.url?.standardizedFileURL
    }

    private func configureProfile(_ profileURL: URL, languages: [String]) -> Bool {
        let directory = profileURL.appendingPathComponent("Default", isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("Preferences")
        do {
            if pathState(at: directory.path) == .missing {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard validateProfileDirectory(directory) else { return false }
            var preferences: [String: Any] = [:]
            var originalData: Data?
            if pathState(at: preferencesURL.path) != .missing {
                var status = stat()
                guard Darwin.lstat(preferencesURL.path, &status) == 0,
                      (status.st_mode & S_IFMT) == S_IFREG,
                      status.st_size <= 4_194_304
                else { throw CocoaError(.fileReadNoPermission) }
                let data = try Data(contentsOf: preferencesURL)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                preferences = object
                originalData = data
            }
            var updated = preferences
            var signin = updated["signin"] as? [String: Any] ?? [:]
            signin["allowed"] = false
            signin["allowed_on_next_startup"] = false
            updated["signin"] = signin
            var omnibox = updated["omnibox"] as? [String: Any] ?? [:]
            omnibox["show_ai_mode_omnibox_button"] = false
            updated["omnibox"] = omnibox
            var international = updated["intl"] as? [String: Any] ?? [:]
            international["accept_languages"] = languages.joined(separator: ",")
            international["selected_languages"] = languages.joined(separator: ",")
            updated["intl"] = international
            var promo = updated["sync_promo"] as? [String: Any] ?? [:]
            promo["show_on_first_run_allowed"] = false
            promo["show_ntp_bubble"] = false
            updated["sync_promo"] = promo
            if NSDictionary(dictionary: preferences).isEqual(to: updated) { return true }
            if let originalData {
                let backup = profileURL.appendingPathComponent("Claude Chrome Preferences.latest-backup")
                if pathState(at: backup.path) != .missing {
                    var status = stat()
                    guard Darwin.lstat(backup.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                }
                try originalData.write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            let data = try JSONSerialization.data(withJSONObject: updated, options: .sortedKeys)
            try data.write(to: preferencesURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
            return true
        } catch {
            showError("無法更新 Claude Chrome 的語言及登入設定。")
            return false
        }
    }

    private func proxyIsListening(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased(),
              let portValue = components.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portValue))
        else { return false }

        let hosts: [NWEndpoint.Host]
        if host == "localhost" {
            hosts = ["127.0.0.1", "::1"]
        } else {
            hosts = [NWEndpoint.Host(host)]
        }
        let timeout: DispatchTimeInterval = hosts.count == 1 ? .milliseconds(900) : .milliseconds(450)
        return hosts.contains { canConnect(to: $0, port: port, timeout: timeout) }
    }

    private func canConnect(
        to host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        timeout: DispatchTimeInterval
    ) -> Bool {
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var connected = false
        var completed = false

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                lock.lock()
                connected = true
                let shouldSignal = !completed
                completed = true
                lock.unlock()
                if shouldSignal { semaphore.signal() }
            case .failed, .cancelled:
                lock.lock()
                let shouldSignal = !completed
                completed = true
                lock.unlock()
                if shouldSignal { semaphore.signal() }
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "local.claudechrome.proxy-check"))
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()

        lock.lock()
        let result = connected
        lock.unlock()
        return result
    }

    private func trailingPID(in value: String) -> pid_t? {
        let digits = value.reversed().prefix { $0.isNumber }.reversed()
        guard !digits.isEmpty, let number = Int32(String(digits)), number > 0 else { return nil }
        return number
    }

    private func processIsAlive(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func managedGuardIsParent(of browserPID: pid_t) -> Bool {
        guard let browserBefore = processIdentity(for: browserPID),
              browserBefore.parentPID > 1,
              let guardBefore = processIdentity(for: browserBefore.parentPID),
              processExecutablePath(for: guardBefore.pid) == URL(fileURLWithPath: guardBinary).resolvingSymlinksInPath().path,
              runningCodeMatchesCurrentGuard(guardBefore.pid),
              processIdentity(for: guardBefore.pid) == guardBefore,
              processIdentity(for: browserPID) == browserBefore
        else { return false }
        return true
    }

    private struct ProcessIdentity: Equatable {
        let pid: pid_t
        let parentPID: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private func processIdentity(for pid: pid_t) -> ProcessIdentity? {
        var information = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, expectedSize) == expectedSize,
              information.pbi_pid == UInt32(pid)
        else { return nil }
        return ProcessIdentity(
            pid: pid,
            parentPID: pid_t(information.pbi_ppid),
            startSeconds: information.pbi_start_tvsec,
            startMicroseconds: information.pbi_start_tvusec
        )
    }

    private func processExecutablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    private func runningCodeMatchesCurrentGuard(_ pid: pid_t) -> Bool {
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: pid] as CFDictionary,
            [],
            &guestCode
        ) == errSecSuccess,
            let guestCode,
            SecCodeCheckValidity(guestCode, [], nil) == errSecSuccess
        else { return false }

        var runningStaticCode: SecStaticCode?
        var installedStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guestCode, [], &runningStaticCode) == errSecSuccess,
              let runningStaticCode,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: guardBinary) as CFURL, [], &installedStaticCode) == errSecSuccess,
              let installedStaticCode,
              SecStaticCodeCheckValidity(installedStaticCode, [], nil) == errSecSuccess,
              let runningHash = codeHash(for: runningStaticCode),
              let installedHash = codeHash(for: installedStaticCode)
        else { return false }
        return runningHash == installedHash
    }

    private func codeHash(for code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [CFString: Any]
        else { return nil }
        return values[kSecCodeInfoUnique] as? Data
    }

    private func profileLanguagesMatch(_ profileURL: URL, languages: [String]) -> Bool {
        let preferencesURL = profileURL.appendingPathComponent("Default/Preferences")
        var status = stat()
        guard Darwin.lstat(preferencesURL.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size > 0,
              status.st_size <= 4_194_304,
              let data = try? Data(contentsOf: preferencesURL),
              let preferences = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let international = preferences["intl"] as? [String: Any]
        else { return false }
        let expected = languages.joined(separator: ",")
        return international["accept_languages"] as? String == expected &&
            international["selected_languages"] as? String == expected
    }

    private func processInvocation(for pid: pid_t) -> (executable: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var byteCount = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &byteCount, nil, 0) == 0,
              byteCount > MemoryLayout<Int32>.size,
              byteCount <= 1_048_576
        else { return nil }

        var buffer = [UInt8](repeating: 0, count: byteCount)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &byteCount, nil, 0) == 0 else {
            return nil
        }

        let argumentCount = buffer.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: Int32.self)
        }
        guard argumentCount > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        let executableStart = index
        while index < byteCount, buffer[index] != 0 { index += 1 }
        guard index < byteCount,
              let executable = String(bytes: buffer[executableStart..<index], encoding: .utf8)
        else { return nil }
        while index < byteCount, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        for _ in 0..<Int(argumentCount) {
            guard index < byteCount else { return nil }
            let start = index
            while index < byteCount, buffer[index] != 0 { index += 1 }
            guard index < byteCount,
                  let argument = String(bytes: buffer[start..<index], encoding: .utf8)
            else { return nil }
            arguments.append(argument)
            index += 1
        }

        return (executable, arguments)
    }

    private func showError(_ message: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "無法開啟 \(appName)"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
        keepRunning = false
    }
}

@main
enum Launcher {
    static func main() {
        let launcher = AppDelegate()
        launcher.start()
        while launcher.keepRunning {
            if !RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
