import Foundation

// MARK: - Entrada e saída

public struct ResolutionInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var profiles: [Profile]
    public var holiday: HolidayLookup
    public var holidayBehavior: HolidayBehavior
    public var fireLog: FireLog
    public var trigger: Trigger
    /// Quanto tempo o Mac dormiu. `nil` quando o gatilho não é wake.
    public var sleepDuration: TimeInterval?
    public var wakeThreshold: TimeInterval

    public init(
        now: Date,
        calendar: Calendar,
        profiles: [Profile],
        holiday: HolidayLookup = .notHoliday,
        holidayBehavior: HolidayBehavior = .ask,
        fireLog: FireLog = FireLog(),
        trigger: Trigger = .manual,
        sleepDuration: TimeInterval? = nil,
        wakeThreshold: TimeInterval = 4 * 3600
    ) {
        self.now = now
        self.calendar = calendar
        self.profiles = profiles
        self.holiday = holiday
        self.holidayBehavior = holidayBehavior
        self.fireLog = fireLog
        self.trigger = trigger
        self.sleepDuration = sleepDuration
        self.wakeThreshold = wakeThreshold
    }
}

public enum SkipReason: Sendable, Equatable {
    case noMatchingProfile
    case alreadyFiredToday(UUID)
    case alreadyPending(UUID)
    case sleepTooShort(TimeInterval)
    case holidaySkipped(UUID)
    case profileDisabled
}

public enum Resolution: Sendable, Equatable {
    /// Perfil escolhido; o app ainda pede confirmação antes de abrir.
    case fire(Profile, windowDay: String)
    /// Feriado em dia útil: o prompt muda de texto.
    case askHolidayConfirmation(Profile, windowDay: String, holidayNames: [String])
    case skip(reason: SkipReason)

    public var profile: Profile? {
        switch self {
        case .fire(let p, _), .askHolidayConfirmation(let p, _, _): p
        case .skip: nil
        }
    }

    public var windowDay: String? {
        switch self {
        case .fire(_, let day), .askHolidayConfirmation(_, let day, _): day
        case .skip: nil
        }
    }
}

// MARK: - Candidato interno

/// Um perfil que casou com o instante, junto do dia a que a janela pertence.
struct ProfileCandidate: Equatable {
    var profile: Profile
    var windowDay: String
    /// Minutos entre o início da janela e `now`, para desempate.
    var minutesSinceStart: Int
    /// Casou pela tolerância pós-janela, não por estar dentro dela.
    var matchedViaGrace: Bool
}

// MARK: - Resolver

public enum ProfileResolver {

    /// Decide qual perfil (se algum) deve disparar. Função pura: sem I/O, sem relógio global.
    public static func resolve(_ input: ResolutionInput) -> Resolution {
        // 1. Wake curto demais: sai cedo, é o caso mais barato.
        if input.trigger == .wake, let slept = input.sleepDuration, slept < input.wakeThreshold {
            return .skip(reason: .sleepTooShort(slept))
        }

        // 2. Candidatos.
        let candidates = self.candidates(for: input)
        guard !candidates.isEmpty else { return .skip(reason: .noMatchingProfile) }

        // 3. Um perfil por disparo — abrir dois ambientes sobrepostos é pior que escolher errado.
        guard let winner = bestCandidate(among: candidates) else {
            return .skip(reason: .noMatchingProfile)
        }

        // 4. Dedupe.
        if winner.profile.dedupeScope != .always {
            if input.fireLog.hasFired(profileID: winner.profile.id, windowDay: winner.windowDay) {
                return .skip(reason: .alreadyFiredToday(winner.profile.id))
            }
            if input.fireLog.pendingDecision(
                profileID: winner.profile.id, windowDay: winner.windowDay) != nil
            {
                return .skip(reason: .alreadyPending(winner.profile.id))
            }
        }

        // 5. Feriado — só depois de escolher o perfil.
        return applyHolidayPolicy(to: winner, input: input)
    }

    // MARK: Candidatos

    static func candidates(for input: ResolutionInput) -> [ProfileCandidate] {
        let minutesNow = minutesSinceMidnight(input.now, calendar: input.calendar)
        guard let weekdayNow = weekday(of: input.now, calendar: input.calendar) else { return [] }

        var result: [ProfileCandidate] = []

        for profile in input.profiles where profile.isEnabled {
            let window = profile.window

            if window.contains(minutes: minutesNow) {
                // Janela que virou o dia e estamos na madrugada: a janela pertence a ontem,
                // então quem manda é o dia da semana de ontem.
                let inPostMidnight = window.isInPostMidnightSegment(minutes: minutesNow)
                let effectiveWeekday = inPostMidnight ? weekdayNow.previous : weekdayNow
                guard profile.weekdays.contains(effectiveWeekday) else { continue }

                guard let day = windowDay(
                    for: input.now, shiftedBackOneDay: inPostMidnight, calendar: input.calendar)
                else { continue }

                let elapsed = inPostMidnight
                    ? (1440 - window.startMinutes) + minutesNow
                    : minutesNow - window.startMinutes

                result.append(ProfileCandidate(
                    profile: profile,
                    windowDay: day,
                    minutesSinceStart: elapsed,
                    matchedViaGrace: false
                ))
                continue
            }

            // Fora da janela, mas dentro da tolerância: "liguei o Mac 9h15 e o perfil era 8h–9h".
            if profile.graceMinutes > 0,
               let grace = graceCandidate(
                   profile: profile,
                   minutesNow: minutesNow,
                   weekdayNow: weekdayNow,
                   input: input)
            {
                result.append(grace)
            }
        }

        return result
    }

    private static func graceCandidate(
        profile: Profile,
        minutesNow: Int,
        weekdayNow: Weekday,
        input: ResolutionInput
    ) -> ProfileCandidate? {
        let window = profile.window
        guard !window.isAllDay else { return nil }

        // Minutos desde o fim da janela, considerando que ela pode ter virado o dia.
        let sinceEnd: Int
        let endedYesterday: Bool
        if minutesNow >= window.endMinutes {
            sinceEnd = minutesNow - window.endMinutes
            endedYesterday = false
        } else {
            sinceEnd = (1440 - window.endMinutes) + minutesNow
            endedYesterday = true
        }

        guard sinceEnd > 0, sinceEnd <= profile.graceMinutes else { return nil }

        // O dia da janela é o do seu início, que pode ser até dois dias atrás
        // no caso de uma janela que vira o dia e cuja tolerância também vira.
        let daysBack: Int
        if window.crossesMidnight {
            daysBack = endedYesterday ? 2 : 1
        } else {
            daysBack = endedYesterday ? 1 : 0
        }

        guard let startDay = shiftDay(input.now, by: -daysBack, calendar: input.calendar),
              let startWeekday = weekday(of: startDay, calendar: input.calendar),
              profile.weekdays.contains(startWeekday),
              let day = dayString(startDay, calendar: input.calendar)
        else { return nil }

        return ProfileCandidate(
            profile: profile,
            windowDay: day,
            minutesSinceStart: window.durationMinutes + sinceEnd,
            matchedViaGrace: true
        )
    }

    // MARK: Desempate

    /// Cascata determinística: dentro da janela > prioridade > janela mais estreita >
    /// começou mais recentemente > UUID. O último critério existe para os testes.
    static func bestCandidate(among candidates: [ProfileCandidate]) -> ProfileCandidate? {
        candidates.min { a, b in
            if a.matchedViaGrace != b.matchedViaGrace { return !a.matchedViaGrace }
            if a.profile.priority != b.profile.priority { return a.profile.priority > b.profile.priority }

            let aWidth = a.profile.window.durationMinutes
            let bWidth = b.profile.window.durationMinutes
            if aWidth != bWidth { return aWidth < bWidth }

            if a.minutesSinceStart != b.minutesSinceStart {
                return a.minutesSinceStart < b.minutesSinceStart
            }
            return a.profile.id.uuidString < b.profile.id.uuidString
        }
    }

    // MARK: Feriado

    static func applyHolidayPolicy(
        to candidate: ProfileCandidate,
        input: ResolutionInput
    ) -> Resolution {
        let profile = candidate.profile

        // Sem permissão de calendário o app se comporta como num dia normal.
        // Nunca travar o usuário por falta de acesso.
        guard case .holiday(let names) = input.holiday else {
            return .fire(profile, windowDay: candidate.windowDay)
        }

        guard input.holidayBehavior != .ignore, profile.skipOnHoliday else {
            return .fire(profile, windowDay: candidate.windowDay)
        }

        if input.holidayBehavior == .alwaysSkip {
            return .skip(reason: .holidaySkipped(profile.id))
        }

        // Feriado no fim de semana não muda nada — perguntar seria só ruído.
        guard let dayDate = date(fromDayString: candidate.windowDay, calendar: input.calendar),
              let dayWeekday = weekday(of: dayDate, calendar: input.calendar),
              dayWeekday.isWorkday
        else {
            return .skip(reason: .holidaySkipped(profile.id))
        }

        return .askHolidayConfirmation(
            profile, windowDay: candidate.windowDay, holidayNames: names)
    }

    // MARK: Utilidades de calendário

    static func minutesSinceMidnight(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func weekday(of date: Date, calendar: Calendar) -> Weekday? {
        guard let raw = calendar.dateComponents([.weekday], from: date).weekday else { return nil }
        return Weekday(rawValue: raw)
    }

    static func shiftDay(_ date: Date, by days: Int, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: days, to: date)
    }

    /// Identificador estável do dia ("2026-09-17"), montado sem DateFormatter
    /// para não depender de locale nem de comportamento de ICU entre plataformas.
    public static func dayString(_ date: Date, calendar: Calendar) -> String? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = parts.year, let m = parts.month, let d = parts.day else { return nil }
        let mm = m < 10 ? "0\(m)" : "\(m)"
        let dd = d < 10 ? "0\(d)" : "\(d)"
        return "\(y)-\(mm)-\(dd)"
    }

    static func windowDay(
        for date: Date,
        shiftedBackOneDay: Bool,
        calendar: Calendar
    ) -> String? {
        let target = shiftedBackOneDay
            ? calendar.date(byAdding: .day, value: -1, to: date)
            : date
        guard let target else { return nil }
        return dayString(target, calendar: calendar)
    }

    static func date(fromDayString day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = y
        components.month = m
        components.day = d
        components.hour = 12  // meio-dia evita a hora inexistente nos dias de mudança de DST
        return calendar.date(from: components)
    }
}

// MARK: - Saudação

public enum GreetingResolver {

    public struct Rendered: Sendable, Equatable {
        public var title: String
        public var body: String
    }

    /// "Bom dia" até 12h, "Boa tarde" até 18h, "Boa noite" depois.
    public static func timeOfDaySalutation(_ date: Date, calendar: Calendar) -> String {
        let hour = calendar.dateComponents([.hour], from: date).hour ?? 0
        switch hour {
        case 5..<12: return "Bom dia"
        case 12..<18: return "Boa tarde"
        default: return "Boa noite"
        }
    }

    public static func render(
        profile: Profile,
        at date: Date,
        calendar: Calendar,
        itemCount: Int
    ) -> Rendered {
        if profile.greeting.style == .custom {
            return Rendered(
                title: profile.greeting.title ?? profile.name,
                body: profile.greeting.body ?? defaultBody(profile: profile, itemCount: itemCount)
            )
        }
        let salutation = timeOfDaySalutation(date, calendar: calendar)
        return Rendered(
            title: "\(salutation)!",
            body: defaultBody(profile: profile, itemCount: itemCount)
        )
    }

    public static func renderHolidayPrompt(
        profile: Profile,
        holidayNames: [String]
    ) -> Rendered {
        let name = holidayNames.first ?? "Feriado"
        return Rendered(
            title: "Hoje é feriado: \(name)",
            body: "Vai trabalhar hoje? Se sim, abro o perfil \(profile.name)."
        )
    }

    private static func defaultBody(profile: Profile, itemCount: Int) -> String {
        let plural = itemCount == 1 ? "item" : "itens"
        return "Perfil \(profile.name) pronto — \(itemCount) \(plural) para abrir."
    }
}
