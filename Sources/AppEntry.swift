import AppKit
import Foundation

@main
enum AppEntry {
    static func main() {
        let guardExecutable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/Claude Chrome Guard.app/Contents/MacOS/Claude Chrome Guard")
        let process = Process()
        process.executableURL = guardExecutable
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "無法開啟 Claude Chrome"
            alert.informativeText = "請重新建置並安裝 Claude Chrome。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}
