import AppKit
import Darwin
import Foundation
import Network

private let appName = "Claude Chrome"
private let chromeBinary = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
private let defaultProxyURL = "http://127.0.0.1:17897"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var profileURL = resolveProfileURL()
    private lazy var proxyURL = resolveProxyURL()
    private var launchPending = false
    private var browserProcess: Process?
    private var browserTimeZone: String?
    private var browserLanguages: [String]?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        openLoginBrowser()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openLoginBrowser()
        return false
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        sender.reply(toOpenOrPrint: .failure)
    }

    func application(_ application: NSApplication, open urls: [URL]) {}

    func applicationWillTerminate(_ notification: Notification) {
        if let browserProcess, browserProcess.isRunning {
            browserProcess.terminate()
        }
    }

    private func configureMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(
            withTitle: "結束 \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func openLoginBrowser() {
        guard !launchPending else { return }
        guard FileManager.default.isExecutableFile(atPath: chromeBinary) else {
            showError("找不到 Google Chrome。")
            return
        }
        guard let profileURL, let proxyURL else { return }

        guard proxyIsListening(proxyURL) else {
            showError("本機代理未啟動。")
            return
        }
        guard let startPage = Bundle.main.url(forResource: "Start", withExtension: "html") else {
            showError("找不到環境檢查頁。")
            return
        }

        launchPending = true
        DispatchQueue.global(qos: .userInitiated).async {
            let assessment = ExitAssessment.lookup(proxyURL: proxyURL, profileURL: profileURL)
            DispatchQueue.main.async {
                self.launchPending = false
                guard let assessment, let encodedAssessment = assessment.encodedPageData else {
                    self.showError("無法確認出口 IP 的時區，請檢查本機代理後重試。")
                    return
                }
                let timeZone = assessment.timeZone
                var page = URLComponents(url: startPage, resolvingAgainstBaseURL: false)!
                var parameters = URLComponents()
                parameters.queryItems = [
                    URLQueryItem(name: "timezone", value: timeZone.identifier),
                    URLQueryItem(name: "assessment", value: encodedAssessment),
                ]
                page.percentEncodedFragment = parameters.percentEncodedQuery
                guard let pageURL = page.url else { return }
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
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TZ"] = timeZone.identifier
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            if mode == .cold {
                browserProcess = process
                browserTimeZone = timeZone.identifier
                browserLanguages = languages
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
            showError("代理設定格式不正確。")
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
        guard let browserProcess,
              browserProcess.isRunning,
              browserProcess.processIdentifier == pid,
              browserTimeZone == timeZone.identifier,
              browserLanguages == languages,
              invocation.executable == chromeBinary,
              invocation.arguments.first == chromeBinary,
              requiredArguments.allSatisfy({ expected in
                  invocation.arguments.filter({ $0 == expected }).count == 1
              }),
              invocation.arguments.filter({ $0.hasPrefix("--app") }).isEmpty,
              positionalArguments.count == 1,
              let actualHomepage = positionalArguments.first,
              sameStartPageBase(actualHomepage, homepageURL.absoluteString),
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "無法開啟 \(appName)"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

@main
enum Launcher {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
