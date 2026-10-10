import SwiftUI
import OSLog

@main
struct ScrollLockApp: App {
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        if let index = arguments.firstIndex(of: "--scrolllock-disable-all-limits"), arguments.indices.contains(index + 1) {
            do { try ScrollLockEnforcement.disableAllLimits(requestID: arguments[index + 1]) }
            catch { Logger(subsystem: "com.example.scrolllock", category: "Settings").error("Could not turn off limits: \(error.localizedDescription, privacy: .private)") }
            return
        }
        #endif
        guard let index = arguments.firstIndex(of: "--scrolllock-kill-switch"), arguments.indices.contains(index + 1) else { return }
        do { try ScrollLockEnforcement.recover(requestID: arguments[index + 1]) }
        catch { Logger(subsystem: "com.example.scrolllock", category: "Recovery").error("Recovery failed: \(error.localizedDescription, privacy: .private)") }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
