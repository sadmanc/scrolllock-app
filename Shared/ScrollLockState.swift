import Foundation
import Darwin

enum ScrollLockLimits {
    static let minimumDeviceActivityWindowMinutes = 15
    static let minimumSessionLimitMinutes = 1
}

// One catalog drives suggestions, search, identifier lookup, and execution checks.
// An app remains available while selected anywhere, even with its limits off.
struct ShortcutAppOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct StatusHistoryEntry: Codable, Identifiable {
    var id = UUID()
    var timestamp = Date()
    var message: String
}

#if DEBUG
struct DebugTraceEntry: Codable, Identifiable {
    var id = UUID()
    var timestamp = Date()
    var event: String
    var appID: String?
    var appName: String?
    var details: String

    init(
        event: String,
        appID: String? = nil,
        appName: String? = nil,
        details: String,
        timestamp: Date = Date()
    ) {
        self.timestamp = timestamp
        self.event = event
        self.appID = appID
        self.appName = appName
        self.details = details
    }
}
#endif

struct AppPreset: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var token: Data
    var name: String
    var shortcutAlias: String?
    var enabled = false
    var minutes = 10
    var sessionEnabled = false
    var sessionMinutes = ScrollLockLimits.minimumSessionLimitMinutes
    var cooldownMinutes = 20
    var hourlyEnabled = false
    var hourlyMinutes = 20
    var scheduleEnabled = false
    var scheduleWeekday = 4
    var scheduleStartMinute = 9 * 60
    var scheduleEndMinute = 12 * 60

    private enum CodingKeys: String, CodingKey {
        case id, token, name, shortcutAlias, enabled, minutes, sessionEnabled, sessionMinutes
        case cooldownMinutes, hourlyEnabled, hourlyMinutes, scheduleEnabled
        case scheduleWeekday, scheduleStartMinute, scheduleEndMinute
    }

    init(id: String = UUID().uuidString, token: Data, name: String, shortcutAlias: String? = nil, enabled: Bool = false,
         minutes: Int = 10, sessionEnabled: Bool = false, sessionMinutes: Int = ScrollLockLimits.minimumSessionLimitMinutes,
         cooldownMinutes: Int = 20, hourlyEnabled: Bool = false, hourlyMinutes: Int = 20,
         scheduleEnabled: Bool = false, scheduleWeekday: Int = 4,
         scheduleStartMinute: Int = 9 * 60, scheduleEndMinute: Int = 12 * 60) {
        self.id = id
        self.token = token
        self.name = name
        self.shortcutAlias = shortcutAlias
        self.enabled = enabled
        self.minutes = minutes
        self.sessionEnabled = sessionEnabled
        self.sessionMinutes = sessionMinutes
        self.cooldownMinutes = cooldownMinutes
        self.hourlyEnabled = hourlyEnabled
        self.hourlyMinutes = hourlyMinutes
        self.scheduleEnabled = scheduleEnabled
        self.scheduleWeekday = scheduleWeekday
        self.scheduleStartMinute = scheduleStartMinute
        self.scheduleEndMinute = scheduleEndMinute
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        token = try values.decode(Data.self, forKey: .token)
        name = try values.decode(String.self, forKey: .name)
        shortcutAlias = try values.decodeIfPresent(String.self, forKey: .shortcutAlias)
        // Legacy saved presets were daily-enabled before this field existed.
        // Preserve those rules; only newly created presets default to off.
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        minutes = try values.decodeIfPresent(Int.self, forKey: .minutes) ?? 10
        sessionEnabled = try values.decodeIfPresent(Bool.self, forKey: .sessionEnabled) ?? false
        sessionMinutes = max(
            ScrollLockLimits.minimumSessionLimitMinutes,
            try values.decodeIfPresent(Int.self, forKey: .sessionMinutes) ?? ScrollLockLimits.minimumSessionLimitMinutes
        )
        let decodedCooldown = try values.decodeIfPresent(Int.self, forKey: .cooldownMinutes) ?? 20
        cooldownMinutes = max(ScrollLockLimits.minimumSessionLimitMinutes, decodedCooldown)
        hourlyEnabled = try values.decodeIfPresent(Bool.self, forKey: .hourlyEnabled) ?? false
        hourlyMinutes = try values.decodeIfPresent(Int.self, forKey: .hourlyMinutes) ?? 20
        scheduleEnabled = try values.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? false
        scheduleWeekday = try values.decodeIfPresent(Int.self, forKey: .scheduleWeekday) ?? 4
        scheduleStartMinute = try values.decodeIfPresent(Int.self, forKey: .scheduleStartMinute) ?? 9 * 60
        scheduleEndMinute = try values.decodeIfPresent(Int.self, forKey: .scheduleEndMinute) ?? 12 * 60
    }

    var shortcutName: String {
        let alias = shortcutAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
        return alias?.isEmpty == false ? alias! : name
    }
}

struct ScheduleAppRule: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var appID: String
    var token: Data?
    var name: String?
    var shortcutAlias: String?
    var block = false
    var totalEnabled = false
    var totalMinutes = 20
    var sessionEnabled = false
    var sessionMinutes = ScrollLockLimits.minimumSessionLimitMinutes
    var cooldownMinutes = 20
    var hourlyEnabled = false
    var hourlyMinutes = 10

    private enum CodingKeys: String, CodingKey {
        case id, appID, token, name, shortcutAlias, block, totalEnabled, totalMinutes
        case sessionEnabled, sessionMinutes, cooldownMinutes, hourlyEnabled, hourlyMinutes
    }

    init(id: String = UUID().uuidString, appID: String = UUID().uuidString, token: Data? = nil, name: String? = nil, shortcutAlias: String? = nil,
         block: Bool = false, totalEnabled: Bool = false, totalMinutes: Int = 20,
         sessionEnabled: Bool = false, sessionMinutes: Int = ScrollLockLimits.minimumSessionLimitMinutes,
         cooldownMinutes: Int = 20,
         hourlyEnabled: Bool = false, hourlyMinutes: Int = 10) {
        self.id = id
        self.appID = appID
        self.token = token
        self.name = name
        self.shortcutAlias = shortcutAlias
        self.block = block
        self.totalEnabled = totalEnabled
        self.totalMinutes = totalMinutes
        self.sessionEnabled = sessionEnabled
        self.sessionMinutes = sessionMinutes
        self.cooldownMinutes = cooldownMinutes
        self.hourlyEnabled = hourlyEnabled
        self.hourlyMinutes = hourlyMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        appID = try values.decode(String.self, forKey: .appID)
        token = try values.decodeIfPresent(Data.self, forKey: .token)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        shortcutAlias = try values.decodeIfPresent(String.self, forKey: .shortcutAlias)
        block = try values.decodeIfPresent(Bool.self, forKey: .block) ?? false
        totalEnabled = try values.decodeIfPresent(Bool.self, forKey: .totalEnabled) ?? false
        totalMinutes = try values.decodeIfPresent(Int.self, forKey: .totalMinutes) ?? 20
        sessionEnabled = try values.decodeIfPresent(Bool.self, forKey: .sessionEnabled) ?? false
        sessionMinutes = max(
            ScrollLockLimits.minimumSessionLimitMinutes,
            try values.decodeIfPresent(Int.self, forKey: .sessionMinutes) ?? ScrollLockLimits.minimumSessionLimitMinutes
        )
        cooldownMinutes = max(
            ScrollLockLimits.minimumSessionLimitMinutes,
            try values.decodeIfPresent(Int.self, forKey: .cooldownMinutes) ?? 20
        )
        hourlyEnabled = try values.decodeIfPresent(Bool.self, forKey: .hourlyEnabled) ?? false
        hourlyMinutes = try values.decodeIfPresent(Int.self, forKey: .hourlyMinutes) ?? 10
    }

    var shortcutName: String {
        let alias = shortcutAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
        return alias?.isEmpty == false ? alias! : (name ?? "Selected app")
    }
}

struct ScrollLockSchedule: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var enabled = true
    var weekdays: Set<Int> = Set(2...6)
    var startMinute = 9 * 60
    var endMinute = 15 * 60 + 30
    var rules: [ScheduleAppRule] = []
}

struct ScheduleUsageState: Codable {
    var intervalStart: Date?
    var intervalEnd: Date?
    var seconds: TimeInterval = 0
    var sessionSeconds: TimeInterval = 0
    var sessionActiveSince: Date?
    var sessionResetAt: Date?
    var sessionCooldownUntil: Date?
    var hourlyBucket: Date?
    var hourlySeconds: TimeInterval = 0
    var totalLocked = false
    var sessionLocked = false
    var hourlyLocked = false

    mutating func reset(for interval: DateInterval) {
        intervalStart = interval.start
        intervalEnd = interval.end
        seconds = 0
        sessionSeconds = 0
        sessionActiveSince = nil
        sessionResetAt = nil
        sessionCooldownUntil = nil
        hourlyBucket = nil
        hourlySeconds = 0
        totalLocked = false
        sessionLocked = false
        hourlyLocked = false
    }

    func used(at now: Date) -> TimeInterval {
        seconds
    }

    func sessionUsed(at now: Date) -> TimeInterval {
        sessionSeconds + max(0, sessionActiveSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    func hourlyUsed(at now: Date, calendar: Calendar) -> TimeInterval {
        return hourlySeconds
    }

    mutating func beginSession(now: Date, sessionMinutes: Int, intervalEnd: Date) {
        guard sessionActiveSince == nil else { return }
        sessionActiveSince = now
        if sessionResetAt == nil {
            sessionResetAt = min(intervalEnd, now.addingTimeInterval(TimeInterval(sessionMinutes * 60)))
        }
    }

    mutating func finishSession(now: Date, sessionMinutes: Int, cooldownMinutes: Int) -> Bool {
        guard let started = sessionActiveSince else { return false }
        sessionSeconds += max(0, now.timeIntervalSince(started))
        sessionActiveSince = nil
        guard sessionSeconds >= TimeInterval(sessionMinutes * 60) else { return false }
        sessionSeconds = TimeInterval(sessionMinutes * 60)
        sessionLocked = true
        sessionCooldownUntil = now.addingTimeInterval(TimeInterval(cooldownMinutes * 60))
        sessionResetAt = nil
        return true
    }
}

struct UsageState: Codable {
    var day: Date
    var seconds: TimeInterval = 0
    var hourlyBucket: Date?
    var hourlySeconds: TimeInterval = 0
    var sessionSeconds: TimeInterval = 0
    var sessionActiveSince: Date?
    var sessionWindowStarted: Date?
    var sessionResetAt: Date?
    var sessionCooldownUntil: Date?
    var hourlyLocked = false
    var sessionLocked = false

    private enum CodingKeys: String, CodingKey {
        case day, seconds, hourlyBucket
        case hourlySeconds, sessionSeconds, sessionActiveSince, sessionWindowStarted, sessionResetAt, sessionCooldownUntil
        case hourlyLocked, sessionLocked
    }

    init(day: Date, seconds: TimeInterval = 0, hourlyBucket: Date? = nil, hourlySeconds: TimeInterval = 0,
         sessionSeconds: TimeInterval = 0, sessionActiveSince: Date? = nil, sessionWindowStarted: Date? = nil,
         sessionResetAt: Date? = nil,
         sessionCooldownUntil: Date? = nil, hourlyLocked: Bool = false, sessionLocked: Bool = false) {
        self.day = day
        self.seconds = seconds
        self.hourlyBucket = hourlyBucket
        self.hourlySeconds = hourlySeconds
        self.sessionSeconds = sessionSeconds
        self.sessionActiveSince = sessionActiveSince
        self.sessionWindowStarted = sessionWindowStarted
        self.sessionResetAt = sessionResetAt
        self.sessionCooldownUntil = sessionCooldownUntil
        self.hourlyLocked = hourlyLocked
        self.sessionLocked = sessionLocked
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        day = try values.decode(Date.self, forKey: .day)
        seconds = try values.decodeIfPresent(TimeInterval.self, forKey: .seconds) ?? 0
        hourlyBucket = try values.decodeIfPresent(Date.self, forKey: .hourlyBucket)
        hourlySeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .hourlySeconds) ?? 0
        sessionSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .sessionSeconds) ?? 0
        sessionActiveSince = try values.decodeIfPresent(Date.self, forKey: .sessionActiveSince)
        sessionWindowStarted = try values.decodeIfPresent(Date.self, forKey: .sessionWindowStarted)
        sessionResetAt = try values.decodeIfPresent(Date.self, forKey: .sessionResetAt)
        sessionCooldownUntil = try values.decodeIfPresent(Date.self, forKey: .sessionCooldownUntil)
        hourlyLocked = try values.decodeIfPresent(Bool.self, forKey: .hourlyLocked) ?? false
        sessionLocked = try values.decodeIfPresent(Bool.self, forKey: .sessionLocked) ?? false
    }

    mutating func rollDay(now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        if day != today {
            day = today
            seconds = 0
        }
        rollHour(now: now, calendar: calendar)
    }

    func used(at now: Date) -> TimeInterval {
        seconds
    }

    func sessionUsed(at now: Date) -> TimeInterval {
        sessionSeconds + max(0, sessionActiveSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    func hourlyUsed(at now: Date, calendar: Calendar) -> TimeInterval {
        hourlySeconds
    }

    mutating func rollHour(now: Date, calendar: Calendar) {
        let start = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        guard hourlyBucket != start else { return }
        hourlyBucket = start
        hourlySeconds = 0
        hourlyLocked = false
    }

    mutating func resetSessionBudget() {
        sessionSeconds = 0
        sessionActiveSince = nil
        sessionWindowStarted = nil
        sessionResetAt = nil
        sessionCooldownUntil = nil
        sessionLocked = false
    }

    mutating func beginSession(now: Date, sessionMinutes: Int) {
        guard sessionActiveSince == nil else { return }
        sessionActiveSince = now
        if sessionResetAt == nil {
            sessionWindowStarted = now
            sessionResetAt = now.addingTimeInterval(TimeInterval(sessionMinutes * 60))
        }
    }

    mutating func finishSession(now: Date, sessionMinutes: Int, cooldownMinutes: Int) -> Bool {
        guard let started = sessionActiveSince else { return false }
        sessionSeconds += max(0, now.timeIntervalSince(started))
        sessionActiveSince = nil
        guard sessionSeconds >= TimeInterval(sessionMinutes * 60) else { return false }
        sessionSeconds = TimeInterval(sessionMinutes * 60)
        sessionLocked = true
        sessionCooldownUntil = now.addingTimeInterval(TimeInterval(cooldownMinutes * 60))
        sessionWindowStarted = nil
        sessionResetAt = nil
        return true
    }

    mutating func advanceSession(now: Date, sessionMinutes: Int, enabled: Bool) {
        guard enabled else {
            resetSessionBudget()
            return
        }

        // A live Start/End Shortcut session owns the budget until its End
        // action arrives. Background reconciliation must not reset it merely
        // because the hidden reset deadline passed while the app was open.
        guard sessionActiveSince == nil else { return }

        if let cooldown = sessionCooldownUntil, cooldown <= now {
            resetSessionBudget()
        }

        guard !sessionLocked, let resetAt = sessionResetAt, resetAt <= now else { return }
        resetSessionBudget()
    }
}

enum SettingsUnlockMode: String, Codable, CaseIterable {
    case countdown
    case scheduled
}

struct ShortcutSetupState: Codable, Equatable {
    var startSeenAt: Date?
    var endSeenAt: Date?

    var isReady: Bool { startSeenAt != nil && endSeenAt != nil }
}

struct SettingsLockState: Codable, Equatable {
    var enabled = false
    var mode: SettingsUnlockMode = .countdown
    var countdownMinutes = 5
    var unlockAt: Date?
}

struct ScrollLockState: Codable {
    var version = 1
    var presets: [AppPreset] = []
    var schedules: [ScrollLockSchedule] = []
    var usage: [String: UsageState] = [:]
    var scheduleUsage: [String: ScheduleUsageState] = [:]
    var shortcutSetup: [String: ShortcutSetupState] = [:]
    var history: [StatusHistoryEntry] = []
    var day = Calendar.current.startOfDay(for: Date())
    var locked: Set<String> = []
    var scheduledLocked: Set<String> = []
    var activeScheduleIDs: Set<String> = []
    var settingsLock = SettingsLockState()
    var monitoring = false
    var emergency = false
    var generation = UUID().uuidString
    var migrated = false
#if DEBUG
    var debugTrace: [DebugTraceEntry] = []
#endif

    private enum CodingKeys: String, CodingKey {
        case version, presets, schedules, usage, scheduleUsage, shortcutSetup, history, day, locked, scheduledLocked, activeScheduleIDs, settingsLock, monitoring
        case emergency, generation, migrated
#if DEBUG
        case debugTrace
#endif
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        presets = try values.decodeIfPresent([AppPreset].self, forKey: .presets) ?? []
        schedules = try values.decodeIfPresent([ScrollLockSchedule].self, forKey: .schedules) ?? []
        usage = try values.decodeIfPresent([String: UsageState].self, forKey: .usage) ?? [:]
        scheduleUsage = try values.decodeIfPresent([String: ScheduleUsageState].self, forKey: .scheduleUsage) ?? [:]
        shortcutSetup = try values.decodeIfPresent([String: ShortcutSetupState].self, forKey: .shortcutSetup) ?? [:]
        history = try values.decodeIfPresent([StatusHistoryEntry].self, forKey: .history) ?? []
        day = try values.decodeIfPresent(Date.self, forKey: .day) ?? Calendar.current.startOfDay(for: Date())
        locked = try values.decodeIfPresent(Set<String>.self, forKey: .locked) ?? []
        scheduledLocked = try values.decodeIfPresent(Set<String>.self, forKey: .scheduledLocked) ?? []
        activeScheduleIDs = try values.decodeIfPresent(Set<String>.self, forKey: .activeScheduleIDs) ?? []
        settingsLock = try values.decodeIfPresent(SettingsLockState.self, forKey: .settingsLock) ?? SettingsLockState()
        monitoring = try values.decodeIfPresent(Bool.self, forKey: .monitoring) ?? false
        emergency = try values.decodeIfPresent(Bool.self, forKey: .emergency) ?? false
        generation = try values.decodeIfPresent(String.self, forKey: .generation) ?? UUID().uuidString
        migrated = try values.decodeIfPresent(Bool.self, forKey: .migrated) ?? false
#if DEBUG
        debugTrace = try values.decodeIfPresent([DebugTraceEntry].self, forKey: .debugTrace) ?? []
#endif
    }

    mutating func record(_ message: String, now: Date = Date()) {
        history.append(StatusHistoryEntry(timestamp: now, message: message))
        history = Array(history.suffix(1000))
        recordDebug(event: "status", details: message, timestamp: now)
    }

    mutating func recordDebug(
        event: String,
        appID: String? = nil,
        appName: String? = nil,
        details: String,
        timestamp: Date = Date()
    ) {
#if DEBUG
        debugTrace.append(DebugTraceEntry(
            event: event,
            appID: appID,
            appName: appName,
            details: details,
            timestamp: timestamp
        ))
        debugTrace = Array(debugTrace.suffix(20_000))
#endif
    }

    mutating func rollDay(now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        if day != today {
            day = today
            locked.removeAll()
            record("New local day. Daily locks reset; allowances renewed.", now: now)
        }
        for preset in presets {
            guard var value = usage[preset.id] else { continue }
            value.rollDay(now: now, calendar: calendar)
            value.advanceSession(now: now, sessionMinutes: preset.sessionMinutes, enabled: preset.sessionEnabled)
            usage[preset.id] = value
        }
        reconcileScheduledLocks(now: now, calendar: calendar)
        reconcileSchedules(now: now, calendar: calendar)
    }

    func validate(_ proposed: [AppPreset]) throws {
        try validateLockedAppChanges(proposed)
        guard Set(proposed.map(\.id)).count == proposed.count else {
            throw ScrollLockError.message("Duplicate app identifiers. Choose the apps again.")
        }
        let names = proposed.map { Self.normalized($0.name) }
        guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else {
            throw ScrollLockError.message("Give each app a different, nonempty name.")
        }
        let shortcutNames = proposed.map { Self.normalized($0.shortcutName) }
        guard shortcutNames.allSatisfy({ !$0.isEmpty }), Set(shortcutNames).count == shortcutNames.count else {
            throw ScrollLockError.message("Give each app a different Shortcut alias, or leave aliases blank.")
        }
        guard proposed.allSatisfy({
            (1...1440).contains($0.minutes) &&
            (1...1440).contains($0.sessionMinutes) &&
            (1...60).contains($0.hourlyMinutes) &&
            (1...1440).contains($0.cooldownMinutes) &&
            (1...7).contains($0.scheduleWeekday) &&
            (0...1439).contains($0.scheduleStartMinute) &&
            (1...1440).contains($0.scheduleEndMinute) &&
            $0.name.count <= 80 &&
            ($0.shortcutAlias?.count ?? 0) <= 80
        }) else {
            throw ScrollLockError.message("Use 1 to 1,440 minutes for daily/session/cooldown limits, 1 to 60 minutes for hourly limits, and app names of at most 80 characters.")
        }
        for preset in proposed where preset.sessionEnabled {
            let previous = presets.first(where: { $0.id == preset.id })
            let sessionChanged = previous == nil
                || previous?.token != preset.token
                || previous?.sessionEnabled != preset.sessionEnabled
                || previous?.sessionMinutes != preset.sessionMinutes
                || previous?.cooldownMinutes != preset.cooldownMinutes
            // A previously saved session rule can survive a permission
            // reset without its Shortcuts setup. Allow unrelated settings to
            // be saved even after monitoring resumes, but still require setup
            // when the user enables or changes the session rule.
            let preservedUnconfiguredRule = !sessionChanged
            guard shortcutReady(for: preset.token) || preservedUnconfiguredRule else {
                throw ScrollLockError.message("\(preset.name): run both its Start Session and End Session Shortcuts before enabling the per-session limit.")
            }
            if preset.hourlyEnabled && preset.hourlyMinutes < preset.sessionMinutes {
                throw ScrollLockError.message("\(preset.name): hourly limit cannot be shorter than the per-session limit.")
            }
            if preset.enabled && preset.minutes < preset.sessionMinutes {
                throw ScrollLockError.message("\(preset.name): daily limit cannot be shorter than the per-session limit.")
            }
        }
        for preset in proposed where preset.scheduleEnabled {
            guard preset.scheduleStartMinute < preset.scheduleEndMinute else {
                throw ScrollLockError.message("\(preset.name): scheduled block must end after it starts and stay within the same day.")
            }
        }
        for preset in presets where locked.contains(preset.id) {
            guard proposed.first(where: { $0.id == preset.id }) == preset else {
                throw ScrollLockError.message("\(preset.name) is locked until the next local day. Its settings cannot be changed or removed before then.")
            }
        }
        for preset in presets where usage[preset.id]?.sessionLocked == true || usage[preset.id]?.hourlyLocked == true {
            guard proposed.first(where: { $0.id == preset.id }) == preset else {
                throw ScrollLockError.message("\(preset.name) is locked until its active session or hourly window resets.")
            }
        }
    }

    func validateSchedules(_ proposed: [ScrollLockSchedule], apps: [AppPreset]) throws {
        try validateLockedScheduleChanges(proposed)
        let names = proposed.map { Self.normalized($0.name) }
        guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else {
            throw ScrollLockError.message("Schedules need different, nonempty names.")
        }
        guard proposed.allSatisfy({
            !$0.weekdays.isEmpty && $0.weekdays.allSatisfy { (1...7).contains($0) } &&
            (0...1439).contains($0.startMinute) && (1...1440).contains($0.endMinute) &&
            $0.startMinute < $0.endMinute && $0.name.count <= 80
        }) else {
            throw ScrollLockError.message("Each schedule needs at least one day and a same-day time window.")
        }
        for schedule in proposed {
            guard Set(schedule.rules.map(\.appID)).count == schedule.rules.count else {
                throw ScrollLockError.message("An app can appear only once in each schedule.")
            }
            for rule in schedule.rules {
                // Older schedules stored only the main preset ID. LimitStore
                // hydrates those records before saving, but allow them through
                // validation so an existing installation can still migrate.
                let isLegacyRule = rule.token == nil && apps.contains { $0.id == rule.appID }
                guard isLegacyRule || (rule.token != nil && !(rule.token?.isEmpty ?? true)) else {
                    throw ScrollLockError.message("Every scheduled app needs a valid Apple app selection. Choose the app again from the schedule picker.")
                }
                guard (1...1440).contains(rule.totalMinutes),
                      (1...1440).contains(rule.sessionMinutes),
                      (1...1440).contains(rule.cooldownMinutes),
                      (1...60).contains(rule.hourlyMinutes),
                      (rule.shortcutAlias?.count ?? 0) <= 80 else {
                    throw ScrollLockError.message("Schedule limits and Shortcut aliases must use valid durations and names.")
                }
                if rule.sessionEnabled && rule.totalEnabled && rule.totalMinutes < rule.sessionMinutes {
                    throw ScrollLockError.message("A schedule total limit cannot be shorter than its per-session limit.")
                }
                if rule.sessionEnabled {
                    let token = rule.token ?? apps.first(where: { $0.id == rule.appID })?.token
                    let previous = schedules.first(where: { $0.id == schedule.id })?.rules
                        .first(where: { $0.appID == rule.appID })
                    let previousToken = previous?.token ?? presets.first(where: { $0.id == previous?.appID })?.token
                    let preservedSession = previous?.sessionEnabled == true
                        && previousToken == token
                        && previous?.sessionMinutes == rule.sessionMinutes
                        && previous?.cooldownMinutes == rule.cooldownMinutes
                    guard let token, shortcutReady(for: token) || preservedSession else {
                        throw ScrollLockError.message("\(rule.name ?? "Scheduled app"): run both its Start Session and End Session Shortcuts before enabling the scheduled per-session limit.")
                    }
                }
                if rule.sessionEnabled && rule.hourlyEnabled && rule.hourlyMinutes < rule.sessionMinutes {
                    throw ScrollLockError.message("A schedule hourly limit cannot be shorter than its per-session limit.")
                }
            }
        }
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isPlaceholderAppName(_ name: String) -> Bool {
        let value = normalized(name)
        if value.hasPrefix("selected app ") { return Int(value.dropFirst("selected app ".count)) != nil }
        if value.hasPrefix("app ") { return Int(value.dropFirst("app ".count)) != nil }
        return value.isEmpty || value == "unknown app" || value == "unnamed app"
    }

    private func validateLockedAppChanges(_ proposed: [AppPreset]) throws {
        guard settingsLock.enabled else { return }
        for current in presets {
            guard let next = proposed.first(where: { $0.id == current.id }) else {
                throw ScrollLockError.message("Settings are locked. Existing apps cannot be removed until the unlock time.")
            }
            guard next.token == current.token, next.name == current.name else {
                throw ScrollLockError.message("Settings are locked. App identity cannot be changed until the unlock time.")
            }
            if current.enabled && (!next.enabled || next.minutes > current.minutes) {
                throw ScrollLockError.message("Settings are locked. Daily limits can only become stricter.")
            }
            if current.sessionEnabled && (!next.sessionEnabled || next.sessionMinutes > current.sessionMinutes || next.cooldownMinutes < current.cooldownMinutes) {
                throw ScrollLockError.message("Settings are locked. Per-session limits can only become stricter.")
            }
            if current.hourlyEnabled && (!next.hourlyEnabled || next.hourlyMinutes > current.hourlyMinutes) {
                throw ScrollLockError.message("Settings are locked. Hourly limits can only become stricter.")
            }
            if current.scheduleEnabled && !next.scheduleEnabled {
                throw ScrollLockError.message("Settings are locked. Scheduled restrictions can only become stricter.")
            }
        }
    }

    private func validateLockedScheduleChanges(_ proposed: [ScrollLockSchedule]) throws {
        guard settingsLock.enabled else { return }
        for current in schedules {
            guard let next = proposed.first(where: { $0.id == current.id }) else {
                throw ScrollLockError.message("Settings are locked. Existing schedules cannot be removed until the unlock time.")
            }
            if current.enabled && !next.enabled {
                throw ScrollLockError.message("Settings are locked. Existing schedules cannot be turned off until the unlock time.")
            }
            guard next.weekdays.isSuperset(of: current.weekdays),
                  next.startMinute <= current.startMinute,
                  next.endMinute >= current.endMinute else {
                throw ScrollLockError.message("Settings are locked. Schedule windows can only become stricter.")
            }
            for currentRule in current.rules {
                guard let nextRule = next.rules.first(where: { $0.appID == currentRule.appID }) else {
                    throw ScrollLockError.message("Settings are locked. Existing scheduled apps cannot be removed until the unlock time.")
                }
                if currentRule.block && !nextRule.block { throw ScrollLockError.message("Settings are locked. Complete blocks cannot be relaxed.") }
                if currentRule.totalEnabled && (!nextRule.totalEnabled || nextRule.totalMinutes > currentRule.totalMinutes) { throw ScrollLockError.message("Settings are locked. Schedule total limits can only become stricter.") }
                if currentRule.sessionEnabled && (!nextRule.sessionEnabled || nextRule.sessionMinutes > currentRule.sessionMinutes) { throw ScrollLockError.message("Settings are locked. Schedule session limits can only become stricter.") }
                if currentRule.hourlyEnabled && (!nextRule.hourlyEnabled || nextRule.hourlyMinutes > currentRule.hourlyMinutes) { throw ScrollLockError.message("Settings are locked. Schedule hourly limits can only become stricter.") }
            }
        }
    }


    mutating func reached(id: String, generation: String, now: Date = Date()) -> Bool {
        rollDay(now: now)
        guard monitoring, !emergency, self.generation == generation,
              let preset = presets.first(where: { $0.id == id && $0.enabled }) else { return false }
        guard locked.insert(id).inserted else { return true }
        if var session = usage[id] {
            session.seconds = session.used(at: now)
            session.sessionSeconds = session.sessionUsed(at: now)
            session.sessionActiveSince = nil
            session.hourlySeconds = session.hourlyUsed(at: now, calendar: .current)
            usage[id] = session
        }
        record("\(preset.name): system daily threshold reached (\(preset.minutes) min). Shield requested until the next local day.", now: now)
        return true
    }

    mutating func reachedWindow(id: String, generation: String, rule: String, now: Date = Date()) -> Bool {
        rollDay(now: now)
        guard monitoring, !emergency, self.generation == generation,
              let preset = presets.first(where: { $0.id == id }) else { return false }
        var state = usage[id] ?? UsageState(day: Calendar.current.startOfDay(for: now))
        let enabled = rule == "session" ? preset.sessionEnabled : preset.hourlyEnabled
        guard enabled else { return false }
        guard rule != "session" || state.sessionActiveSince != nil else { return false }
        state.advanceSession(now: now, sessionMinutes: preset.sessionMinutes, enabled: preset.sessionEnabled)
        if rule == "session", state.sessionActiveSince != nil {
            state.sessionSeconds = state.sessionUsed(at: now)
            state.sessionActiveSince = nil
        }
        let dailyUsed = state.used(at: now)
        let sessionUsed = state.sessionUsed(at: now)
        let hourlyUsed = state.hourlyUsed(at: now, calendar: .current)
        if rule == "session" {
            guard !state.sessionLocked else { return true }
            state.seconds = dailyUsed
            state.sessionSeconds = sessionUsed
            state.hourlySeconds = hourlyUsed
            state.sessionLocked = true
            state.sessionSeconds = max(state.sessionSeconds, TimeInterval(preset.sessionMinutes * 60))
            state.sessionCooldownUntil = now.addingTimeInterval(TimeInterval(preset.cooldownMinutes * 60))
            state.sessionWindowStarted = nil
            state.sessionResetAt = nil
            record("\(preset.name): per-session threshold reached (\(preset.sessionMinutes) min). Shield active for \(preset.cooldownMinutes) min from this threshold.", now: now)
        } else {
            guard !state.hourlyLocked else { return true }
            state.seconds = dailyUsed
            state.sessionSeconds = sessionUsed
            state.hourlySeconds = hourlyUsed
            state.hourlyLocked = true
            record("\(preset.name): hourly threshold reached (\(preset.hourlyMinutes) min). Shield active until the next local hour.", now: now)
        }
        usage[id] = state
        return true
    }

    func isLocked(_ id: String) -> Bool {
        locked.contains(id) || scheduledLocked.contains(id) || usage[id]?.sessionLocked == true || usage[id]?.hourlyLocked == true
    }

    func lockReason(for preset: AppPreset, usage: UsageState? = nil) -> String {
        if locked.contains(preset.id) { return "daily" }
        if scheduledLocked.contains(preset.id) { return "scheduled" }
        let value = usage ?? self.usage[preset.id]
        if value?.sessionLocked == true { return "per-session" }
        if value?.hourlyLocked == true { return "hourly" }
        return "limit"
    }

    mutating func disableAllLimits(now: Date = Date()) {
        for index in presets.indices {
            presets[index].enabled = false
            presets[index].sessionEnabled = false
            presets[index].hourlyEnabled = false
            presets[index].scheduleEnabled = false
        }
        for index in schedules.indices {
            schedules[index].enabled = false
            for ruleIndex in schedules[index].rules.indices {
                schedules[index].rules[ruleIndex].block = false
                schedules[index].rules[ruleIndex].totalEnabled = false
                schedules[index].rules[ruleIndex].sessionEnabled = false
                schedules[index].rules[ruleIndex].hourlyEnabled = false
            }
        }
        for key in Array(usage.keys) {
            guard var value = usage[key] else { continue }
            value.sessionSeconds = value.sessionUsed(at: now)
            value.sessionActiveSince = nil
            value.sessionResetAt = nil
            value.sessionCooldownUntil = nil
            value.sessionLocked = false
            value.hourlyLocked = false
            usage[key] = value
        }
        for key in Array(scheduleUsage.keys) {
            guard var value = scheduleUsage[key] else { continue }
            value.sessionSeconds = value.sessionUsed(at: now)
            value.sessionActiveSince = nil
            value.sessionResetAt = nil
            value.sessionCooldownUntil = nil
            value.sessionLocked = false
            value.hourlyLocked = false
            value.totalLocked = false
            scheduleUsage[key] = value
        }
        monitoring = false
        generation = UUID().uuidString
        locked.removeAll()
        scheduledLocked.removeAll()
        activeScheduleIDs.removeAll()
    }

    mutating func recover(now: Date = Date()) {
        emergency = true
        monitoring = false
        generation = UUID().uuidString
        locked.removeAll()
        scheduledLocked.removeAll()
        activeScheduleIDs.removeAll()
        settingsLock = SettingsLockState()
        record("Mac emergency recovery: monitoring stopped and ScrollLock shields cleared. Limits stay paused until resumed in ScrollLock.", now: now)
    }

    static func scheduleKey(scheduleID: String, appID: String) -> String {
        "\(scheduleID)::\(appID)"
    }

    static func shortcutKey(for token: Data) -> String {
        token.base64EncodedString()
    }

    var shortcutApps: [ShortcutAppOption] {
        var result: [String: ShortcutAppOption] = [:]
        for preset in presets where !preset.token.isEmpty {
            let key = Self.shortcutKey(for: preset.token)
            result[key] = ShortcutAppOption(id: key, name: preset.shortcutName)
        }
        for rule in schedules.flatMap(\.rules) {
            // Older schedules link to a main preset instead of storing a token.
            guard let token = token(for: rule), !token.isEmpty else { continue }
            let key = Self.shortcutKey(for: token)
            if result[key] == nil {
                result[key] = ShortcutAppOption(id: key, name: rule.shortcutName)
            }
        }
        return result.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func token(for rule: ScheduleAppRule) -> Data? {
        rule.token ?? presets.first(where: { $0.id == rule.appID })?.token
    }

    func containsShortcutApp(_ tokenKey: String) -> Bool {
        shortcutApps.contains { $0.id == tokenKey }
    }

    func shortcutReady(for token: Data) -> Bool {
        shortcutSetup[Self.shortcutKey(for: token)]?.isReady == true
    }

    mutating func shortcutDidStart(tokenKey: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard containsShortcutApp(tokenKey) else { return false }
        var setup = shortcutSetup[tokenKey] ?? ShortcutSetupState(startSeenAt: nil, endSeenAt: nil)
        setup.startSeenAt = now
        shortcutSetup[tokenKey] = setup
        rollDay(now: now, calendar: calendar)
        guard monitoring, !emergency, setup.isReady else { return false }

        var started = false
        for index in presets.indices where Self.shortcutKey(for: presets[index].token) == tokenKey {
            let preset = presets[index]
            guard preset.sessionEnabled, !isLocked(preset.id) else { continue }
            var value = usage[preset.id] ?? UsageState(day: calendar.startOfDay(for: now))
            guard value.sessionCooldownUntil == nil else { continue }
            value.beginSession(now: now, sessionMinutes: preset.sessionMinutes)
            usage[preset.id] = value
            started = true
        }

        for schedule in schedules {
            guard let interval = activeInterval(for: schedule, now: now, calendar: calendar) else { continue }
            for rule in schedule.rules where rule.sessionEnabled && token(for: rule).map(Self.shortcutKey(for:)) == tokenKey {
                let key = Self.scheduleKey(scheduleID: schedule.id, appID: rule.appID)
                var value = scheduleUsage[key] ?? ScheduleUsageState()
                if value.intervalStart != interval.start { value.reset(for: interval) }
                guard !value.sessionLocked, value.sessionCooldownUntil == nil, !scheduledLocked.contains(rule.appID) else { continue }
                value.beginSession(now: now, sessionMinutes: rule.sessionMinutes, intervalEnd: interval.end)
                scheduleUsage[key] = value
                started = true
            }
        }
        recordDebug(event: "shortcut-start", details: "Session start received for token key \(tokenKey).", timestamp: now)
        return started
    }

    mutating func shortcutDidEnd(tokenKey: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard containsShortcutApp(tokenKey) else { return false }
        var setup = shortcutSetup[tokenKey] ?? ShortcutSetupState(startSeenAt: nil, endSeenAt: nil)
        setup.endSeenAt = now
        shortcutSetup[tokenKey] = setup
        rollDay(now: now, calendar: calendar)

        var changed = false
        for index in presets.indices where Self.shortcutKey(for: presets[index].token) == tokenKey {
            let preset = presets[index]
            guard preset.sessionEnabled, var value = usage[preset.id] else { continue }
            guard value.sessionActiveSince != nil else { continue }
            if value.finishSession(now: now, sessionMinutes: preset.sessionMinutes, cooldownMinutes: preset.cooldownMinutes) {
                record("\(preset.name): per-session allowance exhausted by Shortcut timing. Cooldown started for \(preset.cooldownMinutes) min.", now: now)
            }
            usage[preset.id] = value
            changed = true
        }

        for schedule in schedules {
            for rule in schedule.rules where rule.sessionEnabled && token(for: rule).map(Self.shortcutKey(for:)) == tokenKey {
                let key = Self.scheduleKey(scheduleID: schedule.id, appID: rule.appID)
                guard var value = scheduleUsage[key], let started = value.sessionActiveSince, let intervalEnd = value.intervalEnd else { continue }
                let finishAt = max(started, min(now, intervalEnd))
                if value.finishSession(now: finishAt, sessionMinutes: rule.sessionMinutes, cooldownMinutes: rule.cooldownMinutes) {
                    if activeInterval(for: schedule, now: now, calendar: calendar) != nil {
                        scheduledLocked.insert(rule.appID)
                    }
                    record("\(schedule.name): \(rule.name ?? rule.appID) exhausted its scheduled per-session allowance by Shortcut timing. Cooldown started for \(rule.cooldownMinutes) min.", now: now)
                }
                scheduleUsage[key] = value
                changed = true
            }
        }
        recordDebug(event: "shortcut-end", details: "Session end received for token key \(tokenKey).", timestamp: now)
        return changed
    }

    func activeInterval(for schedule: ScrollLockSchedule, now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        guard schedule.enabled,
              schedule.weekdays.contains(calendar.component(.weekday, from: now)) else { return nil }
        let day = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .minute, value: schedule.startMinute, to: day) else { return nil }
        let end: Date
        if schedule.endMinute == 1440 {
            end = calendar.date(byAdding: .day, value: 1, to: day) ?? start
        } else {
            end = calendar.date(byAdding: .minute, value: schedule.endMinute, to: day) ?? start
        }
        guard now >= start && now < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    mutating func reconcileSchedules(now: Date = Date(), calendar: Calendar = .current) {
        let current = Dictionary(uniqueKeysWithValues: schedules.compactMap { schedule in
            activeInterval(for: schedule, now: now, calendar: calendar).map { (schedule.id, $0) }
        })
        activeScheduleIDs = Set(current.keys)
        scheduledLocked = Set(presets.filter {
            $0.scheduleEnabled && isWithinSchedule(for: $0, now: now, calendar: calendar)
        }.map(\.id))
        for schedule in schedules {
            guard let interval = current[schedule.id] else { continue }
            for rule in schedule.rules {
                let key = Self.scheduleKey(scheduleID: schedule.id, appID: rule.appID)
                var value = scheduleUsage[key] ?? ScheduleUsageState()
                if value.intervalStart != interval.start {
                    value.reset(for: interval)
                }
                if let cooldown = value.sessionCooldownUntil, cooldown <= now {
                    value.sessionSeconds = 0
                    value.sessionActiveSince = nil
                    value.sessionResetAt = nil
                    value.sessionCooldownUntil = nil
                    value.sessionLocked = false
                } else if value.sessionActiveSince == nil, let reset = value.sessionResetAt, reset <= now {
                    value.sessionSeconds = 0
                    value.sessionResetAt = nil
                    value.sessionLocked = false
                }
                scheduleUsage[key] = value
                if rule.block || value.totalLocked || value.sessionLocked || value.hourlyLocked {
                    scheduledLocked.insert(rule.appID)
                }
            }
        }
    }

    mutating func reachedSchedule(scheduleID: String, appID: String, rule: String, generation: String, now: Date = Date()) -> Bool {
        rollDay(now: now)
        guard monitoring, !emergency, self.generation == generation,
              let schedule = schedules.first(where: { $0.id == scheduleID }),
              let interval = activeInterval(for: schedule, now: now),
              let appRule = schedule.rules.first(where: { $0.appID == appID }) else { return false }
        let key = Self.scheduleKey(scheduleID: scheduleID, appID: appID)
        var value = scheduleUsage[key] ?? ScheduleUsageState()
        if value.intervalStart != interval.start { value.reset(for: interval) }
        switch rule {
        case "total":
            guard appRule.totalEnabled else { return false }
            value.totalLocked = true
        case "session":
            guard appRule.sessionEnabled, value.sessionActiveSince != nil else { return false }
            if value.sessionActiveSince != nil {
                value.sessionSeconds = value.sessionUsed(at: now)
                value.sessionActiveSince = nil
            }
            value.sessionLocked = true
            value.sessionCooldownUntil = now.addingTimeInterval(TimeInterval(appRule.cooldownMinutes * 60))
            value.sessionResetAt = nil
        case "hourly":
            guard appRule.hourlyEnabled else { return false }
            value.hourlyLocked = true
        default:
            return false
        }
        scheduleUsage[key] = value
        scheduledLocked.insert(appID)
        if rule == "session" {
            record("\(schedule.name): \(appRule.name ?? appID) reached its scheduled per-session limit. Cooldown lasts \(appRule.cooldownMinutes) min.", now: now)
        } else {
            record("\(schedule.name): \(appRule.name ?? appID) reached its scheduled \(rule) limit.", now: now)
        }
        return true
    }

    func isWithinSchedule(for preset: AppPreset, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard preset.scheduleEnabled else { return false }
        let weekday = calendar.component(.weekday, from: now)
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return weekday == preset.scheduleWeekday &&
            minute >= preset.scheduleStartMinute && minute < preset.scheduleEndMinute
    }

    mutating func reconcileScheduledLocks(now: Date = Date(), calendar: Calendar = .current) {
        let enabledIDs = Set(presets.filter(\.scheduleEnabled).map(\.id))
        scheduledLocked.removeAll()
        for preset in presets where isWithinSchedule(for: preset, now: now, calendar: calendar) {
            if enabledIDs.contains(preset.id) { scheduledLocked.insert(preset.id) }
        }
    }

    static func weekdayName(_ weekday: Int) -> String {
        let names = Calendar.current.weekdaySymbols
        guard (1...7).contains(weekday) else { return "Unknown day" }
        return names[weekday - 1]
    }

    static func clockText(_ minute: Int) -> String {
        let hour = max(0, min(23, minute / 60))
        let minuteValue = max(0, min(59, minute % 60))
        var components = DateComponents()
        components.hour = hour
        components.minute = minuteValue
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "Unknown" }
        let value = Int(min(max(0, seconds), 31_536_000).rounded())
        return value < 60 ? "\(value)s" : "\(value / 60)m \(value % 60)s"
    }
}

enum ScrollLockError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

// Serialize app, intent and extension writes. Corrupt storage throws rather
// than silently replacing existing limits or history with empty state.
enum ScrollLockStorage {
    static func container() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.example.scrolllock") else {
            throw ScrollLockError.message("ScrollLock's shared storage is unavailable. Check App Group signing.")
        }
        return url
    }

    @discardableResult
    static func transaction<T>(directory: URL? = nil, _ body: (inout ScrollLockState) throws -> T) throws -> T {
        let root = try directory ?? container()
        let lockURL = root.appendingPathComponent("scrolllock-state.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ScrollLockError.message("Cannot open ScrollLock storage lock (\(errno)).") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ScrollLockError.message("Cannot lock ScrollLock storage (\(errno)).") }
        defer { flock(fd, LOCK_UN) }
        let directoryURL: URL
        let legacyFile = root.appendingPathComponent("scrolllock-state.json")
        if directory == nil {
            directoryURL = root.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } else {
            directoryURL = root
        }
        let file = directoryURL.appendingPathComponent("scrolllock-state.json")
        let sourceFile = FileManager.default.fileExists(atPath: file.path) ? file : legacyFile
        let original = FileManager.default.fileExists(atPath: sourceFile.path) ? try Data(contentsOf: sourceFile) : nil
        var state = try original.map { try JSONDecoder().decode(ScrollLockState.self, from: $0) } ?? ScrollLockState()
        guard state.version == 1 else {
            throw ScrollLockError.message("This saved state needs a newer ScrollLock build. Existing data was left intact.")
        }
        let result = try body(&state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        if original != data {
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: lockURL.path)
            #else
            try data.write(to: file, options: .atomic)
            #endif
        }
        return result
    }
}
