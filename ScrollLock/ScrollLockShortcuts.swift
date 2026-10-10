import AppIntents
import Foundation

struct ScrollLockShortcutApp: AppEntity, Hashable, Sendable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "App")
    static var defaultQuery = ScrollLockShortcutAppQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct ScrollLockShortcutAppQuery: EntityStringQuery, EnumerableEntityQuery {
    func entities(for identifiers: [ScrollLockShortcutApp.ID]) async throws -> [ScrollLockShortcutApp] {
        let available = try availableApps()
        return identifiers.compactMap { id in available.first(where: { $0.id == id }) }
    }

    func suggestedEntities() async throws -> [ScrollLockShortcutApp] {
        try availableApps()
    }

    func allEntities() async throws -> [ScrollLockShortcutApp] {
        try availableApps()
    }

    func entities(matching string: String) async throws -> [ScrollLockShortcutApp] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return try availableApps().filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
        }
    }

    private func availableApps() throws -> [ScrollLockShortcutApp] {
        // Read the shared file on every request; never retain an old app list.
        try ScrollLockStorage.transaction { state in
            state.shortcutApps.map { ScrollLockShortcutApp(id: $0.id, name: $0.name) }
        }
    }

}

struct StartScrollLockSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start App Session"
    static var description = IntentDescription("Start timing the selected app's per-session allowance.")
    static var openAppWhenRun = false

    @Parameter(title: "App")
    var application: ScrollLockShortcutApp

    func perform() async throws -> some IntentResult {
        try ScrollLockShortcutBridge.start(tokenKey: application.id)
        return .result()
    }
}

struct EndScrollLockSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "End App Session"
    static var description = IntentDescription("Stop timing the selected app and apply its per-session allowance.")
    static var openAppWhenRun = false

    @Parameter(title: "App")
    var application: ScrollLockShortcutApp

    func perform() async throws -> some IntentResult {
        try ScrollLockShortcutBridge.end(tokenKey: application.id)
        return .result()
    }
}

private enum ScrollLockShortcutBridge {
    static func start(tokenKey: String) throws {
        try update(tokenKey: tokenKey) { state in
            _ = state.shortcutDidStart(tokenKey: tokenKey)
        }
        syncSessionMonitors(tokenKey: tokenKey, action: "Start App Session")
    }

    static func end(tokenKey: String) throws {
        try update(tokenKey: tokenKey) { state in
            _ = state.shortcutDidEnd(tokenKey: tokenKey)
        }
        syncSessionMonitors(tokenKey: tokenKey, action: "End App Session")
    }

    private static func syncSessionMonitors(tokenKey: String, action: String) {
        do {
            try ScrollLockEnforcement.syncSessionMonitors(tokenKey: tokenKey)
        } catch {
            let nsError = error as NSError
            let detail = "\(action) safety-monitor sync failed: \(nsError.domain) (\(nsError.code)): \(error.localizedDescription)"
            try? ScrollLockStorage.transaction { state in
                state.record("Session timing was saved, but its Screen Time safety monitor could not be updated. Open ScrollLock to review status.")
                state.recordDebug(event: "shortcut-monitor-sync-error", details: detail)
            }
        }
    }

    private static func update(tokenKey: String, _ body: (inout ScrollLockState) throws -> Void) throws {
        try ScrollLockStorage.transaction { state in
            // Shortcuts can retain a previously selected entity after removal.
            // Check membership again inside the same transaction as the action.
            guard state.containsShortcutApp(tokenKey) else {
                throw ScrollLockError.message("This app is no longer selected in ScrollLock. Choose an app currently in Limits or Schedules, or delete this automation.")
            }
            try body(&state)
            try ScrollLockEnforcement.applyShields(state)
        }
    }
}
