import Foundation
import Observation
import SwiftUI
import WakeUpeerDomain
import WakeUpeerPersistence
import WakeUpeerPlatformMac

/// Estado central da aplicação: a ponte entre o domínio puro e as views.
@Observable
@MainActor
final class AppState {

    // MARK: Estado observável

    private(set) var config: AppConfig
    private(set) var fireLog: FireLog
    private(set) var runningApps: [RunningApp] = []
    private(set) var lastReport: LaunchReport?
    private(set) var isLaunching = false
    private(set) var storeError: String?

    /// Disparo aguardando confirmação do usuário.
    private(set) var pendingPrompt: Prompt?

    private(set) var todayHoliday: HolidayLookup = .notHoliday
    private(set) var loginItemStatus: LoginItemStatus = .notRegistered
    private(set) var notificationsAuthorized = false

    /// Recalculado a cada segundo enquanto o popover está aberto, para os
    /// tempos subirem à vista.
    private(set) var tick = 0

    /// Chamado quando algo pede a janela de relatório — por ora, tocar na
    /// notificação semanal. O AppDelegate abre a janela em AppKit.
    var onOpenReport: (@MainActor () -> Void)?

    // MARK: Dependências

    private let store: any StateStore
    private let launcher: any AppLauncher
    private let clock: any Clock
    /// Recriado quando o usuário muda os calendários selecionados.
    private var holidayProvider: any HolidayProvider
    private let loginItem: any LoginItemManager
    private let notifier: UserNotificationsNotifier
    private let eventSource: WorkspaceEventSource
    let tracker: UsageTracker

    private var eventTask: Task<Void, Never>?

    // MARK: Init

    init(
        store: any StateStore,
        launcher: any AppLauncher,
        clock: any Clock,
        holidayProvider: any HolidayProvider,
        loginItem: any LoginItemManager,
        notifier: UserNotificationsNotifier,
        eventSource: WorkspaceEventSource,
        tracker: UsageTracker
    ) {
        self.store = store
        self.launcher = launcher
        self.clock = clock
        self.holidayProvider = holidayProvider
        self.loginItem = loginItem
        self.notifier = notifier
        self.eventSource = eventSource
        self.tracker = tracker

        // Um config ilegível não pode impedir o app de abrir: cai no padrão
        // e mostra o erro na UI para o usuário poder corrigir o arquivo.
        do {
            self.config = try store.loadConfig()
        } catch {
            self.config = DefaultProfiles.makeConfig()
            self.storeError = String(describing: error)
        }
        self.fireLog = (try? store.loadFireLog()) ?? FireLog()
    }

    /// Fábrica com as implementações reais do macOS.
    static func live() -> AppState {
        let root = FileStateStore.defaultRoot()
        let clock = SystemClock()
        let store: any StateStore
        do {
            store = try FileStateStore(root: root)
        } catch {
            fatalError("Não foi possível preparar \(root.path): \(error)")
        }

        let config = (try? store.loadConfig()) ?? DefaultProfiles.makeConfig()
        let notifier = UserNotificationsNotifier()

        let state = AppState(
            store: store,
            launcher: NSWorkspaceAppLauncher(),
            clock: clock,
            holidayProvider: Self.makeHolidayProvider(
                calendarIDs: config.holidayCalendarIDs, calendar: clock.calendar),
            loginItem: SMAppServiceLoginItem(),
            notifier: notifier,
            eventSource: WorkspaceEventSource(),
            tracker: UsageTracker(store: store, clock: clock, config: config.tracking)
        )
        notifier.answerSink = state
        return state
    }

    /// O EventKit vem na frente para pegar feriados municipais e datas
    /// pessoais; a lista nacional atrás garante que negar a permissão não
    /// quebra a detecção.
    private static func makeHolidayProvider(
        calendarIDs: [String], calendar: Calendar
    ) -> any HolidayProvider {
        let national = BrazilianHolidayProvider(calendar: calendar)
        guard !calendarIDs.isEmpty else { return national }
        return ChainedHolidayProvider(
            primary: EventKitHolidayProvider(calendarIDs: calendarIDs, calendar: calendar),
            fallback: national)
    }

    // MARK: - Ciclo de vida

    private var hasBootstrapped = false

    func bootstrap() async {
        // O popover chama isto toda vez que abre; o trabalho pesado roda uma vez.
        guard !hasBootstrapped else {
            await refreshRunningApps()
            return
        }
        hasBootstrapped = true

        notifier.onOpenReport = { [weak self] in
            Task { @MainActor in self?.onOpenReport?() }
        }

        // O rastreamento começa primeiro, e sem await: pedir autorização de
        // notificações bloqueia até o usuário responder o diálogo, e não faz
        // sentido o tempo do dia ficar refém dessa resposta.
        tracker.currentProfileID = activeProfile?.id
        tracker.start()
        observeSystemEvents()

        await refreshRunningApps()
        await refreshHoliday()
        restorePendingPrompt()

        loginItemStatus = await loginItem.status()
        refreshCalendars()
        scheduleWeeklyReport()
        purgeOldTracking()

        Task { [weak self] in
            guard let self else { return }
            let granted = await self.notifier.requestAuthorization()
            await MainActor.run { self.notificationsAuthorized = granted }
        }
    }

    /// Se o app foi encerrado com uma pergunta em aberto, ela volta.
    private func restorePendingPrompt() {
        let today = ProfileResolver.dayString(clock.now, calendar: clock.calendar)
        guard let pending = fireLog.pending.first(where: { $0.windowDay == today }),
              let profile = config.profile(id: pending.profileID)
        else { return }

        pendingPrompt = makePrompt(
            profile: profile,
            windowDay: pending.windowDay,
            holidayNames: pending.holidayNames,
            isHoliday: pending.isHolidayPrompt)
    }

    private func observeSystemEvents() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.eventSource.events() {
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: SystemEvent) async {
        switch event {
        case .didLogin:
            await evaluate(trigger: .login)

        case .didWake(let slept):
            await refreshHoliday()
            await evaluate(trigger: .wake, sleepDuration: slept)

        case .willSleep, .willTerminate:
            tracker.flush()

        case .screenLocked, .screenUnlocked:
            break
        }
    }

    func shutdown() {
        eventTask?.cancel()
        weeklyReportTask?.cancel()
        tracker.stop()
    }

    /// Respeita a retenção configurada, apagando os arquivos mensais antigos.
    private func purgeOldTracking() {
        guard let cutoff = clock.calendar.date(
            byAdding: .day, value: -config.tracking.retentionDays, to: clock.now)
        else { return }
        try? store.purgeTracking(olderThan: cutoff)
    }

    func refreshRunningApps() async {
        runningApps = await launcher.runningApps()
        tracker.currentProfileID = activeProfile?.id
    }

    func refreshHoliday() async {
        todayHoliday = await holidayProvider.lookup(day: clock.now)
    }

    /// Chamado pelo timer do popover; só força a releitura dos tempos.
    func refreshTick() {
        tick &+= 1
    }

    // MARK: - Avaliação

    /// Decide se algum perfil deve disparar e, se sim, monta o prompt.
    /// Nada abre sem confirmação do usuário.
    func evaluate(trigger: Trigger, sleepDuration: TimeInterval? = nil) async {
        let input = ResolutionInput(
            now: clock.now,
            calendar: clock.calendar,
            profiles: config.profiles,
            holiday: todayHoliday,
            holidayBehavior: config.holidayBehavior,
            fireLog: fireLog,
            trigger: trigger,
            sleepDuration: sleepDuration,
            wakeThreshold: config.wakeThreshold
        )

        switch ProfileResolver.resolve(input) {
        case .fire(let profile, let windowDay):
            await present(
                makePrompt(profile: profile, windowDay: windowDay))

        case .askHolidayConfirmation(let profile, let windowDay, let names):
            await present(
                makePrompt(
                    profile: profile, windowDay: windowDay,
                    holidayNames: names, isHoliday: true))

        case .skip:
            break
        }
    }

    private func makePrompt(
        profile: Profile,
        windowDay: String,
        holidayNames: [String] = [],
        isHoliday: Bool = false
    ) -> Prompt {
        if isHoliday {
            let greeting = GreetingResolver.renderHolidayPrompt(
                profile: profile, holidayNames: holidayNames)
            return Prompt(
                profileID: profile.id,
                windowDay: windowDay,
                title: greeting.title,
                body: greeting.body,
                confirmLabel: "Sim, vou trabalhar",
                declineLabel: "Não, é folga",
                isHolidayPrompt: true)
        }

        let greeting = GreetingResolver.render(
            profile: profile,
            at: clock.now,
            calendar: clock.calendar,
            itemCount: profile.enabledItems.count)
        return Prompt(
            profileID: profile.id,
            windowDay: windowDay,
            title: greeting.title,
            body: greeting.body)
    }

    private func present(_ prompt: Prompt) async {
        pendingPrompt = prompt
        fireLog.pending.append(
            PendingDecision(
                profileID: prompt.profileID,
                windowDay: prompt.windowDay,
                askedAt: clock.now,
                isHolidayPrompt: prompt.isHolidayPrompt,
                holidayNames: todayHoliday.names))
        persistFireLog()

        await notifier.present(prompt)
    }

    // MARK: - Resposta do usuário

    func answer(_ answer: PromptAnswer) async {
        guard let prompt = pendingPrompt else { return }
        await resolve(prompt: prompt, with: answer)
    }

    private func resolve(prompt: Prompt, with answer: PromptAnswer) async {
        guard answer != .ignored else { return }

        pendingPrompt = nil
        fireLog.pending.removeAll {
            $0.profileID == prompt.profileID && $0.windowDay == prompt.windowDay
        }
        await notifier.withdrawPrompt(
            profileID: prompt.profileID, windowDay: prompt.windowDay)

        switch answer {
        case .confirmed:
            guard let profile = config.profile(id: prompt.profileID) else { return }
            await launch(
                profile: profile,
                windowDay: prompt.windowDay,
                trigger: prompt.isHolidayPrompt ? .holidayConfirmed : .login)
        case .declined:
            record(
                profileID: prompt.profileID,
                windowDay: prompt.windowDay,
                trigger: prompt.isHolidayPrompt ? .holidaySkipped : .manual)
        case .ignored:
            break
        }
    }

    // MARK: - Lançamento

    /// Disparo manual pelo menu, ignorando janela e dedupe.
    func launchManually(profile: Profile) async {
        let windowDay = ProfileResolver.dayString(clock.now, calendar: clock.calendar) ?? ""
        await launch(profile: profile, windowDay: windowDay, trigger: .manual)
    }

    private func launch(profile: Profile, windowDay: String, trigger: Trigger) async {
        isLaunching = true
        defer { isLaunching = false }

        let profileLauncher = ProfileLauncher(
            launcher: launcher,
            delayMilliseconds: config.launchDelayMilliseconds)
        lastReport = await profileLauncher.launch(profile: profile, at: clock.now)

        record(profileID: profile.id, windowDay: windowDay, trigger: trigger)
        await refreshRunningApps()
    }

    private func record(profileID: UUID, windowDay: String, trigger: Trigger) {
        fireLog.records.append(
            FireRecord(
                profileID: profileID,
                firedAt: clock.now,
                windowDay: windowDay,
                trigger: trigger))
        trimFireLog()
        persistFireLog()
    }

    /// Mantém só o histórico recente; o dedupe não precisa de mais que isso.
    private func trimFireLog() {
        guard let cutoff = clock.calendar.date(byAdding: .day, value: -90, to: clock.now)
        else { return }
        fireLog.records.removeAll { $0.firedAt < cutoff }
        fireLog.pending.removeAll { $0.askedAt < clock.calendar.startOfDay(for: clock.now) }
    }

    private func persistFireLog() {
        do {
            try store.saveFireLog(fireLog)
        } catch {
            storeError = String(describing: error)
        }
    }

    // MARK: - Configuração

    func reloadConfig() {
        do {
            config = try store.loadConfig()
            tracker.update(config: config.tracking)
            storeError = nil
        } catch {
            storeError = String(describing: error)
        }
    }

    func save(config newConfig: AppConfig) {
        config = newConfig
        do {
            try store.saveConfig(newConfig)
            tracker.update(config: newConfig.tracking)
            storeError = nil
        } catch {
            storeError = String(describing: error)
        }
    }

    // MARK: - Edição de perfis

    /// Grava um perfil alterado. Toda edição passa por aqui, então o
    /// config.json fica sempre em dia com a UI.
    func update(profile: Profile) {
        var updated = config
        guard let index = updated.profiles.firstIndex(where: { $0.id == profile.id })
        else { return }
        updated.profiles[index] = profile
        save(config: updated)
    }

    func addProfile() -> Profile {
        let new = Profile(
            name: "Novo perfil",
            weekdays: Weekday.workdays,
            window: TimeWindow(from: 9, to: 18),
            priority: 0,
            symbolName: "circle")
        var updated = config
        updated.profiles.append(new)
        save(config: updated)
        return new
    }

    func duplicate(profile: Profile) -> Profile {
        var copy = profile
        copy.id = UUID()
        copy.name = "\(profile.name) (cópia)"
        // Os itens precisam de identidade própria, senão a lista da UI
        // confunde as duas cópias.
        copy.items = profile.items.map {
            ProfileItem(
                item: $0.item, isEnabled: $0.isEnabled,
                bringToFront: $0.bringToFront, launchHidden: $0.launchHidden)
        }
        var updated = config
        updated.profiles.append(copy)
        save(config: updated)
        return copy
    }

    func delete(profileID: UUID) {
        var updated = config
        updated.profiles.removeAll { $0.id == profileID }
        save(config: updated)
    }

    func moveProfiles(from source: IndexSet, to destination: Int) {
        var updated = config
        updated.profiles.move(fromOffsets: source, toOffset: destination)
        save(config: updated)
    }

    // MARK: - Configurações gerais

    func setWakeThreshold(_ hours: Double) {
        var updated = config
        updated.wakeThresholdHours = max(0, hours)
        save(config: updated)
    }

    func setLaunchDelay(_ milliseconds: Int) {
        var updated = config
        updated.launchDelayMilliseconds = max(0, milliseconds)
        save(config: updated)
    }

    func setHolidayBehavior(_ behavior: HolidayBehavior) {
        var updated = config
        updated.holidayBehavior = behavior
        save(config: updated)
    }

    func setTracking(_ tracking: TrackingConfig) {
        var updated = config
        updated.tracking = tracking
        save(config: updated)
    }

    func setWeeklyReport(enabled: Bool, weekday: Weekday, hour: Int) {
        var updated = config
        updated.weeklyReportEnabled = enabled
        updated.weeklyReportWeekday = weekday
        updated.weeklyReportHour = hour
        save(config: updated)
    }

    /// Apaga todo o histórico de uso.
    func eraseTrackingData() {
        try? store.purgeTracking(olderThan: clock.now.addingTimeInterval(86_400))
        tracker.resetToday()
    }

    // MARK: - Calendários de feriado

    private(set) var calendarAuthorization = EventKitHolidayProvider.authorization
    private(set) var availableCalendars: [EventKitHolidayProvider.CalendarInfo] = []

    func requestCalendarAccess() async {
        let provider = EventKitHolidayProvider(
            calendarIDs: config.holidayCalendarIDs, calendar: clock.calendar)
        calendarAuthorization = await provider.requestAccess()
        refreshCalendars()

        // Na primeira autorização, já marca os calendários que parecem ser
        // de feriados, para o recurso funcionar sem configuração extra.
        if calendarAuthorization == .authorized, config.holidayCalendarIDs.isEmpty {
            let suggested = provider.suggestedHolidayCalendarIDs()
            if !suggested.isEmpty {
                setHolidayCalendars(suggested)
            }
        }
        await refreshHoliday()
    }

    func refreshCalendars() {
        calendarAuthorization = EventKitHolidayProvider.authorization
        guard calendarAuthorization == .authorized else {
            availableCalendars = []
            return
        }
        let provider = EventKitHolidayProvider(
            calendarIDs: config.holidayCalendarIDs, calendar: clock.calendar)
        availableCalendars = provider.availableCalendars()
    }

    func setHolidayCalendars(_ ids: [String]) {
        var updated = config
        updated.holidayCalendarIDs = ids
        save(config: updated)
        holidayProvider = Self.makeHolidayProvider(
            calendarIDs: ids, calendar: clock.calendar)
        Task { await refreshHoliday() }
    }

    func openCalendarSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Resumo semanal

    private var weeklyReportTask: Task<Void, Never>?

    /// Verifica de hora em hora se chegou a hora do resumo. Um timer de
    /// precisão não se justifica para algo que acontece uma vez por semana.
    private func scheduleWeeklyReport() {
        weeklyReportTask?.cancel()
        weeklyReportTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.postWeeklyReportIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func postWeeklyReportIfDue() async {
        guard config.weeklyReportEnabled else { return }

        let now = clock.now
        let parts = clock.calendar.dateComponents([.weekday, .hour], from: now)
        guard parts.weekday == config.weeklyReportWeekday.rawValue,
              let hour = parts.hour, hour == config.weeklyReportHour
        else { return }

        // Uma vez por semana, mesmo que o app reinicie no mesmo dia.
        guard let day = ProfileResolver.dayString(now, calendar: clock.calendar),
              lastWeeklyReportDay != day
        else { return }
        lastWeeklyReportDay = day

        let report = self.report(forWeekContaining: now)
        guard report.totalActive > 0 else { return }

        let top = report.apps.first.map { " \($0.appName) liderou." } ?? ""
        await notifier.postWeeklyReport(
            title: "Sua semana no Mac",
            body:
                "\(DurationFormat.short(report.totalActive)) de uso ativo, média de \(DurationFormat.short(report.dailyAverage)) por dia.\(top)"
        )
    }

    private var lastWeeklyReportDay: String? {
        get { UserDefaults.standard.string(forKey: "lastWeeklyReportDay") }
        set { UserDefaults.standard.set(newValue, forKey: "lastWeeklyReportDay") }
    }

    // MARK: - Login item

    func setLaunchAtLogin(_ enabled: Bool) async {
        do {
            try await loginItem.setEnabled(enabled)
            var updated = config
            updated.launchAtLogin = enabled
            save(config: updated)
        } catch {
            storeError = "Não foi possível alterar o início automático: \(error.localizedDescription)"
        }
        loginItemStatus = await loginItem.status()
    }

    func openLoginItemSettings() async {
        await loginItem.openSystemSettings()
    }

    var isInStableLocation: Bool { SMAppServiceLoginItem.isInStableLocation }

    // MARK: - Relatório

    func report(forWeekContaining date: Date) -> UsageReport {
        let calendar = clock.calendar
        guard let interval = ReportBuilder.weekInterval(containing: date, calendar: calendar)
        else {
            return ReportBuilder.build(
                events: [], from: date, to: date, calendar: calendar)
        }

        tracker.flush()  // inclui o que ainda está em memória
        let events = (try? store.trackingEvents(from: interval.start, to: interval.end)) ?? []
        return ReportBuilder.build(
            events: events, from: interval.start, to: interval.end, calendar: calendar)
    }

    var todayReport: UsageReport {
        let calendar = clock.calendar
        let startOfDay = calendar.startOfDay(for: clock.now)
        tracker.flush()
        let events = (try? store.trackingEvents(from: startOfDay, to: clock.now)) ?? []
        return ReportBuilder.build(
            events: events, from: startOfDay, to: clock.now, calendar: calendar)
    }

    // MARK: - Derivados para a UI

    /// O perfil cuja janela contém o instante atual, se houver.
    var activeProfile: Profile? {
        let input = ResolutionInput(
            now: clock.now,
            calendar: clock.calendar,
            profiles: config.profiles,
            holiday: .notHoliday,
            fireLog: FireLog(),  // ignora o dedupe: queremos "quem está ativo agora"
            trigger: .manual
        )
        return ProfileResolver.resolve(input).profile
    }

    var salutation: String {
        GreetingResolver.timeOfDaySalutation(clock.now, calendar: clock.calendar)
    }

    var menuBarSymbol: String {
        if pendingPrompt != nil { return "bell.badge.fill" }
        if let profile = activeProfile { return profile.symbolName }
        let hour = clock.calendar.dateComponents([.hour], from: clock.now).hour ?? 0
        switch hour {
        case 5..<12: return "sun.horizon"
        case 12..<18: return "sun.max"
        default: return "moon.stars"
        }
    }

    func isRunning(_ item: ProfileItem) -> Bool {
        guard case .application(let bundleID, _, _) = item.item else { return false }
        return runningApps.contains { $0.bundleID == bundleID }
    }

    /// Tempo que o app deste item acumulou hoje.
    func timeToday(_ item: ProfileItem) -> TimeInterval {
        guard case .application(let bundleID, _, _) = item.item else { return 0 }
        return tracker.timeToday(bundleID: bundleID)
    }

    func timeToday(bundleID: String) -> TimeInterval {
        tracker.timeToday(bundleID: bundleID)
    }

    var activeToday: TimeInterval { tracker.activeToday }
    var focusedBundleID: String? { tracker.focusedBundleID }
    var isTrackingEnabled: Bool { config.tracking.isEnabled }

    var configDirectory: URL { FileStateStore.defaultRoot() }
}

// MARK: - Respostas vindas das notificações

extension AppState: AnswerSink {
    nonisolated func receive(
        answer: PromptAnswer, profileID: UUID, windowDay: String
    ) async {
        await MainActor.run {
            Task { await self.receiveOnMain(answer: answer, profileID: profileID, windowDay: windowDay) }
        }
    }

    private func receiveOnMain(
        answer: PromptAnswer, profileID: UUID, windowDay: String
    ) async {
        // A resposta pode chegar quando o popover nunca foi aberto, então o
        // prompt é remontado a partir do registro persistido.
        let prompt: Prompt
        if let existing = pendingPrompt,
           existing.profileID == profileID, existing.windowDay == windowDay
        {
            prompt = existing
        } else if let pending = fireLog.pending.first(where: {
            $0.profileID == profileID && $0.windowDay == windowDay
        }), let profile = config.profile(id: profileID) {
            prompt = makePrompt(
                profile: profile, windowDay: windowDay,
                holidayNames: pending.holidayNames, isHoliday: pending.isHolidayPrompt)
        } else {
            return
        }

        await resolve(prompt: prompt, with: answer)
    }
}
