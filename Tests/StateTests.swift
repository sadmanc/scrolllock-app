import Foundation

@main
enum StateTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAILED: " + message) }
    }
    static func rejected(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("FAILED: " + message) } catch { checks += 1 }
    }
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--worker" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            for _ in 0..<50 { try ScrollLockStorage.transaction(directory: directory) { $0.record(UUID().uuidString) } }
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12))!
        let first = AppPreset(token: Data([1]), name: "Instagram", enabled: true, minutes: 1)
        let second = AppPreset(token: Data([2]), name: "TikTok", enabled: true, minutes: 5)
        var state = ScrollLockState()
        state.day = Calendar.current.startOfDay(for: noon)
        state.presets = [first, second]
        state.monitoring = true
        let generation = state.generation
        check(state.reached(id: first.id, generation: generation, now: noon), "first threshold accepted")
        check(state.reached(id: second.id, generation: generation, now: noon), "second threshold accepted")
        check(state.locked == [first.id, second.id], "second lock preserves first")
        let historyCount = state.history.count
        check(state.reached(id: first.id, generation: generation, now: noon), "duplicate threshold idempotent")
        check(state.history.count == historyCount, "duplicate threshold adds no event")
        state.rollDay(now: noon)
        check(state.locked.count == 2, "same-day interval start keeps locks")
        rejected("locked app cannot be removed") { try state.validate([second]) }
        var disabled = first
        disabled.enabled = false
        rejected("locked app cannot be disabled") { try state.validate([disabled, second]) }
        check(!state.reached(id: first.id, generation: "stale", now: noon), "old registration ignored")
        state.recover(now: noon)
        check(state.locked.isEmpty && !state.monitoring && state.emergency, "emergency stops enforcement")
        check(!state.reached(id: first.id, generation: generation, now: noon), "late threshold cannot undo recovery")
        try state.validate([disabled, second])
        state.presets = [disabled, second]
        state.emergency = false
        state.monitoring = true
        check(!state.reached(id: first.id, generation: state.generation, now: noon), "disabled app ignores threshold")
        check(state.reached(id: second.id, generation: state.generation, now: noon), "other app remains enabled")
        state.rollDay(now: calendar.date(byAdding: .day, value: 1, to: noon)!)
        check(state.locked.isEmpty, "new day resets both locks")
        var invalid = first
        invalid.minutes = 0
        rejected("zero duration rejected") { try state.validate([invalid]) }
        invalid.minutes = 1441
        rejected("excessive duration rejected") { try state.validate([invalid]) }
        invalid.minutes = 37
        try state.validate([invalid])
        var duplicateName = second
        duplicateName.name = " instagram "
        rejected("ambiguous app names rejected") { try state.validate([first, duplicateName]) }
        var windowPreset = first
        windowPreset.minutes = 30
        windowPreset.sessionEnabled = true
        windowPreset.sessionMinutes = 15
        windowPreset.cooldownMinutes = 20
        windowPreset.hourlyEnabled = true
        windowPreset.hourlyMinutes = 20
        var adjustedCooldown = windowPreset
        adjustedCooldown.sessionMinutes = 30
        check(adjustedCooldown.cooldownMinutes == 20, "cooldown stays independent from session time")
        var invalidWindow = windowPreset
        invalidWindow.cooldownMinutes = 9
        rejected("cooldown shorter than the Device Activity window rejected") { try state.validate([invalidWindow]) }
        invalidWindow = windowPreset
        invalidWindow.hourlyMinutes = 9
        rejected("hourly shorter than session rejected") { try state.validate([invalidWindow]) }
        invalidWindow = windowPreset
        invalidWindow.minutes = 9
        rejected("daily shorter than session rejected") { try state.validate([invalidWindow]) }
        state.shortcutSetup[ScrollLockState.shortcutKey(for: windowPreset.token)] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        invalidWindow = windowPreset
        invalidWindow.cooldownMinutes = 1
        try state.validate([invalidWindow])
        check(true, "one-minute general cooldown is accepted")

        var staleSessionPreset = first
        staleSessionPreset.sessionEnabled = true
        staleSessionPreset.sessionMinutes = 1
        staleSessionPreset.cooldownMinutes = 1
        var staleSessionState = ScrollLockState()
        staleSessionState.presets = [staleSessionPreset]
        var unrelatedChange = staleSessionPreset
        unrelatedChange.minutes = 2
        try staleSessionState.validate([unrelatedChange])
        check(true, "unrelated settings can save when an old session rule lacks Shortcuts")
        staleSessionState.monitoring = true
        try staleSessionState.validate([unrelatedChange, second])
        check(true, "unchanged legacy session does not block adding apps after monitoring resumes")
        try staleSessionState.validate([staleSessionPreset])
        check(true, "unchanged legacy session remains saveable while monitoring is on")

        var changedSession = staleSessionPreset
        changedSession.sessionMinutes = 2
        rejected("changing an unconfigured session rule still requires Shortcuts") {
            try staleSessionState.validate([changedSession])
        }

        var oneMinutePreset = windowPreset
        oneMinutePreset.sessionMinutes = 1
        oneMinutePreset.cooldownMinutes = 1
        var oneMinuteState = ScrollLockState()
        oneMinuteState.presets = [oneMinutePreset]
        oneMinuteState.monitoring = true
        let oneMinuteKey = ScrollLockState.shortcutKey(for: oneMinutePreset.token)
        oneMinuteState.shortcutSetup[oneMinuteKey] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        try oneMinuteState.validate([oneMinutePreset])
        check(oneMinuteState.shortcutDidStart(tokenKey: oneMinuteKey, now: noon, calendar: calendar), "one-minute session starts from the Shortcut action")
        check(oneMinuteState.usage[oneMinutePreset.id]?.sessionActiveSince == noon, "active session records its exact start timestamp")
        check(oneMinuteState.shortcutDidEnd(tokenKey: oneMinuteKey, now: noon.addingTimeInterval(60), calendar: calendar), "one-minute session ends from the Shortcut action")
        check(oneMinuteState.usage[oneMinutePreset.id]?.sessionLocked == true, "one-minute session locks at the end action")
        check(oneMinuteState.usage[oneMinutePreset.id]?.sessionCooldownUntil == noon.addingTimeInterval(60 + 60), "one-minute cooldown starts after the session")
        check(!oneMinuteState.shortcutDidStart(tokenKey: oneMinuteKey, now: noon.addingTimeInterval(61), calendar: calendar), "Shortcut start is ignored during cooldown")
        check(oneMinuteState.usage[oneMinutePreset.id]?.sessionActiveSince == nil, "cooldown prevents a new active session")
        oneMinuteState.rollDay(now: noon.addingTimeInterval(121), calendar: calendar)
        check(oneMinuteState.usage[oneMinutePreset.id]?.sessionLocked == false, "cooldown expiry unlocks the session budget")
        check(oneMinuteState.shortcutDidStart(tokenKey: oneMinuteKey, now: noon.addingTimeInterval(121), calendar: calendar), "Shortcut start works after cooldown expiry")
        check(oneMinuteState.shortcutDidEnd(tokenKey: oneMinuteKey, now: noon.addingTimeInterval(181), calendar: calendar), "second one-minute session ends at the exact boundary")
        let oneMinuteSeconds = oneMinuteState.usage[oneMinutePreset.id]?.sessionSeconds
        check(!oneMinuteState.shortcutDidEnd(tokenKey: oneMinuteKey, now: noon.addingTimeInterval(182), calendar: calendar), "duplicate End Shortcut is idempotent")
        check(oneMinuteState.usage[oneMinutePreset.id]?.sessionSeconds == oneMinuteSeconds, "duplicate End Shortcut does not add elapsed time")

        var setupState = ScrollLockState()
        setupState.presets = [oneMinutePreset]
        setupState.monitoring = true
        let setupKey = ScrollLockState.shortcutKey(for: oneMinutePreset.token)
        setupState.presets[0].sessionEnabled = false
        rejected("enabling a session requires both Shortcut actions") { try setupState.validate([oneMinutePreset]) }
        setupState.presets = [oneMinutePreset]
        check(!setupState.shortcutDidStart(tokenKey: setupKey, now: noon, calendar: calendar), "first setup action does not start an unconfirmed session")
        check(!setupState.shortcutReady(for: oneMinutePreset.token), "one setup action is insufficient")
        check(!setupState.shortcutDidEnd(tokenKey: setupKey, now: noon.addingTimeInterval(10), calendar: calendar), "first end action does not end an unstarted session")
        check(setupState.shortcutReady(for: oneMinutePreset.token), "both setup actions confirm the app automation pair")
        try setupState.validate([oneMinutePreset])
        check(!setupState.shortcutDidStart(tokenKey: "wrong-token", now: noon, calendar: calendar), "Shortcut for another app cannot start this session")

        var catalogState = ScrollLockState()
        let catalogPresets = (1...4).map {
            AppPreset(token: Data([UInt8($0)]), name: "Catalog app \($0)", enabled: false)
        }
        catalogState.presets = catalogPresets
        let scheduleOnlyToken = Data([5])
        let sixthToken = Data([6])
        var catalogSchedule = ScrollLockSchedule(name: "Catalog", enabled: false)
        catalogSchedule.rules = [
            ScheduleAppRule(appID: catalogPresets[0].id), // Legacy ID-only link.
            ScheduleAppRule(token: catalogPresets[1].token, name: "Duplicate"),
            ScheduleAppRule(token: scheduleOnlyToken, name: "Schedule only", shortcutAlias: "Reading"),
            ScheduleAppRule(token: sixthToken, name: "Sixth"),
            ScheduleAppRule(name: "Orphan without a token"),
            ScheduleAppRule(token: Data(), name: "Empty token")
        ]
        catalogState.schedules = [catalogSchedule, catalogSchedule]
        let catalogIDs = Set((1...6).map { ScrollLockState.shortcutKey(for: Data([UInt8($0)])) })
        check(catalogState.shortcutApps.count == 6, "Shortcut catalog supports more than two apps")
        check(Set(catalogState.shortcutApps.map(\.id)) == catalogIDs, "catalog contains exactly the union of selected apps")
        check(catalogState.shortcutApps.filter { $0.id == ScrollLockState.shortcutKey(for: catalogPresets[1].token) }.count == 1,
              "app selected in both sections appears only once")
        check(catalogState.shortcutApps.contains { $0.name == "Reading" }, "schedule-only Shortcut alias is shown")
        catalogState.presets[1].shortcutAlias = "Main alias"
        check(catalogState.shortcutApps.contains { $0.name == "Main alias" }, "latest main alias overrides duplicate schedule name")
        let scheduleOnlyKey = ScrollLockState.shortcutKey(for: scheduleOnlyToken)
        _ = catalogState.shortcutDidStart(tokenKey: scheduleOnlyKey, now: noon, calendar: calendar)
        _ = catalogState.shortcutDidEnd(tokenKey: scheduleOnlyKey, now: noon, calendar: calendar)
        check(catalogState.shortcutReady(for: scheduleOnlyToken), "schedule-only app can confirm both setup actions while rules are off")
        catalogState.presets.removeAll()
        check(catalogState.shortcutApps.count == 3, "removing main selection keeps apps still selected by a token in schedules")
        catalogState.schedules.removeAll()
        check(catalogState.shortcutApps.isEmpty, "old Shortcut setup never adds removed apps to the picker")
        let removedSetup = catalogState.shortcutSetup[scheduleOnlyKey]
        check(!catalogState.shortcutDidStart(tokenKey: scheduleOnlyKey, now: noon.addingTimeInterval(60), calendar: calendar),
              "stale Start action cannot act on a removed app")
        check(!catalogState.shortcutDidEnd(tokenKey: scheduleOnlyKey, now: noon.addingTimeInterval(120), calendar: calendar),
              "stale End action cannot act on a removed app")
        check(catalogState.shortcutSetup[scheduleOnlyKey]?.startSeenAt == removedSetup?.startSeenAt
              && catalogState.shortcutSetup[scheduleOnlyKey]?.endSeenAt == removedSetup?.endSeenAt,
              "removed app actions do not mutate setup")
        check(!catalogState.shortcutDidStart(tokenKey: "unknown", now: noon, calendar: calendar)
              && catalogState.shortcutSetup["unknown"] == nil, "unknown app cannot create a setup entry")

        var resetState = ScrollLockState()
        var resetPreset = oneMinutePreset
        resetPreset.sessionMinutes = 2
        resetPreset.cooldownMinutes = 1
        resetState.presets = [resetPreset]
        resetState.monitoring = true
        let resetKey = ScrollLockState.shortcutKey(for: resetPreset.token)
        resetState.shortcutSetup[resetKey] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        check(resetState.shortcutDidStart(tokenKey: resetKey, now: noon, calendar: calendar), "reset-window test session starts")
        check(resetState.shortcutDidEnd(tokenKey: resetKey, now: noon.addingTimeInterval(30), calendar: calendar), "short reset-window test session ends")
        check(resetState.usage[resetPreset.id]?.sessionSeconds == 30, "short session retains its precise elapsed seconds")
        check(resetState.shortcutDidStart(tokenKey: resetKey, now: noon.addingTimeInterval(121), calendar: calendar), "new session starts after reset window")
        check(resetState.usage[resetPreset.id]?.sessionSeconds == 0, "reset window clears prior unused allowance")
        check(resetState.shortcutDidEnd(tokenKey: resetKey, now: noon.addingTimeInterval(151), calendar: calendar), "new reset-window session ends")
        check(resetState.usage[resetPreset.id]?.sessionLocked == false, "unused session allowance does not lock the app")

        var activeResetState = ScrollLockState()
        activeResetState.presets = [oneMinutePreset]
        activeResetState.monitoring = true
        activeResetState.shortcutSetup[oneMinuteKey] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        check(activeResetState.shortcutDidStart(tokenKey: oneMinuteKey, now: noon, calendar: calendar), "active session reset test starts")
        activeResetState.rollDay(now: noon.addingTimeInterval(121), calendar: calendar)
        check(activeResetState.usage[oneMinutePreset.id]?.sessionActiveSince == noon, "active session is not reset while its hidden deadline passes")
        check(activeResetState.shortcutDidEnd(tokenKey: oneMinuteKey, now: noon.addingTimeInterval(121), calendar: calendar), "active session can end after its hidden deadline")
        check(activeResetState.usage[oneMinutePreset.id]?.sessionLocked == true, "active elapsed time still counts after the hidden deadline")

        var staleThresholdState = ScrollLockState()
        staleThresholdState.presets = [oneMinutePreset]
        staleThresholdState.monitoring = true
        staleThresholdState.shortcutSetup[oneMinuteKey] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        check(!staleThresholdState.reachedWindow(id: oneMinutePreset.id, generation: staleThresholdState.generation, rule: "session", now: noon), "stale session threshold is ignored without an active Shortcut session")
        check(staleThresholdState.usage[oneMinutePreset.id]?.sessionLocked != true, "stale session threshold does not create a lock")

        var dailyDuringSessionState = ScrollLockState()
        dailyDuringSessionState.presets = [oneMinutePreset]
        dailyDuringSessionState.monitoring = true
        dailyDuringSessionState.shortcutSetup[oneMinuteKey] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        check(dailyDuringSessionState.shortcutDidStart(tokenKey: oneMinuteKey, now: noon, calendar: calendar), "daily/session interaction starts")
        check(dailyDuringSessionState.reached(id: oneMinutePreset.id, generation: dailyDuringSessionState.generation, now: noon.addingTimeInterval(20)), "daily threshold accepts during a live session")
        check(dailyDuringSessionState.usage[oneMinutePreset.id]?.sessionActiveSince == nil, "daily threshold snapshots and closes the active session")
        check(!dailyDuringSessionState.shortcutDidEnd(tokenKey: oneMinuteKey, now: noon.addingTimeInterval(30), calendar: calendar), "end after daily lock does not add a second session")

        // General session timing is driven by Shortcut start/end actions.
        // Device Activity remains a safety threshold while the app is open.
        state = ScrollLockState()
        state.presets = [windowPreset]
        state.monitoring = true
        let windowKey = ScrollLockState.shortcutKey(for: windowPreset.token)
        state.shortcutSetup[windowKey] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        let windowGeneration = state.generation
        check(state.shortcutDidStart(tokenKey: windowKey, now: noon, calendar: calendar), "general session starts before its safety threshold")
        check(state.reachedWindow(id: windowPreset.id, generation: windowGeneration, rule: "session", now: noon), "session safety threshold locks")
        check(state.usage[windowPreset.id]?.sessionLocked == true, "session lock is stored per app")
        check(state.usage[windowPreset.id]?.sessionCooldownUntil == noon.addingTimeInterval(20 * 60), "cooldown starts from the threshold")
        state.rollDay(now: noon.addingTimeInterval(21 * 60), calendar: calendar)
        check(state.usage[windowPreset.id]?.sessionLocked == false, "cooldown expiry resets the session allowance")
        check(state.usage[windowPreset.id]?.sessionSeconds == 0, "cooldown expiry clears session usage")
        check(state.reachedWindow(id: windowPreset.id, generation: windowGeneration, rule: "hourly", now: noon), "hourly threshold locks without an automation")
        check(state.usage[windowPreset.id]?.hourlyLocked == true, "hourly lock is stored per app")

        var scheduledPreset = first
        scheduledPreset.scheduleEnabled = true
        scheduledPreset.scheduleWeekday = 4
        scheduledPreset.scheduleStartMinute = 9 * 60
        scheduledPreset.scheduleEndMinute = 12 * 60
        var scheduledState = ScrollLockState()
        scheduledState.presets = [scheduledPreset]
        scheduledState.monitoring = true
        let scheduledMorning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10))!
        scheduledState.rollDay(now: scheduledMorning, calendar: calendar)
        check(scheduledState.scheduledLocked == [scheduledPreset.id], "scheduled block locks the app during its weekly window")
        check(scheduledState.isLocked(scheduledPreset.id), "scheduled block participates in shield decisions")
        scheduledState.rollDay(now: calendar.date(byAdding: .hour, value: 2, to: scheduledMorning)!, calendar: calendar)
        check(scheduledState.scheduledLocked.isEmpty, "scheduled block releases the app at its end time")
        let scheduledDecoded = try JSONDecoder().decode(ScrollLockState.self, from: JSONEncoder().encode(scheduledState))
        check(scheduledDecoded.presets == scheduledState.presets, "scheduled settings persist")
        var schoolSchedule = ScrollLockSchedule(name: "School Schedule", weekdays: Set([2, 3, 4, 5, 6]), startMinute: 9 * 60, endMinute: 15 * 60 + 30)
        schoolSchedule.rules = [
            ScheduleAppRule(appID: first.id, block: true),
            ScheduleAppRule(appID: second.id, token: second.token, name: second.name, totalEnabled: true, totalMinutes: 20, sessionEnabled: true, sessionMinutes: 15, cooldownMinutes: 20, hourlyEnabled: true, hourlyMinutes: 15)
        ]
        var legacyScheduleState = ScrollLockState()
        legacyScheduleState.presets = [first, second]
        legacyScheduleState.schedules = [schoolSchedule]
        legacyScheduleState.monitoring = true
        try legacyScheduleState.validateSchedules([schoolSchedule], apps: [first, second])
        check(true, "unchanged scheduled session without setup no longer rejects unrelated saves")
        var renamedSchedule = schoolSchedule
        renamedSchedule.name = "Renamed"
        try legacyScheduleState.validateSchedules([renamedSchedule], apps: [first, second])
        check(true, "schedule rename saves despite unchanged legacy session")
        var changedScheduleSession = schoolSchedule
        changedScheduleSession.rules[1].sessionMinutes = 10
        rejected("changed scheduled session still requires Shortcuts") {
            try legacyScheduleState.validateSchedules([changedScheduleSession], apps: [first, second])
        }
        var changedScheduleToken = schoolSchedule
        changedScheduleToken.rules[1].token = Data([9])
        rejected("replacing scheduled app cannot inherit missing setup exemption") {
            try legacyScheduleState.validateSchedules([changedScheduleToken], apps: [first, second])
        }
        var disabledScheduleSession = schoolSchedule
        disabledScheduleSession.rules[1].sessionEnabled = false
        try legacyScheduleState.validateSchedules([disabledScheduleSession], apps: [first, second])
        check(true, "legacy scheduled session can be switched off without setup")

        var shortSessionSchedule = schoolSchedule
        shortSessionSchedule.endMinute = shortSessionSchedule.startMinute + 10
        var shortScheduleState = ScrollLockState()
        shortScheduleState.shortcutSetup[ScrollLockState.shortcutKey(for: second.token)] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        try shortScheduleState.validateSchedules([shortSessionSchedule], apps: [first, second])
        check(true, "short schedule session window is accepted because Shortcuts handle its timing")
        var oneMinuteSchedule = shortSessionSchedule
        oneMinuteSchedule.rules[1].sessionMinutes = 1
        oneMinuteSchedule.rules[1].cooldownMinutes = 1
        try shortScheduleState.validateSchedules([oneMinuteSchedule], apps: [first, second])
        check(true, "one-minute scheduled session and cooldown are accepted")
        var invalidScheduleCooldown = oneMinuteSchedule
        invalidScheduleCooldown.rules[1].cooldownMinutes = 0
        rejected("zero scheduled cooldown rejected") {
            try shortScheduleState.validateSchedules([invalidScheduleCooldown], apps: [first, second])
        }
        var schoolState = ScrollLockState()
        schoolState.presets = [first, second]
        schoolState.schedules = [schoolSchedule]
        schoolState.monitoring = true
        schoolState.shortcutSetup[ScrollLockState.shortcutKey(for: second.token)] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        try schoolState.validateSchedules(schoolState.schedules, apps: schoolState.presets)
        schoolState.rollDay(now: scheduledMorning, calendar: calendar)
        check(schoolState.scheduledLocked.contains(first.id), "schedule block locks the selected app")
        check(!schoolState.scheduledLocked.contains(second.id), "schedule usage limit does not lock before use")
        let schoolKey = ScrollLockState.scheduleKey(scheduleID: schoolSchedule.id, appID: second.id)
        check(schoolState.scheduleUsage[schoolKey]?.sessionResetAt == nil, "schedule session reset window waits for the Start Shortcut")
        check(schoolState.shortcutDidStart(tokenKey: ScrollLockState.shortcutKey(for: second.token), now: scheduledMorning, calendar: calendar), "schedule session starts from the same Start Shortcut")
        check(schoolState.scheduleUsage[schoolKey]?.sessionResetAt == scheduledMorning.addingTimeInterval(15 * 60), "schedule session reset window starts from the Start Shortcut")
        check(schoolState.reachedSchedule(scheduleID: schoolSchedule.id, appID: second.id, rule: "total", generation: schoolState.generation, now: scheduledMorning), "schedule threshold locks without an automation")
        check(schoolState.scheduleUsage[schoolKey]?.totalLocked == true, "schedule threshold state is persisted")
        schoolState.scheduleUsage[schoolKey]?.totalLocked = false
        check(schoolState.reachedSchedule(scheduleID: schoolSchedule.id, appID: second.id, rule: "session", generation: schoolState.generation, now: scheduledMorning), "schedule session threshold locks without an automation")
        check(schoolState.scheduleUsage[schoolKey]?.sessionLocked == true, "schedule session lock is stored per app")
        check(schoolState.scheduleUsage[schoolKey]?.sessionCooldownUntil == scheduledMorning.addingTimeInterval(20 * 60), "schedule session cooldown starts from the threshold")
        schoolState.rollDay(now: scheduledMorning.addingTimeInterval(21 * 60), calendar: calendar)
        check(schoolState.scheduleUsage[schoolKey]?.sessionLocked == false, "schedule session cooldown expiry resets the allowance")

        var boundarySchedule = ScrollLockSchedule(name: "Boundary Schedule", weekdays: Set([4]), startMinute: 10 * 60, endMinute: 11 * 60)
        boundarySchedule.rules = [
            ScheduleAppRule(appID: second.id, token: second.token, name: second.name, sessionEnabled: true, sessionMinutes: 1, cooldownMinutes: 1)
        ]
        var boundaryState = ScrollLockState()
        boundaryState.presets = [second]
        boundaryState.schedules = [boundarySchedule]
        boundaryState.monitoring = true
        boundaryState.shortcutSetup[ScrollLockState.shortcutKey(for: second.token)] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        let boundaryStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10))!
        let boundaryEnd = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 11))!
        check(boundaryState.activeInterval(for: boundarySchedule, now: boundaryStart, calendar: calendar)?.start == boundaryStart, "schedule includes its exact start boundary")
        check(boundaryState.activeInterval(for: boundarySchedule, now: boundaryEnd, calendar: calendar) == nil, "schedule excludes its exact end boundary")
        check(boundaryState.activeInterval(for: boundarySchedule, now: boundaryEnd.addingTimeInterval(1), calendar: calendar) == nil, "schedule remains inactive after its end boundary")
        check(boundaryState.activeInterval(for: boundarySchedule, now: boundaryStart, calendar: calendar) != nil, "selected weekday activates the schedule")
        let thursday = calendar.date(byAdding: .day, value: 1, to: boundaryStart)!
        check(boundaryState.activeInterval(for: boundarySchedule, now: thursday, calendar: calendar) == nil, "unselected weekday does not activate the schedule")
        boundaryState.rollDay(now: boundaryEnd.addingTimeInterval(-60), calendar: calendar)
        let boundaryKey = ScrollLockState.scheduleKey(scheduleID: boundarySchedule.id, appID: second.id)
        check(boundaryState.shortcutDidStart(tokenKey: ScrollLockState.shortcutKey(for: second.token), now: boundaryEnd.addingTimeInterval(-60), calendar: calendar), "scheduled boundary session starts before the end")
        check(boundaryState.scheduleUsage[boundaryKey]?.sessionActiveSince != nil, "scheduled boundary session stores its active start")
        check(boundaryState.shortcutDidEnd(tokenKey: ScrollLockState.shortcutKey(for: second.token), now: boundaryEnd.addingTimeInterval(30), calendar: calendar), "scheduled End Shortcut finalizes after the schedule ends")
        check(boundaryState.scheduleUsage[boundaryKey]?.sessionLocked == true, "scheduled session counts only through the schedule end")
        check(boundaryState.scheduledLocked.contains(second.id) == false, "scheduled session lock does not leak past its schedule")

        var overlapSchedule = ScrollLockSchedule(name: "Overlap Schedule", weekdays: Set([4]), startMinute: 10 * 60, endMinute: 12 * 60)
        overlapSchedule.rules = [
            ScheduleAppRule(appID: first.id, token: first.token, name: first.name, sessionEnabled: true, sessionMinutes: 1, cooldownMinutes: 1)
        ]
        var overlapPreset = first
        overlapPreset.sessionEnabled = true
        overlapPreset.sessionMinutes = 1
        overlapPreset.cooldownMinutes = 1
        var overlapState = ScrollLockState()
        overlapState.presets = [overlapPreset]
        overlapState.schedules = [overlapSchedule]
        overlapState.monitoring = true
        let overlapKey = ScrollLockState.shortcutKey(for: first.token)
        overlapState.shortcutSetup[overlapKey] = ShortcutSetupState(startSeenAt: noon, endSeenAt: noon)
        check(overlapState.shortcutDidStart(tokenKey: overlapKey, now: boundaryStart, calendar: calendar), "same Shortcut starts general and scheduled sessions together")
        let overlapUsageKey = ScrollLockState.scheduleKey(scheduleID: overlapSchedule.id, appID: first.id)
        check(overlapState.usage[overlapPreset.id]?.sessionActiveSince == boundaryStart, "general session starts for the shared app")
        check(overlapState.scheduleUsage[overlapUsageKey]?.sessionActiveSince == boundaryStart, "scheduled session starts for the shared app")
        check(overlapState.shortcutDidEnd(tokenKey: overlapKey, now: boundaryStart.addingTimeInterval(60), calendar: calendar), "same Shortcut ends general and scheduled sessions together")
        check(overlapState.usage[overlapPreset.id]?.sessionLocked == true, "general session locks in the overlap")
        check(overlapState.scheduleUsage[overlapUsageKey]?.sessionLocked == true, "scheduled session locks in the overlap")
        check(overlapState.isLocked(overlapPreset.id), "overlapping restrictions produce one final locked decision")
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ScrollLockState.self, from: encoded)
        check(decoded.usage[windowPreset.id]?.hourlyLocked == true && decoded.presets == state.presets, "usage and presets persist")
        check(decoded.shortcutSetup == state.shortcutSetup, "Shortcut setup confirmations persist")
        var aliasState = ScrollLockState()
        var aliasPreset = first
        aliasPreset.shortcutAlias = "Focus video"
        aliasState.presets = [aliasPreset]
        check(aliasPreset.shortcutName == "Focus video", "Shortcut alias overrides the system app name")
        try aliasState.validate([aliasPreset])
        let aliasRoundTrip = try JSONDecoder().decode(
            ScrollLockState.self,
            from: JSONEncoder().encode(aliasState)
        )
        check(aliasRoundTrip.presets.first?.shortcutAlias == "Focus video", "Shortcut alias persists in shared state")
        var duplicateAlias = second
        duplicateAlias.shortcutAlias = "Focus video"
        rejected("duplicate Shortcut aliases are rejected") {
            try aliasState.validate([aliasPreset, duplicateAlias])
        }
        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyObject.removeValue(forKey: "shortcutSetup")
        if var usageObject = legacyObject["usage"] as? [String: Any] {
            for key in usageObject.keys {
                if var entry = usageObject[key] as? [String: Any] {
                    entry.removeValue(forKey: "sessionActiveSince")
                    usageObject[key] = entry
                }
            }
            legacyObject["usage"] = usageObject
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(ScrollLockState.self, from: legacyData)
        check(legacyDecoded.shortcutSetup.isEmpty, "older state without Shortcut setup decodes safely")
        check(legacyDecoded.usage.values.allSatisfy { $0.sessionActiveSince == nil }, "older usage without active session timestamps decodes safely")
        let dstStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let dstNext = calendar.date(byAdding: .day, value: 1, to: dstStart)!
        check(dstNext.timeIntervalSince(dstStart) == 23 * 3600, "test exercises DST")
        var session = UsageState(day: dstStart, seconds: 90)
        session.rollDay(now: dstNext.addingTimeInterval(90), calendar: calendar)
        check(session.used(at: dstNext.addingTimeInterval(90)) == 0, "DST rollover resets aggregate usage at calendar midnight")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scrolllock-state-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ScrollLockStorage.transaction(directory: directory) { $0 = state }
        check(tryRead(directory).usage[windowPreset.id]?.hourlyLocked == true, "file reload preserves totals")
        var workers: [Process] = []
        for _ in 0..<8 {
            let worker = Process()
            worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            worker.arguments = ["--worker", directory.path]
            try worker.run()
            workers.append(worker)
        }
        for worker in workers { worker.waitUntilExit(); check(worker.terminationStatus == 0, "worker succeeded") }
        check(tryRead(directory).history.count == state.history.count + 400, "concurrent processes lose no history")
        try ScrollLockStorage.transaction(directory: directory) { state in
            for _ in 0..<1100 { state.record("retention") }
        }
        check(tryRead(directory).history.count == 1000, "bounded history retains 1000 events")
        let before = try Data(contentsOf: directory.appendingPathComponent("scrolllock-state.json"))
        rejected("failed transaction throws") {
            try ScrollLockStorage.transaction(directory: directory) { state in
                state.presets.removeAll()
                throw ScrollLockError.message("fixture failure")
            }
        }
        let after = try Data(contentsOf: directory.appendingPathComponent("scrolllock-state.json"))
        check(before == after, "failed transaction preserves last good state")
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("scrolllock-state.json"))
        rejected("corrupt state is not silently reset") { try ScrollLockStorage.transaction(directory: directory) { _ in } }
        var clearedState = overlapState
        let selectedIDs = clearedState.presets.map(\.id)
        let selectedTokens = clearedState.presets.map(\.token)
        let savedScheduleIDs = clearedState.schedules.map(\.id)
        let savedRuleIDs = clearedState.schedules.flatMap { $0.rules.map(\.id) }
        let priorGeneration = clearedState.generation
        clearedState.disableAllLimits(now: noon)
        check(clearedState.presets.allSatisfy { !$0.enabled && !$0.sessionEnabled && !$0.hourlyEnabled && !$0.scheduleEnabled },
              "explicit reset disables every existing app limit")
        check(clearedState.schedules.allSatisfy { !$0.enabled && $0.rules.allSatisfy { !$0.block && !$0.totalEnabled && !$0.sessionEnabled && !$0.hourlyEnabled } },
              "explicit reset disables every existing schedule limit")
        check(clearedState.presets.map(\.id) == selectedIDs && clearedState.presets.map(\.token) == selectedTokens
              && clearedState.schedules.map(\.id) == savedScheduleIDs && clearedState.schedules.flatMap { $0.rules.map(\.id) } == savedRuleIDs,
              "turning off limits preserves all selected apps and schedules")
        check(!clearedState.monitoring && clearedState.generation != priorGeneration && clearedState.locked.isEmpty && clearedState.scheduledLocked.isEmpty,
              "turning off limits invalidates callbacks and releases restrictions")
        clearedState.rollDay(now: noon, calendar: calendar)
        check(clearedState.presets.allSatisfy { !clearedState.isLocked($0.id) }, "refresh cannot restore disabled limits")

        let autosaveDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("scrolllock-autosave-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: autosaveDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: autosaveDirectory) }
        var legacyConfiguration = legacyScheduleState
        legacyConfiguration.presets = [staleSessionPreset, second]
        for monitoring in [false, true] {
            for operation in ["add", "edit", "remove", "removeAll", "scheduleEdit"] {
                var proposed = legacyConfiguration.presets
                var schedules = legacyConfiguration.schedules
                switch operation {
                case "add": proposed.append(AppPreset(token: Data([9]), name: "Another app"))
                case "edit": proposed[1].minutes = 37
                case "remove": proposed.removeLast()
                case "removeAll":
                    proposed.removeAll()
                    // Model the migration that hydrates legacy ID-only rules.
                    schedules[0].rules[0].token = first.token
                default: schedules[0].name = "Renamed schedule"
                }
                try ScrollLockStorage.transaction(directory: autosaveDirectory) { saved in
                    saved = legacyConfiguration
                    saved.monitoring = monitoring
                    try saved.validate(proposed)
                    try saved.validateSchedules(schedules, apps: proposed)
                    saved.presets = proposed
                    saved.schedules = schedules
                }
                let restored = tryRead(autosaveDirectory)
                check(restored.presets == proposed && restored.schedules == schedules,
                      "autosave \(operation) survives disk reload, monitoring=\(monitoring)")
            }
        }
        print("PASS: \(checks) state/accounting/persistence checks. Fixtures: \(directory.path)")
    }

    static func tryRead(_ directory: URL) -> ScrollLockState {
        try! ScrollLockStorage.transaction(directory: directory) { $0 }
    }
}
