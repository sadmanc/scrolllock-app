import DeviceActivity
import Foundation
import OSLog
import ManagedSettings

final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let logger = Logger(subsystem: "com.example.scrolllock.ScrollLockMonitor", category: "DeviceActivity")

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if activity == ScrollLockEnforcement.activity {
            _ = update { state in
                state.rollDay()
                guard state.monitoring, !state.emergency else { return false }
                state.record("Daily monitor window active. Existing daily, hourly, and per-session locks for today preserved.")
                try ScrollLockEnforcement.applyShields(state)
                return false
            }
        }
        if let info = scheduledActivityInfo(activity) {
            _ = update { state in
                state.rollDay()
                guard let schedule = state.schedules.first(where: { $0.id == info.scheduleID }), schedule.enabled else { return false }
                state.record("\(schedule.name): scheduled window started for \(ScrollLockState.weekdayName(info.weekday)).")
                try ScrollLockEnforcement.applyShields(state)
                return false
            }
            try? ScrollLockEnforcement.syncWindowMonitors()
            return
        }
        let scheduledPrefix = "ScrollLockScheduled-"
        if activity.rawValue.hasPrefix(scheduledPrefix) {
            let id = String(activity.rawValue.dropFirst(scheduledPrefix.count))
            _ = update { state in
                state.rollDay()
                guard let preset = state.presets.first(where: { $0.id == id }), preset.scheduleEnabled else { return false }
                state.scheduledLocked.insert(id)
                state.record("\(preset.name): scheduled restriction started for \(ScrollLockState.weekdayName(preset.scheduleWeekday)) \(ScrollLockState.clockText(preset.scheduleStartMinute)) to \(ScrollLockState.clockText(preset.scheduleEndMinute)).")
                try ScrollLockEnforcement.applyShields(state)
                return false
            }
        }
        let scheduleSessionPrefix = "ScrollLockScheduleSession-"
        if activity.rawValue.hasPrefix(scheduleSessionPrefix) {
            _ = update { state in
                state.rollDay()
                try ScrollLockEnforcement.applyShields(state)
                return false
            }
            return
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if activity == ScrollLockEnforcement.activity {
            _ = update { state in
                state.rollDay()
                try ScrollLockEnforcement.applyShields(state)
                state.record("Daily monitor window ended. Daily locks remain until the next local day.")
                return false
            }
            return
        }

        if let info = scheduledActivityInfo(activity) {
            _ = update { state in
                state.rollDay()
                guard let schedule = state.schedules.first(where: { $0.id == info.scheduleID }) else { return false }
                state.record("\(schedule.name): scheduled window ended for \(ScrollLockState.weekdayName(info.weekday)).")
                try ScrollLockEnforcement.applyShields(state)
                return false
            }
            try? ScrollLockEnforcement.syncWindowMonitors()
            return
        }

        let scheduledPrefix = "ScrollLockScheduled-"
        if activity.rawValue.hasPrefix(scheduledPrefix) {
            let id = String(activity.rawValue.dropFirst(scheduledPrefix.count))
            _ = update { state in
                state.rollDay()
                guard let preset = state.presets.first(where: { $0.id == id }) else { return false }
                state.scheduledLocked.remove(id)
                state.record("\(preset.name): scheduled restriction ended. The app is available again until the next scheduled block.")
                try ScrollLockEnforcement.applyShields(state)
                return false
            }
            return
        }

        let scheduleSessionPrefix = "ScrollLockScheduleSession-"
        if activity.rawValue.hasPrefix(scheduleSessionPrefix) {
            let shouldSync = update { state in
                let now = Date()
                if let info = scheduledSessionActivityInfo(activity),
                   let value = state.scheduleUsage[ScrollLockState.scheduleKey(scheduleID: info.scheduleID, appID: info.appID)],
                   value.sessionActiveSince != nil,
                   value.sessionResetAt.map({ $0 <= now }) == true {
                    _ = state.reachedSchedule(
                        scheduleID: info.scheduleID,
                        appID: info.appID,
                        rule: "session",
                        generation: state.generation,
                        now: now
                    )
                }
                state.rollDay()
                try ScrollLockEnforcement.applyShields(state)
                return true
            }
            if shouldSync { try? ScrollLockEnforcement.syncWindowMonitors() }
            return
        }

        let raw = activity.rawValue
        let isSession = raw.hasPrefix("ScrollLockSession-")
        let isHourly = raw.hasPrefix("ScrollLockHourly-")
        guard isSession || isHourly else { return }
        let prefix = isSession ? "ScrollLockSession-" : "ScrollLockHourly-"
        let id = String(raw.dropFirst(prefix.count))
        let shouldSync = update { state in
            let now = Date()
            let before = state.usage[id]
            let sessionCooldownEnded = isSession && before?.sessionCooldownUntil.map { $0 <= now } == true
            let sessionWindowEnded = isSession && before?.sessionResetAt.map { $0 <= now } == true
            let currentHour = Calendar.current.dateInterval(of: .hour, for: now)?.start
            let hourlyReset = isHourly && before?.hourlyBucket != nil && before?.hourlyBucket != currentHour
            state.rollDay()
            guard let preset = state.presets.first(where: { $0.id == id }) else { return false }
            if isSession {
                if sessionWindowEnded && before?.sessionActiveSince != nil {
                    _ = state.reachedWindow(id: id, generation: state.generation, rule: "session", now: now)
                } else if sessionCooldownEnded {
                    state.usage[id]?.resetSessionBudget()
                    if var usage = state.usage[id], preset.sessionEnabled {
                        usage.sessionWindowStarted = now
                        usage.sessionResetAt = now.addingTimeInterval(TimeInterval(preset.sessionMinutes * 60))
                        state.usage[id] = usage
                    }
                    state.record("\(preset.name): cooldown ended. Its per-session allowance is available again.")
                } else if sessionWindowEnded {
                    state.usage[id]?.resetSessionBudget()
                    if var usage = state.usage[id], preset.sessionEnabled {
                        usage.sessionWindowStarted = now
                        usage.sessionResetAt = now.addingTimeInterval(TimeInterval(preset.sessionMinutes * 60))
                        state.usage[id] = usage
                    }
                    state.record("\(preset.name): session reset window ended. Its allowance reset for a new session.")
                }
            } else {
                if hourlyReset {
                    state.record("\(preset.name): hourly window ended. Hourly allowance reset for the new local hour.")
                }
            }
            try ScrollLockEnforcement.applyShields(state)
            return true
        }
        if shouldSync { try? ScrollLockEnforcement.syncWindowMonitors(for: id) }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        let parts = event.rawValue.split(separator: ":")
        if parts.first == "scheduleSession", parts.count == 5 {
            let generation = String(parts[1])
            let scheduleID = String(parts[2])
            let weekday = Int(parts[3]) ?? 0
            let appID = String(parts[4])
            guard activity == ScrollLockEnforcement.scheduleSessionActivity(scheduleID: scheduleID, weekday: weekday, appID: appID) else { return }
            let accepted = update { state in
                guard state.reachedSchedule(scheduleID: scheduleID, appID: appID, rule: "session", generation: generation) else { return false }
                try ScrollLockEnforcement.applyShields(state)
                return true
            }
            if accepted { try? ScrollLockEnforcement.syncWindowMonitors() }
            return
        }
        if parts.first == "schedule", parts.count == 6 {
            let generation = String(parts[1])
            let scheduleID = String(parts[2])
            let weekday = Int(parts[3]) ?? 0
            let rule = String(parts[4])
            let appID = String(parts[5])
            guard activity == ScrollLockEnforcement.scheduledActivity(scheduleID: scheduleID, weekday: weekday) else { return }
            let accepted = update { state in
                guard state.reachedSchedule(scheduleID: scheduleID, appID: appID, rule: rule, generation: generation) else { return false }
                try ScrollLockEnforcement.applyShields(state)
                return true
            }
            if accepted { try? ScrollLockEnforcement.syncWindowMonitors() }
            return
        }
        guard parts.count == 3 else { return }
        let rule = String(parts[0])
        guard rule == "daily" || rule == "session" || rule == "hourly" else { return }
        let generation = String(parts[1])
        let id = String(parts[2])
        if rule == "daily" && activity != ScrollLockEnforcement.activity { return }
        if rule == "session" && activity != ScrollLockEnforcement.sessionActivity(id) { return }
        if rule == "hourly" && activity != ScrollLockEnforcement.hourlyActivity(id) { return }

        let shouldSync = update { state in
            let accepted: Bool
            if rule == "daily" {
                accepted = state.reached(id: id, generation: generation)
            } else {
                accepted = state.reachedWindow(id: id, generation: generation, rule: rule)
            }
            guard accepted else { return false }
            try ScrollLockEnforcement.applyShields(state)
            return rule != "daily"
        }
        if shouldSync { try? ScrollLockEnforcement.syncWindowMonitors(for: id) }
    }

    private func scheduledActivityInfo(_ activity: DeviceActivityName) -> (scheduleID: String, weekday: Int)? {
        let prefix = "ScrollLockSchedule-"
        guard activity.rawValue.hasPrefix(prefix) else { return nil }
        let value = String(activity.rawValue.dropFirst(prefix.count))
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let weekday = Int(parts[1]) else { return nil }
        return (parts[0], weekday)
    }

    private func scheduledSessionActivityInfo(_ activity: DeviceActivityName) -> (scheduleID: String, weekday: Int, appID: String)? {
        let prefix = "ScrollLockScheduleSession-"
        guard activity.rawValue.hasPrefix(prefix) else { return nil }
        let value = String(activity.rawValue.dropFirst(prefix.count))
        let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let weekday = Int(parts[1]) else { return nil }
        return (parts[0], weekday, parts[2])
    }

    @discardableResult
    private func update(_ body: (inout ScrollLockState) throws -> Bool) -> Bool {
        do {
            return try ScrollLockStorage.transaction { state in
                if try ScrollLockEnforcement.recoveryIsPaused() {
                    ScrollLockEnforcement.settings.clearAllSettings()
                    return false
                }
                return try body(&state)
            }
        } catch {
            logger.error("ScrollLock callback failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
