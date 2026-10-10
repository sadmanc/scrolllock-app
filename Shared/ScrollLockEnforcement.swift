import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

enum ScrollLockEnforcement {
    static let activity = DeviceActivityName("ScrollLockDaily")
    static let settings = ManagedSettingsStore(named: .init("ScrollLock"))
    private static let minimumWindowInterval = TimeInterval(ScrollLockLimits.minimumDeviceActivityWindowMinutes * 60)

    private struct WindowPlan {
        var activity: DeviceActivityName
        var schedule: DeviceActivitySchedule
        var event: DeviceActivityEvent.Name?
        var threshold: Int?
        var token: ApplicationToken
        var includesPastActivity: Bool
    }

    private struct SchedulePlan {
        var activity: DeviceActivityName
        var schedule: DeviceActivitySchedule
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    }

    static func sessionActivity(_ id: String) -> DeviceActivityName {
        DeviceActivityName("ScrollLockSession-\(id)")
    }

    static func hourlyActivity(_ id: String) -> DeviceActivityName {
        DeviceActivityName("ScrollLockHourly-\(id)")
    }

    static func scheduledActivity(_ id: String) -> DeviceActivityName {
        DeviceActivityName("ScrollLockScheduled-\(id)")
    }

    static func scheduledActivity(scheduleID: String, weekday: Int) -> DeviceActivityName {
        DeviceActivityName("ScrollLockSchedule-\(scheduleID)|\(weekday)")
    }

    static func scheduleSessionActivity(scheduleID: String, weekday: Int, appID: String) -> DeviceActivityName {
        DeviceActivityName("ScrollLockScheduleSession-\(scheduleID)|\(weekday)|\(appID)")
    }

    static func recoveryMarker() throws -> URL {
        try ScrollLockStorage.container().appendingPathComponent("scrolllock-recovery-paused")
    }

    static func recoveryIsPaused() throws -> Bool {
        FileManager.default.fileExists(atPath: try recoveryMarker().path)
    }

    static func token(_ preset: AppPreset) throws -> ApplicationToken {
        try JSONDecoder().decode(ApplicationToken.self, from: preset.token)
    }

    static func activities(for presets: [AppPreset]) -> Set<DeviceActivityName> {
        var result: Set<DeviceActivityName> = [activity]
        for preset in presets {
            result.insert(sessionActivity(preset.id))
            result.insert(hourlyActivity(preset.id))
            result.insert(scheduledActivity(preset.id))
        }
        return result
    }

    static func activities(for schedules: [ScrollLockSchedule]) -> Set<DeviceActivityName> {
        Set(schedules.flatMap { schedule in
            schedule.weekdays.flatMap { weekday in
                [scheduledActivity(scheduleID: schedule.id, weekday: weekday)] + schedule.rules
                    .map { scheduleSessionActivity(scheduleID: schedule.id, weekday: weekday, appID: $0.appID) }
            }
        })
    }

    static func activities(for state: ScrollLockState) -> Set<DeviceActivityName> {
        activities(for: state.presets).union(activities(for: state.schedules))
    }

    static func applyShields(_ state: ScrollLockState) throws {
        if try recoveryIsPaused() {
            settings.clearAllSettings()
            return
        }
        guard state.migrated else { return }
        // ManagedSettings can stop removal of apps while the user's lock is active.
        // This is intentionally cleared whenever the lock is off or recovery is active.
        settings.application.denyAppRemoval = state.settingsLock.enabled && !state.emergency
        let scheduledAppIDs = Set(state.schedules.flatMap { $0.rules.map(\.appID) })
        var tokens = try Set(state.presets.filter {
            state.isLocked($0.id) && ($0.enabled || $0.sessionEnabled || $0.hourlyEnabled || $0.scheduleEnabled || scheduledAppIDs.contains($0.id))
        }.map(token))
        for rule in state.schedules.flatMap(\.rules) where state.scheduledLocked.contains(rule.appID) {
            if let data = state.token(for: rule), let appToken = try? JSONDecoder().decode(ApplicationToken.self, from: data) {
                tokens.insert(appToken)
            }
        }
        settings.shield.applications = state.emergency || tokens.isEmpty ? nil : tokens
    }

    static func events(_ state: ScrollLockState) throws -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        var result: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for preset in state.presets where preset.enabled {
            let name = DeviceActivityEvent.Name("daily:\(state.generation):\(preset.id)")
            result[name] = DeviceActivityEvent(
                applications: [try token(preset)],
                threshold: DateComponents(minute: preset.minutes),
                includesPastActivity: true
            )
        }
        return result
    }

    private static func dateComponents(_ date: Date, calendar: Calendar) -> DateComponents {
        calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: date
        )
    }

    private static func dailySchedule() -> DeviceActivitySchedule {
        DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true
        )
    }

    private static func windowPlan(
        _ preset: AppPreset,
        state: ScrollLockState,
        rule: String,
        now: Date,
        calendar: Calendar
    ) throws -> WindowPlan? {
        let usage = state.usage[preset.id] ?? UsageState(day: calendar.startOfDay(for: now))
        let windowActivity = rule == "session" ? sessionActivity(preset.id) : hourlyActivity(preset.id)
        let requestedStart = now.addingTimeInterval(1)
        let end: Date
        let remaining: TimeInterval
        let locked: Bool

        if rule == "session" {
            guard preset.sessionEnabled, usage.sessionActiveSince != nil, let resetAt = usage.sessionResetAt else { return nil }
            end = resetAt
            remaining = Double(preset.sessionMinutes * 60) - usage.sessionUsed(at: now)
            locked = usage.sessionLocked
        } else {
            guard preset.hourlyEnabled else { return nil }
            let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            end = calendar.date(byAdding: .hour, value: 1, to: currentHour) ?? now.addingTimeInterval(3600)
            remaining = Double(preset.hourlyMinutes * 60) - usage.hourlyUsed(at: now, calendar: calendar)
            locked = usage.hourlyLocked
        }

        guard end > requestedStart else { return nil }
        // Device Activity rejects intervals shorter than 15 minutes. Keep the
        // start in the future and extend only the monitor interval. Shared
        // state still uses the real reset or cooldown deadline, so the
        // interval-end callback reconciles the window as soon as iOS delivers it.
        // DateComponents are truncated to whole seconds. Since the interval
        // starts at now + 1 second, add a small margin so the encoded interval
        // cannot fall just under Device Activity's 15-minute minimum.
        let monitorEnd = max(end, now.addingTimeInterval(minimumWindowInterval + 2))
        let event: DeviceActivityEvent.Name?
        let threshold: Int?
        if locked || remaining <= 0 {
            event = nil
            threshold = nil
        } else {
            event = DeviceActivityEvent.Name("\(rule):\(state.generation):\(preset.id)")
            threshold = max(1, Int(ceil(remaining / 60)))
        }
        let schedule = DeviceActivitySchedule(
            intervalStart: dateComponents(requestedStart, calendar: calendar),
            intervalEnd: dateComponents(monitorEnd, calendar: calendar),
            repeats: false
        )
        return WindowPlan(
            activity: windowActivity,
            schedule: schedule,
            event: event,
            threshold: threshold,
            token: try token(preset),
            includesPastActivity: rule != "session"
        )
    }

    private static func scheduledPlan(_ schedule: ScrollLockSchedule, state: ScrollLockState, weekday: Int, calendar: Calendar) throws -> SchedulePlan {
        let start = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            hour: schedule.startMinute / 60,
            minute: schedule.startMinute % 60,
            second: 0,
            weekday: weekday
        )
        let end = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            hour: schedule.endMinute / 60,
            minute: schedule.endMinute % 60,
            second: 0,
            weekday: weekday
        )
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for rule in schedule.rules where !rule.block {
            guard let data = state.token(for: rule),
                  let appToken = try? JSONDecoder().decode(ApplicationToken.self, from: data) else { continue }
            let rules: [(String, Bool, Int)] = [
                ("total", rule.totalEnabled, rule.totalMinutes),
                ("hourly", rule.hourlyEnabled, rule.hourlyMinutes)
            ]
            for (kind, enabled, minutes) in rules where enabled {
                let name = DeviceActivityEvent.Name("schedule:\(state.generation):\(schedule.id):\(weekday):\(kind):\(rule.appID)")
                events[name] = DeviceActivityEvent(
                    applications: [appToken],
                    threshold: DateComponents(minute: minutes),
                    includesPastActivity: false
                )
            }
        }
        return SchedulePlan(
            activity: scheduledActivity(scheduleID: schedule.id, weekday: weekday),
            schedule: DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true),
            events: events
        )
    }

    private static func scheduleSessionPlan(
        _ schedule: ScrollLockSchedule,
        rule: ScheduleAppRule,
        state: ScrollLockState,
        weekday: Int,
        now: Date,
        calendar: Calendar
    ) throws -> WindowPlan? {
        guard rule.sessionEnabled,
              calendar.component(.weekday, from: now) == weekday,
              let interval = state.activeInterval(for: schedule, now: now, calendar: calendar),
              let data = state.token(for: rule),
              let appToken = try? JSONDecoder().decode(ApplicationToken.self, from: data) else { return nil }
        let key = ScrollLockState.scheduleKey(scheduleID: schedule.id, appID: rule.appID)
        let usage = state.scheduleUsage[key] ?? ScheduleUsageState()
        guard usage.sessionActiveSince != nil else { return nil }
        let actualEnd: Date
        let event: DeviceActivityEvent.Name?
        let threshold: Int?
        actualEnd = usage.sessionResetAt ?? min(interval.end, now.addingTimeInterval(TimeInterval(rule.sessionMinutes * 60)))
        let remaining = Double(rule.sessionMinutes * 60) - usage.sessionUsed(at: now)
        if usage.sessionLocked || remaining <= 0 {
            event = nil
            threshold = nil
        } else {
            event = DeviceActivityEvent.Name("scheduleSession:\(state.generation):\(schedule.id):\(weekday):\(rule.appID)")
            threshold = max(1, Int(ceil(remaining / 60)))
        }
        let requestedStart = now.addingTimeInterval(1)
        guard actualEnd > requestedStart else { return nil }
        let monitorEnd = max(actualEnd, now.addingTimeInterval(minimumWindowInterval + 2))
        return WindowPlan(
            activity: scheduleSessionActivity(scheduleID: schedule.id, weekday: weekday, appID: rule.appID),
            schedule: DeviceActivitySchedule(
                intervalStart: dateComponents(requestedStart, calendar: calendar),
                intervalEnd: dateComponents(monitorEnd, calendar: calendar),
                repeats: false
            ),
            event: event,
            threshold: threshold,
            token: appToken,
            includesPastActivity: false
        )
    }

    private static func syncPlans(_ plans: [WindowPlan], schedulePlans: [SchedulePlan], known: Set<DeviceActivityName>) throws {
        let center = DeviceActivityCenter()
        let wanted = Set(plans.map(\.activity)).union(schedulePlans.map(\.activity))
        let stale = known.subtracting(wanted).subtracting([activity])
        if !stale.isEmpty { center.stopMonitoring(Array(stale)) }
        for plan in plans {
            if let event = plan.event, let threshold = plan.threshold {
                let configured = DeviceActivityEvent(
                    applications: [plan.token],
                    threshold: DateComponents(minute: threshold),
                    includesPastActivity: plan.includesPastActivity
                )
                try center.startMonitoring(
                    plan.activity,
                    during: plan.schedule,
                    events: [event: configured]
                )
            } else {
                // Keep a schedule with no threshold event so intervalDidEnd can
                // release an exhaustion cooldown or reconcile a reset window.
                try center.startMonitoring(
                    plan.activity,
                    during: plan.schedule,
                    events: [:]
                )
            }
        }
        for plan in schedulePlans {
            try center.startMonitoring(plan.activity, during: plan.schedule, events: plan.events)
        }
    }

    static func syncWindowMonitors(for id: String? = nil) throws {
        let plansAndState: ([WindowPlan], [SchedulePlan], ScrollLockState) = try ScrollLockStorage.transaction { state in
            let now = Date()
            state.rollDay(now: now, calendar: .current)
            for preset in state.presets {
                guard let usage = state.usage[preset.id] else {
                    guard preset.sessionEnabled || preset.hourlyEnabled else { continue }
                    var created = UsageState(day: Calendar.current.startOfDay(for: now))
                    created.rollDay(now: now, calendar: .current)
                    state.usage[preset.id] = created
                    continue
                }
                state.usage[preset.id] = usage
            }
            let selected = state.presets
            let plans = try selected.flatMap { preset in
                try [
                    windowPlan(preset, state: state, rule: "session", now: now, calendar: .current),
                    windowPlan(preset, state: state, rule: "hourly", now: now, calendar: .current)
                ].compactMap { $0 }
            }
            let schedulePlans = try state.schedules.filter(\.enabled).flatMap { schedule in
                try schedule.weekdays.map { try scheduledPlan(schedule, state: state, weekday: $0, calendar: .current) }
            }
            let scheduleSessionPlans = try state.schedules.flatMap { schedule in
                try schedule.rules.flatMap { rule in
                    try schedule.weekdays.compactMap {
                        try scheduleSessionPlan(schedule, rule: rule, state: state, weekday: $0, now: now, calendar: .current)
                    }
                }
            }
            return (plans + scheduleSessionPlans, schedulePlans, state)
        }
        // Device Activity callbacks can synchronously need this same file lock.
        // Never start or stop a monitor while ScrollLockStorage is locked.
        let known: Set<DeviceActivityName>
        known = activities(for: plansAndState.2)
        try syncPlans(plansAndState.0, schedulePlans: plansAndState.1, known: known)
    }

    static func syncSessionMonitors(tokenKey: String) throws {
        let plansAndState: ([WindowPlan], ScrollLockState) = try ScrollLockStorage.transaction { state in
            let now = Date()
            state.rollDay(now: now, calendar: .current)
            let presetPlans = try state.presets
                .filter { ScrollLockState.shortcutKey(for: $0.token) == tokenKey }
                .compactMap { preset in
                    try windowPlan(preset, state: state, rule: "session", now: now, calendar: .current)
                }
            let schedulePlans = try state.schedules.flatMap { schedule in
                try schedule.rules
                    .filter { state.token(for: $0).map(ScrollLockState.shortcutKey(for:)) == tokenKey }
                    .flatMap { rule in
                        try schedule.weekdays.compactMap {
                            try scheduleSessionPlan(schedule, rule: rule, state: state, weekday: $0, now: now, calendar: .current)
                        }
                    }
            }
            return (presetPlans + schedulePlans, state)
        }

        var known = Set<DeviceActivityName>()
        for preset in plansAndState.1.presets where ScrollLockState.shortcutKey(for: preset.token) == tokenKey {
            known.insert(sessionActivity(preset.id))
        }
        for schedule in plansAndState.1.schedules {
            for rule in schedule.rules where plansAndState.1.token(for: rule).map(ScrollLockState.shortcutKey(for:)) == tokenKey {
                for weekday in schedule.weekdays {
                    known.insert(scheduleSessionActivity(scheduleID: schedule.id, weekday: weekday, appID: rule.appID))
                }
            }
        }
        try syncPlans(plansAndState.0, schedulePlans: [], known: known)
    }

    static func configure(_ proposed: [AppPreset], schedules: [ScrollLockSchedule] = []) throws {
        let authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        let hasAuthorization: Bool
        if #available(iOS 26.4, *) {
            hasAuthorization = authorizationStatus == .approved || authorizationStatus == .approvedWithDataAccess
        } else {
            hasAuthorization = authorizationStatus == .approved
        }
        let wasPaused = try recoveryIsPaused()
        let oldState = (try? ScrollLockStorage.transaction { $0 }) ?? ScrollLockState()
        let prepared = try ScrollLockStorage.transaction {
            state -> (generation: String, monitoring: Bool, events: [DeviceActivityEvent.Name: DeviceActivityEvent]) in
            if wasPaused && !state.emergency { state.recover() }
            state.rollDay()
            try state.validate(proposed)
            try state.validateSchedules(schedules, apps: proposed)
            var next = state
            next.presets = proposed
            next.schedules = schedules
            for preset in proposed {
                guard var usage = next.usage[preset.id],
                      let previous = state.presets.first(where: { $0.id == preset.id }) else { continue }
                if !preset.sessionEnabled ||
                    previous.sessionEnabled != preset.sessionEnabled ||
                    previous.sessionMinutes != preset.sessionMinutes ||
                    (usage.sessionResetAt == nil && usage.sessionCooldownUntil == nil && !usage.sessionLocked) {
                    usage.resetSessionBudget()
                    next.usage[preset.id] = usage
                }
            }
            next.emergency = false
            next.generation = UUID().uuidString
            next.reconcileScheduledLocks()
            next.reconcileSchedules()
            let hasRules = proposed.contains { $0.enabled || $0.sessionEnabled || $0.hourlyEnabled || $0.scheduleEnabled } || schedules.contains { $0.enabled && !$0.rules.isEmpty }
            // Keep the user's configuration even before Screen Time access is
            // granted. Only registration with Device Activity is deferred.
            next.monitoring = hasAuthorization && hasRules
            let dailyEvents = try events(next)
            next.record("Applying settings: " + proposed.map {
                let daily = $0.enabled ? "daily \($0.minutes)m" : "daily off"
                let session = $0.sessionEnabled ? "session \($0.sessionMinutes)m/cooldown \($0.cooldownMinutes)m" : "session off"
                let hourly = $0.hourlyEnabled ? "hourly \($0.hourlyMinutes)m" : "hourly off"
                let scheduled = $0.scheduleEnabled
                    ? "scheduled \(ScrollLockState.weekdayName($0.scheduleWeekday)) \(ScrollLockState.clockText($0.scheduleStartMinute))-\(ScrollLockState.clockText($0.scheduleEndMinute))"
                    : "scheduled off"
                return "\($0.name): \(daily), \(session), \(hourly), \(scheduled)"
            }.joined(separator: "; ") + ".")
            state = next
            return (next.generation, next.monitoring, dailyEvents)
        }

        do {
            let center = DeviceActivityCenter()
            center.stopMonitoring(Array(activities(for: oldState)))
            if prepared.monitoring {
                try center.startMonitoring(activity, during: dailySchedule(), events: prepared.events)
            } else {
                center.stopMonitoring([activity])
            }
            try ScrollLockStorage.transaction { state in
                guard state.generation == prepared.generation else { return }
                if hasAuthorization {
                    state.record("Settings applied: selected app rules registered. Daily resets at local midnight; hourly resets at the local hour; per-session cooldowns keep unused allowance until they expire.")
                } else {
                    state.record("Settings saved, but Screen Time access is required before limits can be registered.")
                }
                if wasPaused, FileManager.default.fileExists(atPath: try recoveryMarker().path) {
                    try FileManager.default.removeItem(at: recoveryMarker())
                }
                try applyShields(state)
            }
            if hasAuthorization {
                try syncWindowMonitors()
            }
        } catch {
            try? ScrollLockStorage.transaction { state in
                guard state.generation == prepared.generation else { return }
                state.monitoring = false
                state.record("Settings failed: \(error.localizedDescription)")
                try applyShields(state)
            }
            if wasPaused {
                try? Data("Recovery remains paused after failed configuration".utf8).write(to: recoveryMarker(), options: .atomic)
                DeviceActivityCenter().stopMonitoring(Array(activities(for: oldState)))
                settings.clearAllSettings()
            }
            throw error
        }
    }

    static func refresh() throws -> ScrollLockState {
        if try recoveryIsPaused() { settings.clearAllSettings() }
        return try ScrollLockStorage.transaction { state in
            if try recoveryIsPaused(), !state.emergency { state.recover() }
            state.rollDay()
            try applyShields(state)
            return state
        }
    }

    #if DEBUG
    // Explicit Mac maintenance action, never an automatic launch migration.
    static func disableAllLimits(requestID: String) throws {
        let known = try ScrollLockStorage.transaction { state in
            let known = activities(for: state)
            state.disableAllLimits()
            state.record("All existing limits turned off at your request. Request: " + requestID)
            return known
        }
        DeviceActivityCenter().stopMonitoring(Array(known))
        try ScrollLockStorage.transaction { try applyShields($0) }
    }
    #endif

    static func recover(requestID: String) throws {
        try Data(requestID.utf8).write(to: recoveryMarker(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let known = (try? ScrollLockStorage.transaction { activities(for: $0) }) ?? [activity]
        DeviceActivityCenter().stopMonitoring(Array(known))
        settings.clearAllSettings()
        var persistenceWarning: String?
        do {
            try ScrollLockStorage.transaction { state in
                state.recover()
                try applyShields(state)
            }
        } catch { persistenceWarning = error.localizedDescription }
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var receipt = ["requestID": requestID, "status": "cleared", "timestamp": ISO8601DateFormatter().string(from: Date())]
        receipt["persistenceWarning"] = persistenceWarning
        try JSONEncoder().encode(receipt).write(to: documents.appendingPathComponent("scrolllock-recovery.json"), options: .atomic)
    }
}
