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
        guard FileManager.default.isExecutableFile(atPath: chromeBinary) else {
            showError("找不到 Google Chrome。")
            return
        }
        guard let profileURL, let proxyURL else { return }

        let arguments = browserArguments(profileURL: profileURL, proxyURL: proxyURL)
        guard proxyIsListening(proxyURL) else {
            showError("本機代理未啟動。")
            return
        }
        guard mayUseProfile(profileURL, expectedArguments: arguments) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: chromeBinary)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            showError("登入瀏覽器暫時無法開啟。")
        }
    }

    private func browserArguments(profileURL: URL, proxyURL: String) -> [String] {
        [
            "--user-data-dir=\(profileURL.path)",
            "--proxy-server=\(proxyURL)",
            "--webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--no-first-run",
            "--no-default-browser-check",
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

    private func mayUseProfile(_ profileURL: URL, expectedArguments: [String]) -> Bool {
        let lockPath = profileURL.appendingPathComponent("SingletonLock").path
        var fileStatus = stat()
        if Darwin.lstat(lockPath, &fileStatus) != 0 {
            if errno == ENOENT { return true }
            showError("登入瀏覽器狀態無法確認。")
            return false
        }

        guard (fileStatus.st_mode & S_IFMT) == S_IFLNK,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lockPath),
              let pid = trailingPID(in: target)
        else {
            showError("登入瀏覽器正由其他啟動方式使用。")
            return false
        }

        guard processIsAlive(pid) else { return true }
        guard let invocation = processInvocation(for: pid),
              invocation.executable == chromeBinary,
              invocation.arguments.first == chromeBinary,
              expectedArguments.allSatisfy({ expected in
                  invocation.arguments.filter({ $0 == expected }).count == 1
              }),
              invocation.arguments.dropFirst().allSatisfy({ argument in
                  let isGuarded = argument.hasPrefix("--proxy-") ||
                      argument.hasPrefix("--no-proxy-server") ||
                      argument.hasPrefix("--user-data-dir") ||
                      argument.hasPrefix("--webrtc-ip-handling-policy")
                  return !isGuarded || expectedArguments.contains(argument)
              })
        else {
            showError("登入瀏覽器正由其他啟動方式使用。")
            return false
        }

        return true
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

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
