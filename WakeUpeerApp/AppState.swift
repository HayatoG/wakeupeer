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

    /// Feriado de hoje, consultado ao iniciar.
    private(set) var todayHoliday: HolidayLookup = .notHoliday

    // MARK: Dependências

    private let store: any StateStore
    private let launcher: any AppLauncher
    private let clock: any Clock
    private let holidayProvider: any HolidayProvider

    // MARK: Init

    init(
        store: any StateStore,
        launcher: any AppLauncher,
        clock: any Clock,
        holidayProvider: any HolidayProvider
    ) {
        self.store = store
        self.launcher = launcher
        self.clock = clock
        self.holidayProvider = holidayProvider

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
        return AppState(
            store: store,
            launcher: NSWorkspaceAppLauncher(),
            clock: clock,
            holidayProvider: BrazilianHolidayProvider(calendar: clock.calendar)
        )
    }

    // MARK: - Ciclo de vida

    func bootstrap() async {
        await refreshRunningApps()
        await refreshHoliday()
        await evaluate(trigger: .login)
    }

    func refreshRunningApps() async {
        runningApps = await launcher.runningApps()
    }

    func refreshHoliday() async {
        todayHoliday = await holidayProvider.lookup(day: clock.now)
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
            let greeting = GreetingResolver.render(
                profile: profile,
                at: clock.now,
                calendar: clock.calendar,
                itemCount: profile.enabledItems.count)
            present(
                Prompt(
                    profileID: profile.id,
                    windowDay: windowDay,
                    title: greeting.title,
                    body: greeting.body))

        case .askHolidayConfirmation(let profile, let windowDay, let names):
            let greeting = GreetingResolver.renderHolidayPrompt(
                profile: profile, holidayNames: names)
            present(
                Prompt(
                    profileID: profile.id,
                    windowDay: windowDay,
                    title: greeting.title,
                    body: greeting.body,
                    confirmLabel: "Sim, vou trabalhar",
                    declineLabel: "Não, é folga",
                    isHolidayPrompt: true))

        case .skip:
            break
        }
    }

    private func present(_ prompt: Prompt) {
        pendingPrompt = prompt
        fireLog.pending.append(
            PendingDecision(
                profileID: prompt.profileID,
                windowDay: prompt.windowDay,
                askedAt: clock.now,
                isHolidayPrompt: prompt.isHolidayPrompt,
                holidayNames: todayHoliday.names))
        persistFireLog()
    }

    // MARK: - Resposta do usuário

    func answer(_ answer: PromptAnswer) async {
        guard let prompt = pendingPrompt else { return }
        pendingPrompt = nil
        fireLog.pending.removeAll {
            $0.profileID == prompt.profileID && $0.windowDay == prompt.windowDay
        }

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
            persistFireLog()
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
        // Pendências expiram na virada do dia.
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
            storeError = nil
        } catch {
            storeError = String(describing: error)
        }
    }

    func save(config newConfig: AppConfig) {
        config = newConfig
        do {
            try store.saveConfig(newConfig)
            storeError = nil
        } catch {
            storeError = String(describing: error)
        }
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
        if pendingPrompt != nil { return "bell.badge" }
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

    var configDirectory: URL { FileStateStore.defaultRoot() }
}
