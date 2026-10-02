import AppKit
import Carbon
import Security

private let routerIdentifier = "local.claudechrome.login-router"
private let supportURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude Chrome")
private let configurationURL = supportURL.appendingPathComponent("login-router.json")
private let browserURL = URL(fileURLWithPath: "/Applications/Claude Chrome.app")

private struct RouterConfiguration: Codable {
    let fallback: [String: String]
    let signingFingerprint: String
}

private func configuration() throws -> RouterConfiguration {
    let value = try JSONDecoder().decode(RouterConfiguration.self, from: Data(contentsOf: configurationURL))
    guard Set(value.fallback.keys) == Set(["http", "https"]),
          value.fallback.values.allSatisfy({ !$0.isEmpty && $0 != routerIdentifier && $0 != "local.claudechrome.launcher" }),
          value.signingFingerprint.range(of: #"^[A-Fa-f0-9]{40}$"#, options: .regularExpression) != nil
    else { throw NSError(domain: "ClaudeLoginRouter", code: 1) }
    return value
}

private func handler(_ scheme: String) -> String? {
    guard let url = URL(string: "\(scheme)://example.com/"),
          let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
    return Bundle(url: app)?.bundleIdentifier
}

private func route(_ url: URL, sourceIdentifier: String? = nil) -> String {
    if DesktopLoginURL.isValid(url.absoluteString) { return "claude-chrome" }
    if DesktopLoginURL.matchesEndpoint(url.absoluteString) { return "reject" }
    let host = url.host?.lowercased() ?? ""
    let claudeDomain = ["claude.ai", "claude.com", "anthropic.com"].contains {
        host == $0 || host.hasSuffix("." + $0)
    }
    let claudeSource = sourceIdentifier == "com.anthropic.claudefordesktop" ||
        sourceIdentifier?.hasPrefix("com.anthropic.claudefordesktop.") == true
    if claudeDomain || claudeSource {
        return ExternalURL.isValid(url.absoluteString) ? "claude-external" : "reject"
    }
    return url.scheme == "http" || url.scheme == "https" ? "fallback" : "reject"
}

private func verifyBrowser(_ fingerprint: String) -> Bool {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let rule = "identifier \"local.claudechrome.launcher\" and certificate leaf = H\"\(fingerprint)\""
    guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
          SecStaticCodeCreateWithPath(browserURL as CFURL, [], &code) == errSecSuccess,
          let code, let requirement,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess,
          let startScript = try? String(contentsOf: browserURL.appendingPathComponent("Contents/Resources/Start.js"), encoding: .utf8),
          startScript.contains("function isDesktopLoginURL(") else { return false }
    return true
}

final class LoginRouterDelegate: NSObject, NSApplicationDelegate {
    private var pending = 0
    private var receivedURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishWhenIdle()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURL = true
        let event = NSAppleEventManager.shared().currentAppleEvent
        let sourcePID = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        let sourceIdentifier = sourcePID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        for url in urls {
            do {
                let settings = try configuration()
                let options = NSWorkspace.OpenConfiguration()
                let destination = route(url, sourceIdentifier: sourceIdentifier)
                let readback = ["source": sourceIdentifier ?? "unknown", "route": destination]
                if let data = try? JSONEncoder().encode(readback) {
                    let receipt = supportURL.appendingPathComponent("last-route.json")
                    try? data.write(to: receipt, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
                }
                switch destination {
                case "claude-chrome", "claude-external":
                    guard verifyBrowser(settings.signingFingerprint) else {
                        showError("Claude Chrome 的簽章或桌面登入支援無法確認。請重新安裝已驗證版本。")
                        continue
                    }
                    options.createsNewApplicationInstance = true
                    options.arguments = [destination == "claude-chrome" ? "--login-url" : "--external-url", url.absoluteString]
                    pending += 1
                    NSWorkspace.shared.openApplication(at: browserURL, configuration: options) { [weak self] _, error in
                        self?.completed(error)
                    }
                case "fallback":
                    guard let scheme = url.scheme, let identifier = settings.fallback[scheme],
                          let fallback = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                    else {
                        showError("原本的瀏覽器無法開啟。請確認它仍然安裝在本機。")
                        continue
                    }
                    pending += 1
                    NSWorkspace.shared.open([url], withApplicationAt: fallback, configuration: options) { [weak self] _, error in
                        self?.completed(error)
                    }
                default:
                    showError("登入網址無法確認；已停止轉接。")
                }
            } catch {
                showError("登入轉接設定無法讀取。請重新啟用或還原轉接器。")
            }
        }
        finishWhenIdle()
    }

    private func completed(_ error: Error?) {
        DispatchQueue.main.async {
            self.pending -= 1
            if error != nil { self.showError("目標瀏覽器無法開啟，未改用其他出口。") }
            self.finishWhenIdle()
        }
    }

    private func finishWhenIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + (receivedURL ? 1 : 3)) {
            if self.pending == 0 { NSApplication.shared.terminate(nil) }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Claude 登入轉接"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

@main
enum LoginRouter {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--inspect"] {
            let handlers = ["http": handler("http") ?? "", "https": handler("https") ?? ""]
            print(String(data: try JSONEncoder().encode(handlers), encoding: .utf8)!)
            return
        }
        if (arguments.count == 2 || arguments.count == 4), arguments[0] == "--route", let url = URL(string: arguments[1]),
           arguments.count == 2 || arguments[2] == "--source" {
            print(route(url, sourceIdentifier: arguments.count == 4 ? arguments[3] : nil))
            return
        }
        if arguments == ["--enable"] || arguments == ["--disable"] {
            try configureDefaults(enable: arguments == ["--enable"])
            return
        }
        guard arguments.isEmpty else { throw NSError(domain: "ClaudeLoginRouter", code: 2) }
        let application = NSApplication.shared
        let delegate = LoginRouterDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
    }

    private static func configureDefaults(enable: Bool) throws {
        let settings: RouterConfiguration
        if enable {
            if handler("http") == routerIdentifier || handler("https") == routerIdentifier {
                settings = try configuration()
            } else {
                guard let http = handler("http"), let https = handler("https"),
                      http != "local.claudechrome.launcher", https != "local.claudechrome.launcher" else {
                    throw NSError(domain: "ClaudeLoginRouter", code: 3)
                }
                let fingerprint = try String(contentsOf: supportURL.appendingPathComponent("signing-identity.txt"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard fingerprint.range(of: #"^[A-Fa-f0-9]{40}$"#, options: .regularExpression) != nil else {
                    throw NSError(domain: "ClaudeLoginRouter", code: 4)
                }
                settings = RouterConfiguration(fallback: ["http": http, "https": https], signingFingerprint: fingerprint)
            }
            guard verifyBrowser(settings.signingFingerprint), Bundle.main.bundleIdentifier == routerIdentifier else {
                throw NSError(domain: "ClaudeLoginRouter", code: 5)
            }
            try JSONEncoder().encode(settings).write(to: configurationURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        } else {
            settings = try configuration()
        }
        var changed: [String] = []
        do {
            for scheme in ["http", "https"] {
                let target: URL
                let identifier: String
                if enable {
                    target = Bundle.main.bundleURL
                    identifier = routerIdentifier
                } else {
                    identifier = settings.fallback[scheme]!
                    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                        throw NSError(domain: "ClaudeLoginRouter", code: 6)
                    }
                    target = app
                }
                if handler(scheme) == identifier { continue }
                try setHandler(target, scheme: scheme)
                changed.append(scheme)
                guard handler(scheme) == identifier else { throw NSError(domain: "ClaudeLoginRouter", code: 7) }
            }
        } catch {
            if enable {
                for scheme in changed.reversed() {
                    if let original = settings.fallback[scheme],
                       let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: original) {
                        try? setHandler(app, scheme: scheme)
                    }
                }
            }
            throw error
        }
        print(enable ? "Claude 登入自動轉接已啟用；其他連結使用原本瀏覽器。" : "已還原原本瀏覽器。")
    }

    private static func setHandler(_ app: URL, scheme: String) throws {
        var completed = false
        var failure: Error?
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
            failure = error
            completed = true
        }
        let deadline = Date(timeIntervalSinceNow: 90)
        while !completed, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        guard completed else { throw NSError(domain: "ClaudeLoginRouter", code: 8) }
        if let failure { throw failure }
    }
}
