import Foundation

/// As portas do domínio: tudo que toca o sistema operacional entra por aqui.
/// Portar para Linux/Windows é implementar estes protocolos — o resto do
/// domínio não muda uma linha.

// MARK: - Relógio

public protocol Clock: Sendable {
    var now: Date { get }
    /// Já com a timezone e `firstWeekday` corretos. O domínio nunca usa `Calendar.current`.
    var calendar: Calendar { get }
}

/// Relógio fixo, para testes.
public struct FixedClock: Clock {
    public let now: Date
    public let calendar: Calendar

    public init(now: Date, calendar: Calendar) {
        self.now = now
        self.calendar = calendar
    }
}

// MARK: - Feriados

public protocol HolidayProvider: Sendable {
    /// Consulta os feriados do dia. Nunca lança: falha vira `.unavailable`.
    func lookup(day: Date) async -> HolidayLookup
}

// MARK: - Lançamento de apps

public enum LaunchOutcome: Sendable, Equatable {
    case launched
    case alreadyRunning
    case activated
    case failed(reason: String)

    public var isSuccess: Bool {
        switch self {
        case .launched, .alreadyRunning, .activated: true
        case .failed: false
        }
    }
}

public struct LaunchResult: Sendable, Equatable, Identifiable {
    public var itemID: String
    public var displayName: String
    public var outcome: LaunchOutcome

    public var id: String { itemID }

    public init(itemID: String, displayName: String, outcome: LaunchOutcome) {
        self.itemID = itemID
        self.displayName = displayName
        self.outcome = outcome
    }
}

public struct LaunchReport: Sendable, Equatable {
    public var profileID: UUID
    public var profileName: String
    public var startedAt: Date
    public var results: [LaunchResult]

    public init(profileID: UUID, profileName: String, startedAt: Date, results: [LaunchResult]) {
        self.profileID = profileID
        self.profileName = profileName
        self.startedAt = startedAt
        self.results = results
    }

    public var failures: [LaunchResult] { results.filter { !$0.outcome.isSuccess } }
    public var hasFailures: Bool { !failures.isEmpty }
}

public protocol AppLauncher: Sendable {
    func launch(_ item: ProfileItem) async -> LaunchOutcome
    func runningApps() async -> [RunningApp]
    func isRunning(bundleID: String) async -> Bool
}

// MARK: - Notificações

/// A resposta do usuário ao prompt de confirmação. O feriado usa o mesmo
/// mecanismo, só com texto diferente.
public enum PromptAnswer: String, Sendable, Codable {
    case confirmed
    case declined
    case ignored
}

public struct Prompt: Sendable, Equatable {
    public var profileID: UUID
    public var windowDay: String
    public var title: String
    public var body: String
    public var confirmLabel: String
    public var declineLabel: String
    public var isHolidayPrompt: Bool

    public init(
        profileID: UUID,
        windowDay: String,
        title: String,
        body: String,
        confirmLabel: String = "Abrir agora",
        declineLabel: String = "Agora não",
        isHolidayPrompt: Bool = false
    ) {
        self.profileID = profileID
        self.windowDay = windowDay
        self.title = title
        self.body = body
        self.confirmLabel = confirmLabel
        self.declineLabel = declineLabel
        self.isHolidayPrompt = isHolidayPrompt
    }
}

public protocol Notifier: Sendable {
    /// Requisita autorização. `false` não é fatal: o popover é o plano B.
    func requestAuthorization() async -> Bool
    /// Mostra o prompt. A resposta chega pelo `AnswerSink`, podendo nunca chegar.
    func present(_ prompt: Prompt) async
    /// Informativo, sem ações.
    func postInfo(title: String, body: String) async
    /// Resumo semanal; abre a janela de relatório ao ser tocado.
    func postWeeklyReport(title: String, body: String) async
    func withdrawPrompt(profileID: UUID, windowDay: String) async
}

/// Para onde as respostas do usuário voltam, venham da notificação ou do popover.
public protocol AnswerSink: AnyObject, Sendable {
    func receive(answer: PromptAnswer, profileID: UUID, windowDay: String) async
}

// MARK: - Tracking

public protocol ForegroundSampler: Sendable {
    func sample() async -> ForegroundSample?
}

// MARK: - Persistência

public protocol StateStore: Sendable {
    func loadConfig() throws -> AppConfig
    func saveConfig(_ config: AppConfig) throws

    func loadFireLog() throws -> FireLog
    func saveFireLog(_ log: FireLog) throws

    func appendTracking(_ events: [TrackingEvent]) throws
    func trackingEvents(from: Date, to: Date) throws -> [TrackingEvent]
    func purgeTracking(olderThan: Date) throws
}

// MARK: - Login item

public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case notRegistered
    /// O usuário desabilitou nos Ajustes do Sistema; só ele pode reverter.
    case requiresApproval
    case unavailable(reason: String)
}

public protocol LoginItemManager: Sendable {
    func status() async -> LoginItemStatus
    func setEnabled(_ enabled: Bool) async throws
    func openSystemSettings() async
}

// MARK: - Ciclo de vida do sistema

public enum SystemEvent: Sendable, Equatable {
    case didLogin
    /// Acordou do sono, com a duração medida por relógio monotônico.
    case didWake(sleptFor: TimeInterval)
    case willSleep
    case screenLocked
    case screenUnlocked
    case willTerminate
}

public protocol SystemEventSource: Sendable {
    func events() -> AsyncStream<SystemEvent>
}
