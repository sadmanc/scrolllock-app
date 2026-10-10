import SwiftUI
import Combine
import FamilyControls
import DeviceActivity
import ManagedSettings

private extension DeviceActivityReport.Context {
    static let scrollLockSummary = Self("ScrollLockSummary")
}

@MainActor
final class LimitStore: ObservableObject {
    @Published var state = ScrollLockState()
    @Published var drafts: [AppPreset] = []
    @Published var scheduleDrafts: [ScrollLockSchedule] = []
    @Published var selection = FamilyActivitySelection()
    @Published var isPickerPresented = false
    @Published var scheduleSelection = FamilyActivitySelection()
    @Published var isSchedulePickerPresented = false
    @Published var errorMessage: String?
    @Published var monitorInfo = ""
    @Published var authorization = "Not requested"
    @Published private(set) var authorizationGranted = false
    @Published private(set) var authorizationNeedsAttention = true
    @Published var ready = false
    @Published private(set) var isApplying = false

    private var autoApplyTask: Task<Void, Never>?
    private var schedulePickerID: String?
    private let enforcementQueue = DispatchQueue(label: "com.example.scrolllock.configuration", qos: .userInitiated)
    var hasChanges: Bool { drafts != state.presets || scheduleDrafts != state.schedules }

    func binding(for presetID: String) -> Binding<AppPreset> {
        Binding(
            get: {
                guard let preset = self.drafts.first(where: { $0.id == presetID }) else {
                    return AppPreset(token: Data(), name: "Unavailable app")
                }
                return preset
            },
            set: { updated in
                guard let index = self.drafts.firstIndex(where: { $0.id == presetID }) else { return }
                self.drafts[index] = updated
                self.scheduleAutoApply()
            }
        )
    }

    init() {
        do {
            try ScrollLockMigration.run()
            refresh()
            drafts = state.presets
            scheduleDrafts = state.schedules
            hydrateScheduleRules()
            ready = true
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        guard errorMessage != message else { return }
        errorMessage = message
        try? ScrollLockStorage.transaction { $0.record("A local ScrollLock error occurred. Details are shown on screen.") }
    }

    func showError(_ message: String) {
        report(ScrollLockError.message(message))
    }

    func refresh() {
        do {
            state = try ScrollLockEnforcement.refresh()
            refreshAuthorizationAndMonitorInfo()
        } catch { report(error) }
    }

    private func refreshAuthorizationAndMonitorInfo() {
        let center = DeviceActivityCenter()
        let active = center.activities.contains(ScrollLockEnforcement.activity)
        let authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        let isAuthorized: Bool
        if #available(iOS 26.4, *) {
            isAuthorized = authorizationStatus == .approved || authorizationStatus == .approvedWithDataAccess
        } else {
            isAuthorized = authorizationStatus == .approved
        }
        authorizationGranted = isAuthorized
        authorizationNeedsAttention = !isAuthorized
        if #available(iOS 26.4, *), authorizationStatus == .approvedWithDataAccess {
            authorization = "Allowed with app-name access"
        } else {
            switch authorizationStatus {
                case .approved: authorization = "Allowed (token-only app names)"
                case .denied: authorization = "Denied. Allow access in Settings to enforce limits."
            default: authorization = "Not requested"
            }
        }
        let windowRules = state.presets.filter { $0.sessionEnabled || $0.hourlyEnabled || $0.scheduleEnabled }.count
        if state.emergency {
            monitorInfo = "Emergency recovery is active. Limits are paused until you apply settings again."
        } else if state.monitoring && active {
            monitorInfo = "Daily monitor registered for \(state.presets.filter(\.enabled).count) app(s). \(windowRules) app(s) also use hourly, per-session, or scheduled windows. \(state.schedules.filter(\.enabled).count) named schedule(s) configured. Daily reset: local midnight."
        } else if state.presets.contains(where: { $0.enabled || $0.sessionEnabled || $0.hourlyEnabled }) || state.schedules.contains(where: { $0.enabled && !$0.rules.isEmpty }) {
            monitorInfo = "Limits are not registered yet. Check the error below."
        } else {
            monitorInfo = "All limits are off."
        }
    }

    func addSchedule() {
        let names = Set(scheduleDrafts.map { ScrollLockState.normalized($0.name) })
        var name = "New Schedule"
        var suffix = 2
        while names.contains(ScrollLockState.normalized(name)) {
            name = "New Schedule \(suffix)"
            suffix += 1
        }
        scheduleDrafts.append(ScrollLockSchedule(name: name))
        flushPendingChanges()
    }

    func chooseApps() {
        do {
            selection = FamilyActivitySelection()
            selection.applicationTokens = try Set(drafts.map(ScrollLockEnforcement.token))
            isPickerPresented = true
        } catch { report(error) }
    }

    func chooseApps(for scheduleID: String) {
        guard let schedule = scheduleDrafts.first(where: { $0.id == scheduleID }) else { return }
        schedulePickerID = scheduleID
        scheduleSelection = FamilyActivitySelection()
        scheduleSelection.applicationTokens = Set(schedule.rules.compactMap { rule in
            guard let data = rule.token else { return nil }
            return try? JSONDecoder().decode(ApplicationToken.self, from: data)
        })
        isSchedulePickerPresented = true
    }

    private func hydrateScheduleRules() {
        let byID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
        scheduleDrafts = scheduleDrafts.map { schedule in
            var copy = schedule
            copy.rules = copy.rules.map { rule in
                guard rule.token == nil, let preset = byID[rule.appID] else { return rule }
                var updated = rule
                updated.token = preset.token
                updated.name = preset.name
                return updated
            }
            return copy
        }
    }

    func acceptSelection() {
        do {
            guard selection.categoryTokens.isEmpty, selection.webDomainTokens.isEmpty else {
                throw ScrollLockError.message("Select individual apps only. Category and website limits are outside this version.")
            }
            let previous = drafts
            let selectedApplications = selection.applications
            var proposed: [AppPreset] = []
            // Reserve retained names before assigning fallback names to new apps.
            // Set iteration order must not decide whether adding an app succeeds.
            var usedNames = Set(previous.filter { preset in
                guard let token = try? ScrollLockEnforcement.token(preset) else { return false }
                return selection.applicationTokens.contains(token)
            }.map { ScrollLockState.normalized($0.name) })
            for token in selection.applicationTokens {
                if let saved = try previous.first(where: { try ScrollLockEnforcement.token($0) == token }) {
                    var preserved = saved
                    if let systemName = selectedApplications.first(where: { $0.token == token })?.localizedDisplayName
                        ?? Application(token: token).localizedDisplayName,
                       isPositionalFallback(preserved.name),
                       !state.isLocked(preserved.id), !state.settingsLock.enabled,
                       !usedNames.contains(ScrollLockState.normalized(systemName)) {
                        usedNames.remove(ScrollLockState.normalized(preserved.name))
                        preserved.name = uniqueAppName(preferred: systemName, usedNames: &usedNames)
                    }
                    proposed.append(preserved)
                } else {
                    let systemName = selectedApplications.first(where: { $0.token == token })?.localizedDisplayName
                        ?? Application(token: token).localizedDisplayName
                    let name = uniqueAppName(
                        preferred: systemName,
                        usedNames: &usedNames
                    )
                    proposed.append(AppPreset(token: try JSONEncoder().encode(token), name: name))
                }
            }
            // Recheck persisted locks; a threshold may arrive while the picker is open.
            refresh()
            try state.validate(proposed)
            drafts = proposed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // Picker changes are the boundary where the user explicitly chose
            // the complete app set. Apply immediately so removing the final
            // app cannot be lost if the app is closed before the debounce task
            // runs.
            flushPendingChanges()
        } catch { report(error) }
    }

    private func uniqueAppName(preferred: String?, usedNames: inout Set<String>) -> String {
        if let preferred {
            let normalized = ScrollLockState.normalized(preferred)
            if !normalized.isEmpty, !usedNames.contains(normalized) {
                usedNames.insert(normalized)
                return preferred
            }
        }
        var index = 1
        while usedNames.contains("selected app \(index)") {
            index += 1
        }
        let fallback = "Selected app \(index)"
        usedNames.insert(ScrollLockState.normalized(fallback))
        return fallback
    }

    func acceptScheduleSelection() {
        do {
            guard let scheduleID = schedulePickerID,
                  let scheduleIndex = scheduleDrafts.firstIndex(where: { $0.id == scheduleID }) else { return }
            guard scheduleSelection.categoryTokens.isEmpty, scheduleSelection.webDomainTokens.isEmpty else {
                throw ScrollLockError.message("Select individual apps only. Expand a category to choose its apps.")
            }
            let previous = scheduleDrafts[scheduleIndex].rules
            var proposed: [ScheduleAppRule] = []
            for token in scheduleSelection.applicationTokens {
                let encoded = try JSONEncoder().encode(token)
                if var saved = previous.first(where: { $0.token == encoded }) {
                    saved.name = Application(token: token).localizedDisplayName ?? saved.name ?? "App name unavailable"
                    proposed.append(saved)
                } else {
                    let name = Application(token: token).localizedDisplayName ?? "App name unavailable"
                    proposed.append(ScheduleAppRule(appID: UUID().uuidString, token: encoded, name: name))
                }
            }
            scheduleDrafts[scheduleIndex].rules = proposed.sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
            flushPendingChanges()
        } catch { report(error) }
    }

    private func isPositionalFallback(_ name: String) -> Bool {
        let value = ScrollLockState.normalized(name)
        if value.hasPrefix("selected app ") { return Int(value.dropFirst("selected app ".count)) != nil }
        if value.hasPrefix("app ") { return Int(value.dropFirst("app ".count)) != nil }
        return false
    }

    func scheduleAutoApply() {
        guard ready else { return }
        autoApplyTask?.cancel()
        autoApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.applyIfNeeded()
        }
    }

    private func applyIfNeeded() {
        guard hasChanges else { return }
        guard !isApplying else { return }
        apply()
    }

    func flushPendingChanges() {
        guard hasChanges else { return }
        guard !isApplying else { return }
        apply()
    }

    func apply() {
        autoApplyTask?.cancel()
        guard !isApplying else { return }
        let proposedDrafts = drafts
        let proposedSchedules = scheduleDrafts
        isApplying = true
        enforcementQueue.async { [weak self] in
            var configuredState: ScrollLockState?
            var failure: Error?
            do {
                try ScrollLockEnforcement.configure(proposedDrafts, schedules: proposedSchedules)
                configuredState = try ScrollLockEnforcement.refresh()
            } catch {
                failure = error
                configuredState = try? ScrollLockEnforcement.refresh()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isApplying = false
                if let configuredState {
                    self.state = configuredState
                    self.refreshAuthorizationAndMonitorInfo()
                }
                if let failure {
                    self.report(failure)
                    // Keep edits visible after a failed apply so the user can
                    // correct or retry them instead of losing the draft.
                } else {
                    self.errorMessage = nil
                    if self.drafts == proposedDrafts { self.drafts = self.state.presets }
                    if self.scheduleDrafts == proposedSchedules { self.scheduleDrafts = self.state.schedules }
                }
                if self.hasChanges { self.scheduleAutoApply() }
            }
        }
    }

    deinit {
        autoApplyTask?.cancel()
    }

    func authorize() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            try ScrollLockStorage.transaction { $0.record("Screen Time access granted.") }
            errorMessage = nil
            refresh()
            apply()
        } catch { report(error) }
    }

    func clearHistory() {
        do {
            try ScrollLockStorage.transaction {
                $0.history.removeAll()
                $0.record("Status history cleared by you.")
            }
            refresh()
        } catch { report(error) }
    }

    func startSettingsLock(mode: SettingsUnlockMode, countdownMinutes: Int, unlockAt: Date) {
        do {
            let minutes = min(max(countdownMinutes, 1), 1_440)
            try ScrollLockStorage.transaction { state in
                guard !state.emergency else {
                    throw ScrollLockError.message("Resume enforcement before turning on the settings lock.")
                }
                state.settingsLock = SettingsLockState(
                    enabled: true,
                    mode: mode,
                    countdownMinutes: minutes,
                    unlockAt: mode == .countdown
                        ? Date().addingTimeInterval(TimeInterval(minutes * 60))
                        : unlockAt
                )
                let unlockText = mode == .countdown
                    ? "after \(minuteDurationText(minutes)) without closing ScrollLock"
                    : "at \(unlockAt.formatted(date: .abbreviated, time: .shortened))"
                state.record("Settings lock enabled. Unlocks \(unlockText). Existing restrictions can only become stricter while locked.")
                try ScrollLockEnforcement.applyShields(state)
            }
            errorMessage = nil
            refresh()
        } catch { report(error) }
    }

    func resetCountdownUnlock() {
        guard state.settingsLock.enabled, state.settingsLock.mode == .countdown else { return }
        do {
            try ScrollLockStorage.transaction { state in
                guard state.settingsLock.enabled, state.settingsLock.mode == .countdown else { return }
                let minutes = min(max(state.settingsLock.countdownMinutes, 1), 1_440)
                state.settingsLock.unlockAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
            }
            refresh()
        } catch { report(error) }
    }

    func requestSettingsUnlock() {
        guard state.settingsLock.enabled else { return }
        guard let unlockAt = state.settingsLock.unlockAt, Date() >= unlockAt else {
            let remaining = state.settingsLock.unlockAt.map { ScrollLockState.duration(max(0, $0.timeIntervalSinceNow)) } ?? "the unlock time"
            report(ScrollLockError.message("Settings are locked. Try again in \(remaining)."))
            return
        }
        do {
            try ScrollLockStorage.transaction { state in
                state.settingsLock = SettingsLockState()
                state.record("Settings lock opened after its unlock condition was met.")
                try ScrollLockEnforcement.applyShields(state)
            }
            errorMessage = nil
            refresh()
        } catch { report(error) }
    }

    func unlockSettingsLockIfExpired(now: Date = Date()) {
        guard state.settingsLock.enabled,
              let unlockAt = state.settingsLock.unlockAt,
              now >= unlockAt else { return }
        do {
            let unlocked = try ScrollLockStorage.transaction { state -> Bool in
                guard state.settingsLock.enabled,
                      let unlockAt = state.settingsLock.unlockAt,
                      now >= unlockAt else { return false }
                state.settingsLock = SettingsLockState()
                state.record("Settings lock expired and turned off automatically.", now: now)
                try ScrollLockEnforcement.applyShields(state)
                return true
            }
            if unlocked {
                errorMessage = nil
                refresh()
            }
        } catch { report(error) }
    }

}

struct ContentView: View {
    @StateObject private var store = LimitStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmClear = false
    @State private var analyticsPeriod: AnalyticsPeriod = .today
    @State private var settingsUnlockMode: SettingsUnlockMode = .countdown
    @State private var settingsUnlockMinutes = 5
    @State private var settingsUnlockDate = Date().addingTimeInterval(60 * 60)
    @State private var selectedTab: MainTab = .limits
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private enum MainTab: Hashable {
        case limits
        case analytics
        case schedules
        case history
        case countdown
    }

    private enum AnalyticsPeriod: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "This week"

        var id: Self { self }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            limitsTab
                .tabItem { Label("Limits", systemImage: "slider.horizontal.3") }
                .tag(MainTab.limits)
            analyticsTab
                .tabItem { Label("Analytics", systemImage: "chart.bar.xaxis") }
                .tag(MainTab.analytics)
            schedulesTab
                .tabItem { Label("Schedules", systemImage: "calendar.badge.clock") }
                .tag(MainTab.schedules)
            historyTab
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(MainTab.history)
            if store.state.settingsLock.enabled && store.state.settingsLock.mode == .countdown {
                countdownTab
                    .tabItem { Label("Countdown", systemImage: "timer") }
                    .tag(MainTab.countdown)
            }
        }
        .onAppear {
            store.refresh()
            store.unlockSettingsLockIfExpired()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refresh()
                store.unlockSettingsLockIfExpired()
            } else {
                // Persist edits before the process is backgrounded or
                // force-quit. This is the last chance for a debounced form
                // change to reach the shared store.
                store.flushPendingChanges()
                if phase == .background {
                    store.resetCountdownUnlock()
                }
            }
        }
        .onReceive(timer) { _ in
            guard scenePhase == .active else { return }
            store.unlockSettingsLockIfExpired()
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            if oldTab == .countdown, newTab != .countdown {
                store.resetCountdownUnlock()
            }
        }
        .onChange(of: store.state.settingsLock.enabled) { _, enabled in
            if !enabled, selectedTab == .countdown {
                selectedTab = .limits
            }
        }
        .onChange(of: store.drafts) { _, _ in store.scheduleAutoApply() }
        .onChange(of: store.scheduleDrafts) { _, _ in store.scheduleAutoApply() }
        .sheet(isPresented: $store.isPickerPresented) {
            FamilyActivityPickerSheet(
                selection: $store.selection, title: "Choose Apps", errorMessage: store.errorMessage,
                onSelectionChange: { store.acceptSelection() }
            )
        }
        .sheet(isPresented: $store.isSchedulePickerPresented) {
            FamilyActivityPickerSheet(
                selection: $store.scheduleSelection, title: "Choose Schedule Apps", errorMessage: store.errorMessage,
                onSelectionChange: { store.acceptScheduleSelection() }
            )
        }
        .confirmationDialog("Delete the saved status history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { store.clearHistory() }
        }
    }

    private var countdownTab: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.tint)

                Text("Settings lock is active")
                    .font(.title2.weight(.semibold))

                if let unlockAt = store.state.settingsLock.unlockAt {
                    Text(unlockAt, style: .timer)
                        .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())

                    Text("Settings unlock automatically when the countdown reaches zero.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Text("Unlocks at \(unlockAt.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The countdown is unavailable. Close this tab to restart it.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Button("Close countdown") {
                    selectedTab = .limits
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .navigationTitle("Countdown")
        }
    }

    private var limitsTab: some View {
        NavigationStack {
            List {
                Section("Screen Time") {
                    LabeledContent {
                        Text(store.authorization)
                            .foregroundStyle(store.authorizationGranted ? .green : .orange)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Label("Access", systemImage: "hourglass")
                    }
                    Text("Privacy: ScrollLock has no account, ads, analytics SDK, or tracking. It stores selected app tokens and names, limits, schedules, and recent status history in protected on-device shared storage so its extensions can enforce your settings. It does not send this information to ScrollLock or a server. Analytics uses Apple's report for only the apps you selected and displays it on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if store.authorizationNeedsAttention {
                        Text("ScrollLock opens Apple's Screen Time permission prompt only after you tap this button. You can revoke access later in iPhone Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Allow Screen Time access") { Task { await store.authorize() } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Label("Ready to manage selected apps", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                        Text("App-name access is optional. Token-only access is enough to save limits and manage app selections.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Apple controls this permission. ScrollLock can request access, but it cannot turn Screen Time app and website activity on or off for you.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if store.state.presets.contains(where: { ScrollLockState.isPlaceholderAppName($0.name) }) {
                        Label("Some app names are placeholders because Apple provided token-only access. Limits still work. Rechoose an app after optional app-name access is available, or set a Shortcut alias.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if store.drafts.isEmpty {
                        Text("Shortcuts lists currently selected apps so you can set up their automations before enabling per-session limits. Removing an app here does not delete old personal automations from Apple Shortcuts. Delete those old ScrollLock automations there if they still show Selected app 1/2.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Apps") {
                    Button {
                        store.chooseApps()
                    } label: {
                        Label("Choose Apps", systemImage: "plus.circle")
                    }
                    .disabled(!store.ready)

                    if store.drafts.isEmpty {
                        Text("Select individual apps to configure their limits.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(store.drafts) { item in
                        NavigationLink {
                            AppSettingsView(
                                store: store,
                                preset: store.binding(for: item.id),
                            )
                        } label: {
                            appListRow(item)
                        }
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { store.state.settingsLock.enabled },
                        set: { enabled in
                            if enabled {
                                store.startSettingsLock(
                                    mode: settingsUnlockMode,
                                    countdownMinutes: settingsUnlockMinutes,
                                    unlockAt: settingsUnlockDate
                                )
                            } else {
                                store.requestSettingsUnlock()
                            }
                        }
                    )) {
                        Label("Lock settings", systemImage: "lock.shield")
                    }

                    if !store.state.settingsLock.enabled {
                        Picker("Unlock method", selection: $settingsUnlockMode) {
                            Text("Countdown").tag(SettingsUnlockMode.countdown)
                            Text("Specific time").tag(SettingsUnlockMode.scheduled)
                        }
                        if settingsUnlockMode == .countdown {
                            Stepper(value: $settingsUnlockMinutes, in: 1...1_440) {
                                LabeledContent("Countdown", value: minuteDurationText(settingsUnlockMinutes))
                            }
                        } else {
                            DatePicker("Unlock at", selection: $settingsUnlockDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        }
                    } else {
                        let unlockText = store.state.settingsLock.unlockAt.map {
                            $0.formatted(date: .abbreviated, time: .shortened)
                        } ?? "not scheduled"
                        LabeledContent("Unlocks", value: unlockText)
                        Text("While locked, apps and schedules cannot be removed or relaxed. You can only make restrictions stricter. The lock also prevents removal of apps on this iPhone, not just ScrollLock.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("The Countdown tab shows the timer. Closing that tab or sending ScrollLock to the background restarts it. When it reaches zero, the settings lock turns off automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Settings lock")
                } footer: {
                    Text("This is a development safety feature. The Mac kill switch clears the lock during recovery.")
                }

                if store.state.emergency {
                    Section {
                        Button("Resume with these settings") { store.apply() }
                            .disabled(!store.ready || store.drafts.isEmpty || store.isApplying)
                    } footer: {
                        Text("The kill switch pauses enforcement until you explicitly resume.")
                    }
                }

                Section("Status") {
                    Text(store.monitorInfo)
                        .foregroundStyle(.secondary)
                    if let last = store.state.history.last {
                        LabeledContent("Last change", value: last.timestamp.formatted(date: .abbreviated, time: .standard))
                    }
                    Button("Refresh status") { store.refresh() }
                }

#if DEBUG
                Section("Development") {
                    Text("Development builds can retain a local diagnostic trace. Release builds omit it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
#endif
            }
            .listStyle(.insetGrouped)
            .navigationTitle("ScrollLock")
        }
    }

    private var historyTab: some View {
        NavigationStack {
            List {
                Section {
                    Text("Latest 1,000 local events, newest first. Clear this history any time. Times include seconds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if store.state.history.isEmpty {
                    Section {
                        Text("No status changes recorded yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Events") {
                        ForEach(store.state.history.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.message)
                                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("Clear status history", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("History stays on this iPhone in ScrollLock's protected storage. The development trace is not included in Release builds.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Status history")
        }
    }

    private var analyticsTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Screen Time")
                            .font(.title3.weight(.semibold))
                        Text("These totals come from Apple’s Device Activity report. Daily and hourly limits use this same system tracking and do not need Shortcuts.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Period", selection: $analyticsPeriod) {
                        ForEach(AnalyticsPeriod.allCases) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)

                    if selectedApplicationTokens.isEmpty {
                        ContentUnavailableView(
                            "Select apps to view their report",
                            systemImage: "chart.bar.xaxis",
                            description: Text("Analytics is limited to apps you explicitly select in ScrollLock.")
                        )
                    } else if #available(iOS 26.4, *) {
                        DeviceActivityReport(.scrollLockSummary, filter: analyticsFilter)
                            .frame(minHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(.quaternary, lineWidth: 1)
                            }
                    } else {
                        ContentUnavailableView(
                            "Screen Time report unavailable",
                            systemImage: "hourglass",
                            description: Text("This report requires the current iOS Device Activity data API.")
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("What you can see", systemImage: "info.circle")
                            .font(.headline)
                        Text("For selected apps only, Apple's Device Activity report displays screen time, pickups, and notifications on this iPhone. ScrollLock does not save the full report. Per-session limits use the separate Start and End app automations because Device Activity does not provide raw app-open and app-close timestamps to ScrollLock.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                }
                .padding(16)
            }
            .navigationTitle("Analytics")
        }
    }

    private var analyticsFilter: DeviceActivityFilter {
        let calendar = Calendar.current
        let now = Date()
        switch analyticsPeriod {
        case .today:
            return DeviceActivityFilter(
                segment: .daily(during: DateInterval(start: calendar.startOfDay(for: now), end: now)),
                applications: selectedApplicationTokens
            )
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? calendar.startOfDay(for: now)
            return DeviceActivityFilter(
                segment: .daily(during: DateInterval(start: start, end: now)),
                applications: selectedApplicationTokens
            )
        }
    }

    private var selectedApplicationTokens: Set<ApplicationToken> {
        var tokens = Set(store.drafts.compactMap { try? ScrollLockEnforcement.token($0) })
        for rule in store.scheduleDrafts.flatMap(\.rules) {
            guard let data = rule.token,
                  let token = try? JSONDecoder().decode(ApplicationToken.self, from: data) else { continue }
            tokens.insert(token)
        }
        return tokens
    }

    private var schedulesTab: some View {
        NavigationStack {
            List {
                Section {
                    Text("Schedules are separate from general limits. General limits still override them. When a schedule ends, its rules stop applying unless another schedule is active.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        store.addSchedule()
                    } label: {
                        Label("Add Schedule", systemImage: "plus.circle")
                    }
                }
                if store.scheduleDrafts.isEmpty {
                    Section {
                        Text("Create a schedule for school, work, sleep, or any recurring block.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Your schedules") {
                        ForEach($store.scheduleDrafts) { schedule in
                            NavigationLink {
                                ScheduleEditorView(store: store, schedule: schedule)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(schedule.wrappedValue.name)
                                        Spacer()
                                        Text(schedule.wrappedValue.enabled ? "On" : "Off")
                                            .foregroundStyle(schedule.wrappedValue.enabled ? .green : .secondary)
                                    }
                                    Text(scheduleSummary(schedule.wrappedValue))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { store.scheduleDrafts.remove(atOffsets: $0) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Schedules")
        }
    }

    @ViewBuilder
    private func appListRow(_ preset: AppPreset) -> some View {
        HStack(spacing: 12) {
            if let token = try? ScrollLockEnforcement.token(preset) {
                Label(token)
                    .labelStyle(.titleAndIcon)
            } else {
                Text(preset.name)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text(limitSummary(preset))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if store.state.isLocked(preset.id) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Locked")
                }
                if let restriction = restrictionInfo(for: preset, state: store.state) {
                    Text("\(restriction.reason) · \(restriction.remainingText)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func limitSummary(_ preset: AppPreset) -> String {
        var parts: [String] = []
        if preset.enabled { parts.append("Daily \(preset.minutes)m") }
        if preset.hourlyEnabled { parts.append("Hourly \(preset.hourlyMinutes)m") }
        if preset.sessionEnabled { parts.append("Session \(preset.sessionMinutes)m") }
        if preset.scheduleEnabled {
            parts.append("\(ScrollLockState.weekdayName(preset.scheduleWeekday)) \(ScrollLockState.clockText(preset.scheduleStartMinute))–\(ScrollLockState.clockText(preset.scheduleEndMinute))")
        }
        return parts.isEmpty ? "No limits enabled" : parts.joined(separator: " · ")
    }
}

private struct FamilyActivityPickerSheet: View {
    @Binding var selection: FamilyActivitySelection
    let title: String
    @Environment(\.dismiss) private var dismiss
    let errorMessage: String?
    let onSelectionChange: () -> Void

    var body: some View {
        NavigationStack {
            FamilyActivityPicker(selection: Binding(
                get: { selection },
                set: { updated in
                    selection = updated
                    onSelectionChange()
                }
            ))
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(.regularMaterial)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private func minuteDurationText(_ minutes: Int) -> String {
    let hours = minutes / 60
    let remainder = minutes % 60
    if hours > 0 && remainder > 0 { return "\(hours)h \(remainder)m" }
    if hours > 0 { return "\(hours)h" }
    return "\(remainder)m"
}

private func scheduleSummary(_ schedule: ScrollLockSchedule) -> String {
    let days = schedule.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
    return "\(days) · \(ScrollLockState.clockText(schedule.startMinute)) to \(ScrollLockState.clockText(schedule.endMinute)) · \(schedule.rules.count) app(s)"
}

private struct RestrictionInfo {
    let reason: String
    let limit: String
    let deadline: Date?

    var remainingText: String {
        guard let deadline else { return "active" }
        return ScrollLockState.duration(max(0, deadline.timeIntervalSinceNow)) + " left"
    }
}

private func restrictionInfo(for preset: AppPreset, state: ScrollLockState, now: Date = Date()) -> RestrictionInfo? {
    let calendar = Calendar.current
    let usage = state.usage[preset.id]

    if state.locked.contains(preset.id) {
        let start = calendar.startOfDay(for: now)
        return RestrictionInfo(
            reason: "Daily limit",
            limit: minuteDurationText(preset.minutes),
            deadline: calendar.date(byAdding: .day, value: 1, to: start)
        )
    }

    if let scheduleInfo = scheduleRestrictionInfo(for: preset.id, state: state, now: now, calendar: calendar) {
        return scheduleInfo
    }

    if state.scheduledLocked.contains(preset.id) {
        let end = calendar.date(bySettingHour: preset.scheduleEndMinute / 60,
                                minute: preset.scheduleEndMinute % 60,
                                second: 0,
                                of: now)
        return RestrictionInfo(
            reason: "Scheduled block",
            limit: "\(ScrollLockState.weekdayName(preset.scheduleWeekday)) \(ScrollLockState.clockText(preset.scheduleStartMinute)) to \(ScrollLockState.clockText(preset.scheduleEndMinute))",
            deadline: end
        )
    }

    if usage?.sessionLocked == true {
        return RestrictionInfo(
            reason: "Per-session limit",
            limit: minuteDurationText(preset.sessionMinutes),
            deadline: usage?.sessionCooldownUntil
        )
    }

    if usage?.hourlyLocked == true {
        let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return RestrictionInfo(
            reason: "Hourly limit",
            limit: minuteDurationText(preset.hourlyMinutes),
            deadline: calendar.date(byAdding: .hour, value: 1, to: hourStart)
        )
    }

    return nil
}

private func scheduleRestrictionInfo(
    for appID: String,
    state: ScrollLockState,
    now: Date,
    calendar: Calendar
) -> RestrictionInfo? {
    for schedule in state.schedules {
        guard let interval = state.activeInterval(for: schedule, now: now, calendar: calendar),
              let rule = schedule.rules.first(where: { $0.appID == appID }) else { continue }
        let usage = state.scheduleUsage[ScrollLockState.scheduleKey(scheduleID: schedule.id, appID: appID)]
        let reason: String?
        let limit: String
        if rule.block {
            reason = "\(schedule.name) schedule"
            limit = "Blocked for the whole scheduled window"
        } else if usage?.totalLocked == true {
            reason = "\(schedule.name) schedule total limit"
            limit = minuteDurationText(rule.totalMinutes)
        } else if usage?.sessionLocked == true {
            reason = "\(schedule.name) schedule per-session limit"
            limit = minuteDurationText(rule.sessionMinutes)
        } else if usage?.hourlyLocked == true {
            reason = "\(schedule.name) schedule hourly limit"
            limit = minuteDurationText(rule.hourlyMinutes)
        } else {
            reason = nil
            limit = ""
        }
        if let reason {
            return RestrictionInfo(reason: reason, limit: limit, deadline: interval.end)
        }
    }
    return nil
}

private struct AppSettingsView: View {
    @ObservedObject var store: LimitStore
    @Binding var preset: AppPreset
    @State private var expandedEditor: Editor?

    private enum Editor: Hashable {
        case daily, hourly, session, cooldown
    }

    private var applied: AppPreset? { store.state.presets.first { $0.id == preset.id } }
    private var usage: UsageState? { store.state.usage[preset.id] }
    private var locked: Bool { store.state.isLocked(preset.id) }
    private var shortcutReady: Bool { store.state.shortcutReady(for: preset.token) }
    private var shortcutSetup: ShortcutSetupState {
        store.state.shortcutSetup[ScrollLockState.shortcutKey(for: preset.token)]
            ?? ShortcutSetupState(startSeenAt: nil, endSeenAt: nil)
    }
    private var shortcutAliasBinding: Binding<String> {
        Binding(
            get: { preset.shortcutAlias ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                preset.shortcutAlias = trimmed.isEmpty ? nil : trimmed
            }
        )
    }
    private var sessionMinutesSelection: Binding<Int> {
        Binding(
            get: { preset.sessionMinutes },
            set: { preset.sessionMinutes = $0 }
        )
    }

    var body: some View {
        List {
            Section {
                if let token = try? ScrollLockEnforcement.token(preset) {
                    Label(token)
                        .labelStyle(.titleAndIcon)
                }
            } footer: {
                Text("This is the system-selected app being configured.")
            }

            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } header: {
                    Text("Could not save")
                }
            }

            Section("Shortcut alias") {
                TextField("Name used in Shortcuts", text: shortcutAliasBinding)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .disabled(locked)
                LabeledContent("Shown in Shortcuts", value: preset.shortcutName)
                Text("Use a short name you can recognize when choosing the app in both automations. Leave it blank to use \(preset.name).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if ScrollLockState.isPlaceholderAppName(preset.name) {
                    Label("This app still has a placeholder name", systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Set the name above before creating the automations. This is the label ScrollLock will show in Shortcuts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("If an existing automation still says Selected app 1/2, open its action, tap the app field, and select \(preset.shortcutName) again. Shortcuts keeps the old label inside saved automations.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let restriction = restrictionInfo(for: preset, state: store.state) {
                Section {
                    Label("App restricted", systemImage: "lock.fill")
                        .foregroundStyle(.red)
                    LabeledContent("Caused by", value: restriction.reason)
                    LabeledContent("Limit", value: restriction.limit)
                    LabeledContent("Time remaining", value: restriction.remainingText)
                    if let deadline = restriction.deadline {
                        LabeledContent("Available again", value: deadline.formatted(date: .omitted, time: .standard))
                    }
                } header: {
                    Text("Active restriction")
                } footer: {
                    Text("The countdown updates every second. General limits override schedule limits.")
                }
            }

            Section("Daily limit") {
                Toggle("Daily limit", isOn: $preset.enabled)
                    .disabled(locked)
                if preset.enabled {
                    editorRow(title: "Time allowed", value: minuteDurationText(preset.minutes), editor: .daily)
                        .disabled(locked)
                    if expandedEditor == .daily {
                        DailyLimitEditor(
                            value: $preset.minutes,
                            minimum: max(1, preset.sessionEnabled ? preset.sessionMinutes : 1)
                        )
                    }
                }
            }

            Section("Hourly limit") {
                Toggle("Hourly limit", isOn: $preset.hourlyEnabled)
                    .disabled(locked || (preset.sessionEnabled && preset.sessionMinutes > 60 && !preset.hourlyEnabled))
                if preset.hourlyEnabled {
                    editorRow(title: "Time allowed", value: minuteDurationText(preset.hourlyMinutes), editor: .hourly)
                        .disabled(locked)
                    if expandedEditor == .hourly {
                        MinuteEditor(
                            title: "Hourly limit",
                            value: $preset.hourlyMinutes,
                            range: min(60, max(1, preset.sessionEnabled ? preset.sessionMinutes : 1))...60,
                            note: "Maximum time allowed in each local clock hour."
                        )
                    }
                }
            }

            Section("Per-session limit") {
                Toggle("Per-session limit", isOn: sessionToggle)
                    .disabled(locked)
                if !shortcutReady {
                    ShortcutSetupInstructions(appName: preset.shortcutName, setup: shortcutSetup)
                }
                if preset.sessionEnabled {
                    editorRow(title: "Time allowed", value: minuteDurationText(preset.sessionMinutes), editor: .session)
                        .disabled(locked)
                    if expandedEditor == .session {
                        MinuteEditor(
                            title: "Session limit",
                            value: sessionMinutesSelection,
                            range: ScrollLockLimits.minimumSessionLimitMinutes...1440,
                            note: "Maximum cumulative use inside one session reset window."
                        )
                    }
                    editorRow(title: "Cooldown", value: minuteDurationText(preset.cooldownMinutes), editor: .cooldown)
                        .disabled(locked)
                    if expandedEditor == .cooldown {
                        MinuteEditor(
                            title: "Cooldown",
                            value: $preset.cooldownMinutes,
                            range: ScrollLockLimits.minimumSessionLimitMinutes...1440,
                            note: "Starts only after the session allowance is exhausted."
                        )
                    }
                    Text("ScrollLock starts timing when the app-open automation runs and stops timing when the app-close automation runs. Device Activity remains as a background safety net while the app is open.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if preset.sessionEnabled && preset.sessionMinutes > 60 {
                Section {
                    Label("Hourly limit unavailable", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("An hourly limit can be at most 60 minutes, so it cannot be combined with a per-session limit longer than 60 minutes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Usage today") {
                if let usage {
                    let now = Date()
                    LabeledContent("Tracked today", value: ScrollLockState.duration(usage.used(at: now)))
                    LabeledContent("Session allowance used", value: preset.sessionEnabled ? ScrollLockState.duration(usage.sessionUsed(at: now)) : "Off")
                    LabeledContent("Tracked this hour", value: ScrollLockState.duration(usage.hourlyUsed(at: now, calendar: .current)))
                    if let cooldown = usage.sessionCooldownUntil, cooldown > now {
                        LabeledContent("Cooldown ends", value: cooldown.formatted(date: .omitted, time: .standard))
                    }
                } else {
                    Text("No usage threshold has been recorded yet.")
                        .foregroundStyle(.secondary)
                }
            }

            if let applied {
                Section("Applied settings") {
                    settingsSummary(for: applied)
                }
            }

        }
        .listStyle(.insetGrouped)
        .navigationTitle("App settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: preset) { _, _ in
            store.scheduleAutoApply()
        }
        .onDisappear {
            store.flushPendingChanges()
        }
    }

    private func editorRow(title: String, value: String, editor: Editor) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedEditor = expandedEditor == editor ? nil : editor
            }
        } label: {
            HStack {
                SettingsValueRow(title: title, value: value)
                Image(systemName: expandedEditor == editor ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sessionToggle: Binding<Bool> {
        Binding(
            get: { preset.sessionEnabled },
            set: { enabled in
                if enabled && !shortcutReady {
                    store.showError("Run both the Start Session and End Session Shortcuts for \(preset.shortcutName) before enabling its per-session limit.")
                    return
                }
                preset.sessionEnabled = enabled
            }
        )
    }

    @ViewBuilder
    private func settingsSummary(for values: AppPreset) -> some View {
        LabeledContent("Daily", value: values.enabled ? "\(values.minutes) minutes" : "Off")
        LabeledContent("Hourly", value: values.hourlyEnabled ? "\(values.hourlyMinutes) minutes" : "Off")
        LabeledContent("Per-session", value: values.sessionEnabled ? "\(values.sessionMinutes) minutes" : "Off")
        LabeledContent("Cooldown", value: values.sessionEnabled ? "\(values.cooldownMinutes) minutes" : "Off")
        LabeledContent("Scheduled block", value: values.scheduleEnabled
                       ? "\(ScrollLockState.weekdayName(values.scheduleWeekday)) \(ScrollLockState.clockText(values.scheduleStartMinute)) to \(ScrollLockState.clockText(values.scheduleEndMinute))"
                       : "Off")
    }
}

private struct ScheduleEditorView: View {
    @ObservedObject var store: LimitStore
    @Binding var schedule: ScrollLockSchedule

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section("Could not apply changes") {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("Schedule") {
                TextField("Name", text: $schedule.name)
                Toggle("Schedule enabled", isOn: $schedule.enabled)
            }

            Section {
                HStack {
                    Button("Weekdays") { schedule.weekdays = Set(2...6) }
                    Spacer()
                    Button("Every day") { schedule.weekdays = Set(1...7) }
                }
                ForEach(1...7, id: \.self) { day in
                    Toggle(ScrollLockState.weekdayName(day), isOn: weekdayBinding(day))
                }
            } header: {
                Text("Days")
            } footer: {
                Text("Choose one or more days. The schedule runs on each selected day.")
            }

            Section {
                DatePicker("Starts", selection: startDate, displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: endDate, displayedComponents: .hourAndMinute)
            } header: {
                Text("Time")
            } footer: {
                Text("Schedules use a same-day time window in the iPhone's local time zone.")
            }

            Section {
                Button {
                    store.chooseApps(for: schedule.id)
                } label: {
                    Label("Add or manage apps", systemImage: "plus.circle")
                }
                if schedule.rules.isEmpty {
                    Text("This schedule can contain apps that are not in Limits.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($schedule.rules) { rule in
                        NavigationLink {
                            ScheduleRuleView(
                                store: store,
                                appName: rule.wrappedValue.name ?? "App name unavailable",
                                appToken: rule.wrappedValue.token.flatMap { try? JSONDecoder().decode(ApplicationToken.self, from: $0) },
                                rule: rule
                            )
                        } label: {
                            HStack {
                                if let data = rule.wrappedValue.token,
                                   let token = try? JSONDecoder().decode(ApplicationToken.self, from: data) {
                                    Label(token)
                                        .labelStyle(.titleAndIcon)
                                } else {
                                    Text(rule.wrappedValue.name ?? "App name unavailable")
                                }
                                Spacer()
                                Text(ruleSummary(rule.wrappedValue))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { schedule.rules.remove(atOffsets: $0) }
                }
            } header: {
                Text("Apps in this schedule")
            } footer: {
                Text("Schedule restrictions are independent from general limits. General limits still override them, but a scheduled app does not need to appear in Limits.")
            }

        }
        .listStyle(.insetGrouped)
        .navigationTitle(schedule.name.isEmpty ? "Schedule" : schedule.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            store.flushPendingChanges()
        }
    }

    private func weekdayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { schedule.weekdays.contains(day) },
            set: { enabled in
                if enabled { schedule.weekdays.insert(day) }
                else { schedule.weekdays.remove(day) }
            }
        )
    }

    private var startDate: Binding<Date> {
        Binding(
            get: { scheduleTime(schedule.startMinute) },
            set: { schedule.startMinute = minute($0) }
        )
    }

    private var endDate: Binding<Date> {
        Binding(
            get: { scheduleTime(schedule.endMinute == 1440 ? 0 : schedule.endMinute) },
            set: { schedule.endMinute = minute($0) == 0 ? 1440 : minute($0) }
        )
    }

    private func scheduleTime(_ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    private func minute(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func ruleSummary(_ rule: ScheduleAppRule) -> String {
        if rule.block { return "Blocked" }
        var values: [String] = []
        if rule.totalEnabled { values.append("Total \(minuteDurationText(rule.totalMinutes))") }
        if rule.sessionEnabled {
            values.append("Session \(minuteDurationText(rule.sessionMinutes)) / cooldown \(minuteDurationText(rule.cooldownMinutes))")
        }
        if rule.hourlyEnabled { values.append("Hourly \(minuteDurationText(rule.hourlyMinutes))") }
        return values.isEmpty ? "Needs a restriction" : values.joined(separator: " · ")
    }
}

private struct ScheduleRuleView: View {
    @ObservedObject var store: LimitStore
    let appName: String
    let appToken: ApplicationToken?
    @Binding var rule: ScheduleAppRule
    @State private var expanded: Editor?

    private var shortcutReady: Bool {
        guard let token = rule.token else { return false }
        return store.state.shortcutReady(for: token)
    }
    private var linkedPresetIndex: Int? {
        guard let token = rule.token else { return nil }
        return store.drafts.firstIndex { $0.token == token }
    }
    private var shortcutDisplayName: String {
        if let linkedPresetIndex {
            return store.drafts[linkedPresetIndex].shortcutName
        }
        return rule.shortcutName
    }
    private var shortcutAliasBinding: Binding<String> {
        Binding(
            get: {
                if let linkedPresetIndex {
                    return store.drafts[linkedPresetIndex].shortcutAlias ?? ""
                }
                return rule.shortcutAlias ?? ""
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let linkedPresetIndex {
                    store.drafts[linkedPresetIndex].shortcutAlias = trimmed.isEmpty ? nil : trimmed
                } else {
                    rule.shortcutAlias = trimmed.isEmpty ? nil : trimmed
                }
            }
        )
    }

    private enum Editor: Hashable { case total, session, cooldown, hourly }

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section("Could not apply changes") {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                if let appToken {
                    Label(appToken)
                        .labelStyle(.titleAndIcon)
                } else {
                    Label(appName, systemImage: "app.fill")
                }
                Toggle("Block completely", isOn: $rule.block)
            } footer: {
                Text("A complete block takes priority over the other schedule limits for this app.")
            }

            Section("Shortcut alias") {
                TextField("Name used in Shortcuts", text: shortcutAliasBinding)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                LabeledContent("Shown in Shortcuts", value: shortcutDisplayName)
                Text("This name is shared with the app's general settings when the same app is selected there. Leave it blank to use \(appName).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("If an existing automation still shows an old label, open its action, tap the app field, and select \(shortcutDisplayName) again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Schedule total limit") {
                Toggle("Schedule total limit", isOn: $rule.totalEnabled)
                if rule.totalEnabled {
                    scheduleEditorRow("Time allowed", value: minuteDurationText(rule.totalMinutes), editor: .total)
                    if expanded == .total {
                        MinuteEditor(title: "Schedule total limit", value: $rule.totalMinutes, range: 1...1440, note: "Maximum use during one schedule occurrence.")
                    }
                }
            }

            Section("Per-session limit") {
                Toggle("Per-session limit", isOn: sessionToggle)
                if !shortcutReady {
                    ShortcutSetupInstructions(
                        appName: shortcutDisplayName,
                        setup: rule.token.flatMap { token in
                            store.state.shortcutSetup[ScrollLockState.shortcutKey(for: token)]
                        } ?? ShortcutSetupState(startSeenAt: nil, endSeenAt: nil)
                    )
                }
                if rule.sessionEnabled {
                    scheduleEditorRow("Time allowed", value: minuteDurationText(rule.sessionMinutes), editor: .session)
                    if expanded == .session {
                        MinuteEditor(
                            title: "Schedule session limit",
                            value: $rule.sessionMinutes,
                            range: ScrollLockLimits.minimumSessionLimitMinutes...1440,
                            note: "Maximum cumulative use inside one schedule session reset window."
                        )
                    }
                    scheduleEditorRow("Cooldown", value: minuteDurationText(rule.cooldownMinutes), editor: .cooldown)
                    if expanded == .cooldown {
                        MinuteEditor(
                            title: "Schedule session cooldown",
                            value: $rule.cooldownMinutes,
                            range: ScrollLockLimits.minimumSessionLimitMinutes...1440,
                            note: "Starts only after the schedule session allowance is exhausted."
                        )
                    }
                    Text("The same app-open and app-close automations time this scheduled session. Device Activity remains as a background safety net while the app is open.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hourly limit") {
                Toggle("Hourly limit", isOn: $rule.hourlyEnabled)
                if rule.hourlyEnabled {
                    scheduleEditorRow("Time allowed", value: minuteDurationText(rule.hourlyMinutes), editor: .hourly)
                    if expanded == .hourly {
                        MinuteEditor(title: "Schedule hourly limit", value: $rule.hourlyMinutes, range: 1...60, note: "Maximum use in each local clock hour during the schedule.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Schedule app settings")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            store.flushPendingChanges()
        }
    }

    private func scheduleEditorRow(_ title: String, value: String, editor: Editor) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expanded = expanded == editor ? nil : editor
            }
        } label: {
            HStack {
                SettingsValueRow(title: title, value: value)
                Image(systemName: expanded == editor ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var sessionToggle: Binding<Bool> {
        Binding(
            get: { rule.sessionEnabled },
            set: { enabled in
                if !enabled || shortcutReady {
                    rule.sessionEnabled = enabled
                }
            }
        )
    }
}

private struct ShortcutSetupInstructions: View {
    let appName: String
    let setup: ShortcutSetupState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shortcut setup required", systemImage: "lock.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("Per-session limits stay locked until ScrollLock receives both actions for \(appName). Create two personal automations, one for opening and one for closing the app.")

            setupStep(
                isComplete: setup.startSeenAt != nil,
                title: "When \(appName) is opened",
                detail: "Choose App → Is Opened → Add Action → Start App Session → \(appName)."
            )
            setupStep(
                isComplete: setup.endSeenAt != nil,
                title: "When \(appName) is closed",
                detail: "Choose App → Is Closed → Add Action → End App Session → \(appName)."
            )

            Text("These must be personal automations, not regular shortcuts. For both, choose Run Immediately and turn off Ask Before Running if that option appears. Save them, then trigger each once by opening and closing the app so ScrollLock can confirm both actions.")

            Link(destination: URL(string: "shortcuts://")!) {
                Label("Open Shortcuts", systemImage: "arrow.up.right.square")
            }

            Text("The 1-minute session and 1-minute cooldown choices are supported. The separate 15-minute value is only the hidden Device Activity safety-monitor interval, not your session limit.")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func setupStep(isComplete: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
            }
        }
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DailyLimitEditor: View {
    @Binding var value: Int
    let minimum: Int

    var body: some View {
        DurationWheelPicker(
            title: "Daily limit",
            value: $value,
            range: minimum...1440,
            note: "Scroll hours and minutes separately."
        )
    }
}

private struct MinuteEditor: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let note: String

    var body: some View {
        DurationWheelPicker(title: title, value: $value, range: range, note: note)
    }
}

private struct DurationWheelPicker: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let note: String
    @State private var pickerGeneration = 0

    private var normalizedValue: Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private var selectedHour: Int { normalizedValue / 60 }
    private var selectedMinute: Int { normalizedValue % 60 }
    private var maximumHour: Int { range.upperBound / 60 }

    private var hourRange: ClosedRange<Int> {
        0...maximumHour
    }

    private var minuteRange: ClosedRange<Int> {
        let lower = selectedHour == range.lowerBound / 60 ? range.lowerBound % 60 : 0
        let upper = selectedHour == maximumHour ? range.upperBound % 60 : 59
        return min(lower, upper)...max(lower, upper)
    }

    private var hourSelection: Binding<Int> {
        Binding(
            get: { selectedHour },
            set: { newHour in
                value = normalized(newHour * 60 + selectedMinute)
            }
        )
    }

    private var minuteSelection: Binding<Int> {
        Binding(
            get: { selectedMinute },
            set: { newMinute in
                value = normalized(selectedHour * 60 + newMinute)
            }
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(minuteDurationText(normalizedValue))
                .font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach([1, 5, 15, 30, 60].filter { range.contains($0) }, id: \.self) { minutes in
                    Button(minuteDurationText(minutes)) {
                        value = minutes
                        // Recreate the wheel after a quick choice so a stale Picker
                        // selection cannot write the previous value back over it.
                        pickerGeneration += 1
                    }
                    .buttonStyle(.bordered)
                    .tint(minutes == normalizedValue ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal)
            HStack(spacing: 0) {
                Picker("Hours", selection: hourSelection) {
                    ForEach(hourRange, id: \.self) { hour in
                        Text("\(hour) hr")
                            .tag(hour)
                    }
                }
                Picker("Minutes", selection: minuteSelection) {
                    ForEach(minuteRange, id: \.self) { minute in
                        Text("\(minute) min")
                            .tag(minute)
                    }
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 216)
            .clipped()
            .id(pickerGeneration)
            Text("Quick choices include 1 minute. Use the wheels for any other duration.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear { value = normalizedValue }
    }

    private func normalized(_ candidate: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, candidate))
    }
}

#Preview { ContentView() }
