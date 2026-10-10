import Foundation
import FamilyControls
import DeviceActivity
import ManagedSettings

enum ScrollLockMigration {
    static func run() throws {
        try ScrollLockStorage.transaction { state in
            guard !state.migrated else { return }
            let defaults = UserDefaults(suiteName: "group.com.example.scrolllock")!
            if let data = defaults.data(forKey: "statusHistory") {
                state.history = try JSONDecoder().decode([StatusHistoryEntry].self, from: data)
            }
            if let data = defaults.data(forKey: "selectedActivity") {
                let selection = try JSONDecoder().decode(FamilyActivitySelection.self, from: data)
                let limits = try defaults.data(forKey: "dailyLimits").map { try JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
                let oldUsage = try defaults.data(forKey: "usageState").map { try JSONDecoder().decode([String: LegacyUsage].self, from: $0) } ?? [:]
                let oldLocks = ScrollLockEnforcement.settings.shield.applications ?? []
                for (index, token) in selection.applicationTokens.enumerated() {
                    let name = Application(token: token).localizedDisplayName ?? "App \(index + 1)"
                    var preset = AppPreset(token: try JSONEncoder().encode(token), name: name, enabled: true)
                    if state.presets.contains(where: { ScrollLockState.normalized($0.name) == ScrollLockState.normalized(name) }) { preset.name += " \(index + 1)" }
                    preset.minutes = min(1440, max(1, limits[name] ?? 1))
                    state.presets.append(preset)
                    if oldLocks.contains(token) { state.locked.insert(preset.id) }
                    if let old = oldUsage[name], let day = TimeInterval(old.dayKey) {
                        state.usage[preset.id] = UsageState(day: Date(timeIntervalSince1970: day), seconds: old.totalSeconds)
                    }
                }
            }
            state.migrated = true
            state.record("Shared storage upgraded. Apply settings to register daily, hourly, and per-session monitors; existing shields and history were preserved.")
        }

        // The migration is committed before old copies are removed. These
        // values are no longer needed once the structured shared state exists.
        if let defaults = UserDefaults(suiteName: "group.com.example.scrolllock") {
            ["statusHistory", "selectedActivity", "dailyLimits", "usageState", "screenTimeAppNames"]
                .forEach(defaults.removeObject(forKey:))
        }
    }

    private struct LegacyUsage: Codable {
        let dayKey: String
        var totalSeconds: TimeInterval
        var activeSince: Date?
    }
}
