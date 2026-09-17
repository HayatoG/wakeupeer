import Foundation

// MARK: - Dias da semana

/// Dia da semana com os mesmos números do `Calendar` da Apple (domingo = 1),
/// para converter sem tabela de/para.
public enum Weekday: Int, Codable, Hashable, Sendable, CaseIterable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public var isWeekend: Bool { self == .saturday || self == .sunday }
    public var isWorkday: Bool { !isWeekend }

    /// O dia anterior, usado para resolver janelas que atravessam a meia-noite.
    public var previous: Weekday {
        Weekday(rawValue: rawValue == 1 ? 7 : rawValue - 1)!
    }

    public static let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: Set<Weekday> = [.saturday, .sunday]
    public static let everyDay: Set<Weekday> = Set(Weekday.allCases)
}

// MARK: - Janela de horário

/// Intervalo de horário em minutos desde a meia-noite local.
///
/// Quando `end <= start` a janela atravessa a meia-noite (ex.: 22:00–02:00).
/// Quando `start == end` a janela cobre o dia inteiro.
public struct TimeWindow: Codable, Hashable, Sendable {
    public var startMinutes: Int
    public var endMinutes: Int

    public init(startMinutes: Int, endMinutes: Int) {
        self.startMinutes = max(0, min(1439, startMinutes))
        self.endMinutes = max(0, min(1439, endMinutes))
    }

    public init(from startHour: Int, to endHour: Int) {
        self.init(startMinutes: startHour * 60, endMinutes: endHour * 60)
    }

    public var crossesMidnight: Bool { endMinutes <= startMinutes && !isAllDay }
    public var isAllDay: Bool { startMinutes == endMinutes }

    /// Duração da janela em minutos, já lidando com a virada do dia.
    public var durationMinutes: Int {
        if isAllDay { return 1440 }
        if crossesMidnight { return (1440 - startMinutes) + endMinutes }
        return endMinutes - startMinutes
    }

    /// Só checa o horário; o dia da semana é responsabilidade do resolver.
    public func contains(minutes: Int) -> Bool {
        if isAllDay { return true }
        if crossesMidnight { return minutes >= startMinutes || minutes < endMinutes }
        return minutes >= startMinutes && minutes < endMinutes
    }

    /// `true` quando o instante cai no trecho pós-meia-noite de uma janela que vira o dia.
    /// Nesse caso a janela "pertence" ao dia anterior.
    public func isInPostMidnightSegment(minutes: Int) -> Bool {
        crossesMidnight && minutes < endMinutes
    }
}

// MARK: - Itens a abrir

public enum LaunchItem: Codable, Hashable, Sendable, Identifiable {
    case application(bundleID: String, displayName: String, path: String?)
    case url(URL)
    case file(path: String)
    /// Executável e argumentos separados — nunca uma string passada a um shell.
    case shell(command: String, args: [String])

    public var id: String {
        switch self {
        case .application(let bundleID, _, _): "app:\(bundleID)"
        case .url(let url): "url:\(url.absoluteString)"
        case .file(let path): "file:\(path)"
        case .shell(let command, let args): "shell:\(command) \(args.joined(separator: " "))"
        }
    }

    public var displayName: String {
        switch self {
        case .application(_, let name, _): name
        case .url(let url): url.host ?? url.absoluteString
        case .file(let path): URL(fileURLWithPath: path).lastPathComponent
        case .shell(let command, _): URL(fileURLWithPath: command).lastPathComponent
        }
    }
}

/// Um item de um perfil, com as opções de como abrir.
public struct ProfileItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var item: LaunchItem
    public var isEnabled: Bool
    /// Traz para o primeiro plano ao abrir. No máximo um item por perfil deve usar isso.
    public var bringToFront: Bool
    public var launchHidden: Bool

    public init(
        id: UUID = UUID(),
        item: LaunchItem,
        isEnabled: Bool = true,
        bringToFront: Bool = false,
        launchHidden: Bool = false
    ) {
        self.id = id
        self.item = item
        self.isEnabled = isEnabled
        self.bringToFront = bringToFront
        self.launchHidden = launchHidden
    }
}

// MARK: - Saudação

public struct Greeting: Codable, Hashable, Sendable {
    public enum Style: String, Codable, Sendable {
        /// "Bom dia" / "Boa tarde" / "Boa noite" conforme o horário.
        case automatic
        case custom
    }

    public var style: Style
    public var title: String?
    public var body: String?

    public init(style: Style = .automatic, title: String? = nil, body: String? = nil) {
        self.style = style
        self.title = title
        self.body = body
    }

    public static let automatic = Greeting()
}

// MARK: - Perfil

public enum DedupeScope: String, Codable, Sendable {
    /// Um disparo por dia da janela. O padrão.
    case oncePerDay
    /// Um disparo por ocorrência da janela (idem `oncePerDay` hoje; reservado para janelas repetidas).
    case oncePerWindow
    /// Dispara toda vez que for avaliado.
    case always
}

public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var weekdays: Set<Weekday>
    public var window: TimeWindow
    public var greeting: Greeting
    public var items: [ProfileItem]
    /// Em feriado de dia útil, pergunta antes em vez de abrir direto.
    public var skipOnHoliday: Bool
    /// Desempate de sobreposição: maior vence.
    public var priority: Int
    /// Tolerância após o fim da janela, para quando o Mac é ligado atrasado.
    public var graceMinutes: Int
    public var dedupeScope: DedupeScope
    /// Símbolo SF exibido na barra quando este perfil está ativo.
    public var symbolName: String

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        weekdays: Set<Weekday>,
        window: TimeWindow,
        greeting: Greeting = .automatic,
        items: [ProfileItem] = [],
        skipOnHoliday: Bool = false,
        priority: Int = 0,
        graceMinutes: Int = 0,
        dedupeScope: DedupeScope = .oncePerDay,
        symbolName: String = "sun.max"
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.weekdays = weekdays
        self.window = window
        self.greeting = greeting
        self.items = items
        self.skipOnHoliday = skipOnHoliday
        self.priority = priority
        self.graceMinutes = graceMinutes
        self.dedupeScope = dedupeScope
        self.symbolName = symbolName
    }

    public var enabledItems: [ProfileItem] { items.filter(\.isEnabled) }
}

// MARK: - Feriados

public enum HolidayLookup: Sendable, Equatable {
    case holiday(names: [String])
    case notHoliday
    /// Permissão negada, calendário ausente, erro de leitura. Nunca deve bloquear o usuário.
    case unavailable(reason: String)

    public var isHoliday: Bool {
        if case .holiday = self { return true }
        return false
    }

    public var names: [String] {
        if case .holiday(let names) = self { return names }
        return []
    }
}

public enum HolidayBehavior: String, Codable, Sendable {
    /// Pergunta se vai trabalhar (padrão).
    case ask
    /// Nunca dispara perfis marcados com `skipOnHoliday`.
    case alwaysSkip
    /// Trata feriado como dia normal.
    case ignore
}

// MARK: - Registro de disparos

public enum Trigger: String, Codable, Sendable {
    case login
    case wake
    case manual
    case scheduleBoundary
    case holidayConfirmed
    case holidaySkipped
}

public struct FireRecord: Codable, Hashable, Sendable {
    public var profileID: UUID
    public var firedAt: Date
    /// Dia de referência da janela ("2026-09-17"), na timezone do usuário.
    /// Para janelas que viram o dia, é o dia do **início** da janela.
    public var windowDay: String
    public var trigger: Trigger

    public init(profileID: UUID, firedAt: Date, windowDay: String, trigger: Trigger) {
        self.profileID = profileID
        self.firedAt = firedAt
        self.windowDay = windowDay
        self.trigger = trigger
    }
}

/// Um disparo aguardando confirmação do usuário. Vale até o fim do dia local.
public struct PendingDecision: Codable, Hashable, Sendable {
    public var profileID: UUID
    public var windowDay: String
    public var askedAt: Date
    public var isHolidayPrompt: Bool
    public var holidayNames: [String]

    public init(
        profileID: UUID,
        windowDay: String,
        askedAt: Date,
        isHolidayPrompt: Bool = false,
        holidayNames: [String] = []
    ) {
        self.profileID = profileID
        self.windowDay = windowDay
        self.askedAt = askedAt
        self.isHolidayPrompt = isHolidayPrompt
        self.holidayNames = holidayNames
    }
}

public struct FireLog: Codable, Sendable {
    public var records: [FireRecord]
    public var pending: [PendingDecision]

    public init(records: [FireRecord] = [], pending: [PendingDecision] = []) {
        self.records = records
        self.pending = pending
    }

    public func hasFired(profileID: UUID, windowDay: String) -> Bool {
        records.contains { $0.profileID == profileID && $0.windowDay == windowDay }
    }

    public func pendingDecision(profileID: UUID, windowDay: String) -> PendingDecision? {
        pending.first { $0.profileID == profileID && $0.windowDay == windowDay }
    }
}

// MARK: - Tracking

public struct TrackingConfig: Codable, Sendable {
    public var isEnabled: Bool
    public var sampleIntervalSeconds: Int
    public var idleThresholdSeconds: Int
    public var excludedBundleIDs: Set<String>
    public var retentionDays: Int

    public init(
        isEnabled: Bool = true,
        sampleIntervalSeconds: Int = 15,
        idleThresholdSeconds: Int = 180,
        excludedBundleIDs: Set<String> = [],
        retentionDays: Int = 180
    ) {
        self.isEnabled = isEnabled
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.idleThresholdSeconds = idleThresholdSeconds
        self.excludedBundleIDs = excludedBundleIDs
        self.retentionDays = retentionDays
    }
}

public struct TrackingEvent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case foreground
        case idle
        case sleep
        case locked
    }

    public var start: Date
    public var end: Date
    public var bundleID: String
    public var appName: String
    public var profileID: UUID?
    public var kind: Kind

    public init(
        start: Date,
        end: Date,
        bundleID: String,
        appName: String,
        profileID: UUID? = nil,
        kind: Kind = .foreground
    ) {
        self.start = start
        self.end = end
        self.bundleID = bundleID
        self.appName = appName
        self.profileID = profileID
        self.kind = kind
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

public struct ForegroundSample: Sendable, Equatable {
    public var bundleID: String
    public var appName: String
    public var idleSeconds: TimeInterval

    public init(bundleID: String, appName: String, idleSeconds: TimeInterval) {
        self.bundleID = bundleID
        self.appName = appName
        self.idleSeconds = idleSeconds
    }
}

public struct RunningApp: Sendable, Hashable, Identifiable {
    public var bundleID: String
    public var name: String
    public var isActive: Bool
    public var launchDate: Date?

    public var id: String { bundleID }

    public init(bundleID: String, name: String, isActive: Bool = false, launchDate: Date? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.isActive = isActive
        self.launchDate = launchDate
    }
}

// MARK: - Configuração global

public struct AppConfig: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profiles: [Profile]
    /// Wake do sono só dispara se o Mac dormiu mais do que isto.
    public var wakeThresholdHours: Double
    public var holidayCalendarIDs: [String]
    public var holidayBehavior: HolidayBehavior
    public var tracking: TrackingConfig
    public var launchAtLogin: Bool
    /// `nil` usa a timezone do sistema.
    public var timeZoneID: String?
    /// Intervalo entre lançamentos, para não travar o Dock.
    public var launchDelayMilliseconds: Int
    public var weeklyReportEnabled: Bool
    public var weeklyReportWeekday: Weekday
    public var weeklyReportHour: Int

    public init(
        schemaVersion: Int = AppConfig.currentSchemaVersion,
        profiles: [Profile] = [],
        wakeThresholdHours: Double = 4,
        holidayCalendarIDs: [String] = [],
        holidayBehavior: HolidayBehavior = .ask,
        tracking: TrackingConfig = TrackingConfig(),
        launchAtLogin: Bool = false,
        timeZoneID: String? = nil,
        launchDelayMilliseconds: Int = 600,
        weeklyReportEnabled: Bool = true,
        weeklyReportWeekday: Weekday = .friday,
        weeklyReportHour: Int = 17
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.wakeThresholdHours = wakeThresholdHours
        self.holidayCalendarIDs = holidayCalendarIDs
        self.holidayBehavior = holidayBehavior
        self.tracking = tracking
        self.launchAtLogin = launchAtLogin
        self.timeZoneID = timeZoneID
        self.launchDelayMilliseconds = launchDelayMilliseconds
        self.weeklyReportEnabled = weeklyReportEnabled
        self.weeklyReportWeekday = weeklyReportWeekday
        self.weeklyReportHour = weeklyReportHour
    }

    public var wakeThreshold: TimeInterval { wakeThresholdHours * 3600 }

    public func profile(id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }
}
