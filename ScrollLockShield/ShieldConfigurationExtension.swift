import FamilyControls
import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        let appName = application.localizedDisplayName ?? "This app"
        let message: String

        if let token = application.token {
            message = ShieldRestrictionSummary.message(for: token, appName: appName, now: Date())
        } else {
            message = "\(appName) is restricted by an active ScrollLock limit."
        }

        return ShieldConfiguration(
            icon: UIImage(systemName: "lock.shield.fill"),
            title: ShieldConfiguration.Label(text: "ScrollLock", color: .label),
            subtitle: ShieldConfiguration.Label(text: message, color: .secondaryLabel)
        )
    }
}

private enum ShieldRestrictionSummary {
    static func message(for token: ApplicationToken, appName: String, now: Date) -> String {
        do {
            let state = try ScrollLockStorage.transaction { stored -> ScrollLockState in
                var snapshot = stored
                snapshot.rollDay(now: now, calendar: .current)
                return snapshot
            }

            guard !state.emergency else {
                return "\(appName) is restricted by ScrollLock."
            }

            let reasons = presetReasons(in: state, matching: token, now: now)
                + scheduleReasons(in: state, matching: token, now: now)
            guard !reasons.isEmpty else {
                return "\(appName) is restricted by an active ScrollLock rule."
            }
            return "\(appName) is restricted. " + reasons.joined(separator: " ")
        } catch {
            return "\(appName) is restricted by ScrollLock. Check your limits in the ScrollLock app."
        }
    }

    private static func presetReasons(
        in state: ScrollLockState,
        matching token: ApplicationToken,
        now: Date
    ) -> [String] {
        state.presets.compactMap { preset in
            guard tokenMatches(preset.token, token) else { return nil }
            let usage = state.usage[preset.id]
            var reasons: [String] = []

            if state.locked.contains(preset.id) {
                reasons.append("Daily limit reached (\(duration(preset.minutes))). Resets at midnight.")
            }
            if let usage,
               usage.sessionLocked,
               let cooldownUntil = usage.sessionCooldownUntil,
               cooldownUntil > now {
                reasons.append(sessionReason(
                    allowed: preset.sessionMinutes,
                    cooldown: preset.cooldownMinutes,
                    unlockAt: cooldownUntil,
                    now: now
                ))
            }
            if usage?.hourlyLocked == true {
                let resetAt = Calendar.current.dateInterval(of: .hour, for: now)?.end
                    ?? now.addingTimeInterval(3600)
                reasons.append("Hourly limit reached (\(duration(preset.hourlyMinutes))). Resets at \(dateTime(resetAt, now: now)).")
            }
            if state.scheduledLocked.contains(preset.id),
               state.isWithinSchedule(for: preset, now: now) {
                let endMinute = preset.scheduleEndMinute
                let end = clockText(endMinute)
                reasons.append("Scheduled block is active until \(end).")
            }

            return reasons.isEmpty ? nil : reasons.joined(separator: " ")
        }
    }

    private static func scheduleReasons(
        in state: ScrollLockState,
        matching token: ApplicationToken,
        now: Date
    ) -> [String] {
        state.schedules.flatMap { schedule -> [String] in
            guard let interval = state.activeInterval(for: schedule, now: now) else { return [] }

            return schedule.rules.compactMap { rule in
                guard state.scheduledLocked.contains(rule.appID),
                      let data = state.token(for: rule),
                      tokenMatches(data, token) else { return nil }

                let key = ScrollLockState.scheduleKey(scheduleID: schedule.id, appID: rule.appID)
                let usage = state.scheduleUsage[key]
                let intervalEnd = dateTime(interval.end, now: now)
                var reasons: [String] = []

                if rule.block {
                    reasons.append("Blocked during \(schedule.name) until \(intervalEnd).")
                }
                if usage?.totalLocked == true {
                    reasons.append("\(schedule.name) limit reached (\(duration(rule.totalMinutes))). Access returns at \(intervalEnd).")
                }
                if let usage,
                   usage.sessionLocked,
                   let cooldownUntil = usage.sessionCooldownUntil,
                   cooldownUntil > now {
                    reasons.append(sessionReason(
                        allowed: rule.sessionMinutes,
                        cooldown: rule.cooldownMinutes,
                        unlockAt: min(cooldownUntil, interval.end),
                        now: now
                    ))
                }
                if usage?.hourlyLocked == true {
                    let nextHour = Calendar.current.dateInterval(of: .hour, for: now)?.end
                        ?? now.addingTimeInterval(3600)
                    let resetAt = min(nextHour, interval.end)
                    reasons.append("\(schedule.name) hourly limit reached (\(duration(rule.hourlyMinutes))). Resets at \(dateTime(resetAt, now: now)).")
                }

                if reasons.isEmpty {
                    return "\(schedule.name) restriction is active until \(intervalEnd)."
                }
                return reasons.joined(separator: " ")
            }
        }
    }

    private static func tokenMatches(_ encodedToken: Data, _ token: ApplicationToken) -> Bool {
        guard let storedToken = try? JSONDecoder().decode(ApplicationToken.self, from: encodedToken) else {
            return false
        }
        return storedToken == token
    }

    private static func sessionReason(allowed: Int, cooldown: Int, unlockAt: Date, now: Date) -> String {
        "Per-session limit reached after \(duration(allowed)). Cooldown: \(duration(cooldown)); access returns at \(dateTime(unlockAt, now: now))."
    }

    private static func duration(_ minutes: Int) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
        }
        return "\(minutes) min"
    }

    private static func dateTime(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func clockText(_ minute: Int) -> String {
        if minute == 1440 { return "12:00 AM" }
        return ScrollLockState.clockText(minute)
    }
}
