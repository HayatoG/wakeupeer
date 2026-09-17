import Foundation
import Testing

@testable import WakeUpeerDomain

// MARK: - Helpers

private func makeCalendar(_ timeZoneID: String = "America/Sao_Paulo") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneID)!
    calendar.firstWeekday = 2  // segunda, como no Brasil
    return calendar
}

/// Constrói uma data a partir de componentes locais do calendário dado.
private func date(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int = 0, _ minute: Int = 0,
    calendar: Calendar
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components)!
}

private func makeProfile(
    id: UUID = UUID(),
    name: String = "Teste",
    weekdays: Set<Weekday> = Weekday.workdays,
    window: TimeWindow = TimeWindow(from: 8, to: 17),
    skipOnHoliday: Bool = false,
    priority: Int = 0,
    graceMinutes: Int = 0,
    isEnabled: Bool = true,
    dedupeScope: DedupeScope = .oncePerDay
) -> Profile {
    Profile(
        id: id,
        name: name,
        isEnabled: isEnabled,
        weekdays: weekdays,
        window: window,
        items: [ProfileItem(item: .url(URL(string: "https://example.com")!))],
        skipOnHoliday: skipOnHoliday,
        priority: priority,
        graceMinutes: graceMinutes,
        dedupeScope: dedupeScope
    )
}

private func input(
    now: Date,
    calendar: Calendar,
    profiles: [Profile],
    holiday: HolidayLookup = .notHoliday,
    holidayBehavior: HolidayBehavior = .ask,
    fireLog: FireLog = FireLog(),
    trigger: Trigger = .login,
    sleepDuration: TimeInterval? = nil,
    wakeThreshold: TimeInterval = 4 * 3600
) -> ResolutionInput {
    ResolutionInput(
        now: now,
        calendar: calendar,
        profiles: profiles,
        holiday: holiday,
        holidayBehavior: holidayBehavior,
        fireLog: fireLog,
        trigger: trigger,
        sleepDuration: sleepDuration,
        wakeThreshold: wakeThreshold
    )
}

// MARK: - Bordas da janela

@Suite("Bordas da janela")
struct WindowBoundaryTests {

    @Test("Início da janela é inclusivo: 08:00 dispara")
    func startIsInclusive() {
        let cal = makeCalendar()
        let profile = makeProfile()
        // 2026-09-17 é uma quinta-feira.
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 17, 8, 0, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result.profile?.id == profile.id)
    }

    @Test("Fim da janela é exclusivo: 17:00 não dispara")
    func endIsExclusive() {
        let cal = makeCalendar()
        let profile = makeProfile()
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 17, 17, 0, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result == .skip(reason: .noMatchingProfile))
    }

    @Test("Um minuto antes do fim ainda dispara")
    func justBeforeEnd() {
        let cal = makeCalendar()
        let profile = makeProfile()
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 17, 16, 59, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result.profile?.id == profile.id)
    }

    @Test("Dia da semana fora do perfil não dispara")
    func wrongWeekday() {
        let cal = makeCalendar()
        let profile = makeProfile(weekdays: Weekday.workdays)
        // 2026-09-19 é sábado.
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 19, 10, 0, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result == .skip(reason: .noMatchingProfile))
    }

    @Test("Perfil desabilitado nunca entra como candidato")
    func disabledProfile() {
        let cal = makeCalendar()
        let profile = makeProfile(isEnabled: false)
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result == .skip(reason: .noMatchingProfile))
    }

    @Test("Janela de dia inteiro cobre qualquer horário")
    func allDayWindow() {
        let cal = makeCalendar()
        let profile = makeProfile(
            weekdays: Weekday.everyDay,
            window: TimeWindow(startMinutes: 0, endMinutes: 0))
        for hour in [0, 6, 13, 23] {
            let result = ProfileResolver.resolve(
                input(
                    now: date(2026, 9, 17, hour, 30, calendar: cal), calendar: cal,
                    profiles: [profile]))
            #expect(result.profile?.id == profile.id, "falhou às \(hour)h")
        }
    }
}

// MARK: - Meia-noite

@Suite("Janela que atravessa a meia-noite")
struct MidnightCrossingTests {

    /// Perfil ativo apenas na segunda-feira, das 22:00 às 02:00.
    private func mondayLateProfile() -> Profile {
        makeProfile(weekdays: [.monday], window: TimeWindow(from: 22, to: 2))
    }

    @Test("22:01 de segunda dispara, com windowDay na segunda")
    func mondayNight() {
        let cal = makeCalendar()
        let profile = mondayLateProfile()
        // 2026-09-14 é segunda-feira.
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 14, 22, 1, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result.profile?.id == profile.id)
        #expect(result.windowDay == "2026-09-14")
    }

    @Test("01:00 de terça ainda dispara, e o windowDay continua sendo a segunda")
    func tuesdayEarlyMorningBelongsToMonday() {
        let cal = makeCalendar()
        let profile = mondayLateProfile()
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 15, 1, 0, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result.profile?.id == profile.id)
        #expect(result.windowDay == "2026-09-14", "a madrugada de terça pertence à janela de segunda")
    }

    @Test("03:00 de terça está fora da janela")
    func tuesdayAfterWindow() {
        let cal = makeCalendar()
        let profile = mondayLateProfile()
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 15, 3, 0, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result == .skip(reason: .noMatchingProfile))
    }

    @Test("01:00 de segunda não dispara: pertenceria ao domingo, que está fora do perfil")
    func mondayEarlyMorningBelongsToSunday() {
        let cal = makeCalendar()
        let profile = mondayLateProfile()
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 14, 1, 0, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result == .skip(reason: .noMatchingProfile))
    }

    @Test("Perfil de madrugada todo dia dispara na virada sem duplicar")
    func lateNightEveryDayDoesNotDuplicate() {
        let cal = makeCalendar()
        let profile = makeProfile(
            weekdays: Weekday.everyDay, window: TimeWindow(from: 23, to: 6))

        let beforeMidnight = ProfileResolver.resolve(
            input(now: date(2026, 9, 17, 23, 30, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(beforeMidnight.windowDay == "2026-09-17")

        // Depois de disparar às 23h30, 01h da manhã seguinte é a MESMA janela.
        let log = FireLog(records: [
            FireRecord(
                profileID: profile.id,
                firedAt: date(2026, 9, 17, 23, 30, calendar: cal),
                windowDay: "2026-09-17",
                trigger: .login)
        ])
        let afterMidnight = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 18, 1, 0, calendar: cal), calendar: cal, profiles: [profile],
                fireLog: log))
        #expect(afterMidnight == .skip(reason: .alreadyFiredToday(profile.id)))
    }
}

// MARK: - Deduplicação

@Suite("Deduplicação")
struct DedupeTests {

    @Test("Mesmo perfil no mesmo windowDay não dispara duas vezes")
    func sameDaySkips() {
        let cal = makeCalendar()
        let profile = makeProfile()
        let log = FireLog(records: [
            FireRecord(
                profileID: profile.id,
                firedAt: date(2026, 9, 17, 8, 5, calendar: cal),
                windowDay: "2026-09-17",
                trigger: .login)
        ])
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal, profiles: [profile],
                fireLog: log))
        #expect(result == .skip(reason: .alreadyFiredToday(profile.id)))
    }

    @Test("Dia seguinte dispara de novo")
    func nextDayFires() {
        let cal = makeCalendar()
        let profile = makeProfile()
        let log = FireLog(records: [
            FireRecord(
                profileID: profile.id,
                firedAt: date(2026, 9, 17, 8, 5, calendar: cal),
                windowDay: "2026-09-17",
                trigger: .login)
        ])
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 18, 10, 0, calendar: cal), calendar: cal, profiles: [profile],
                fireLog: log))
        #expect(result.profile?.id == profile.id)
        #expect(result.windowDay == "2026-09-18")
    }

    @Test("Prompt já pendente não gera outro prompt")
    func pendingBlocksRepeat() {
        let cal = makeCalendar()
        let profile = makeProfile()
        let log = FireLog(pending: [
            PendingDecision(
                profileID: profile.id,
                windowDay: "2026-09-17",
                askedAt: date(2026, 9, 17, 8, 5, calendar: cal))
        ])
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal, profiles: [profile],
                fireLog: log))
        #expect(result == .skip(reason: .alreadyPending(profile.id)))
    }

    @Test("dedupeScope .always ignora o histórico")
    func alwaysScopeIgnoresLog() {
        let cal = makeCalendar()
        let profile = makeProfile(dedupeScope: .always)
        let log = FireLog(records: [
            FireRecord(
                profileID: profile.id,
                firedAt: date(2026, 9, 17, 8, 5, calendar: cal),
                windowDay: "2026-09-17",
                trigger: .login)
        ])
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal, profiles: [profile],
                fireLog: log))
        #expect(result.profile?.id == profile.id)
    }
}

// MARK: - Sobreposição

@Suite("Sobreposição de perfis")
struct OverlapTests {

    @Test("Maior prioridade vence")
    func priorityWins() {
        let cal = makeCalendar()
        let low = makeProfile(name: "Baixa", priority: 1)
        let high = makeProfile(name: "Alta", priority: 10)
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal,
                profiles: [low, high]))
        #expect(result.profile?.id == high.id)
    }

    @Test("Com prioridades iguais, a janela mais estreita vence")
    func narrowerWindowWins() {
        let cal = makeCalendar()
        let broad = makeProfile(name: "Amplo", window: TimeWindow(from: 8, to: 18))
        let narrow = makeProfile(
            name: "Reunião", window: TimeWindow(startMinutes: 9 * 60, endMinutes: 10 * 60))
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 9, 30, calendar: cal), calendar: cal,
                profiles: [broad, narrow]))
        #expect(result.profile?.id == narrow.id)
    }

    @Test("Perfis idênticos resolvem sempre para o mesmo, em qualquer ordem")
    func deterministicTieBreak() {
        let cal = makeCalendar()
        let a = makeProfile(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
        let b = makeProfile(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!)
        let now = date(2026, 9, 17, 10, 0, calendar: cal)

        var seen = Set<UUID>()
        for _ in 0..<100 {
            let profiles = Bool.random() ? [a, b] : [b, a]
            let result = ProfileResolver.resolve(
                input(now: now, calendar: cal, profiles: profiles))
            if let id = result.profile?.id { seen.insert(id) }
        }
        #expect(seen.count == 1, "o desempate deve ser determinístico")
        #expect(seen.first == a.id, "o menor UUID vence")
    }

    @Test("Um perfil dentro da janela vence outro que só casou pela tolerância")
    func inWindowBeatsGrace() {
        let cal = makeCalendar()
        let graced = makeProfile(
            name: "Terminou", window: TimeWindow(from: 6, to: 9), priority: 99, graceMinutes: 120)
        let active = makeProfile(name: "Ativo", window: TimeWindow(from: 9, to: 18), priority: 0)
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal,
                profiles: [graced, active]))
        #expect(result.profile?.id == active.id, "estar na janela importa mais que prioridade")
    }
}

// MARK: - Tolerância

@Suite("Tolerância após o fim da janela")
struct GraceTests {

    @Test("09:15 com janela 08–09 e tolerância de 90 min dispara")
    func withinGrace() {
        let cal = makeCalendar()
        let profile = makeProfile(
            window: TimeWindow(startMinutes: 8 * 60, endMinutes: 9 * 60), graceMinutes: 90)
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 17, 9, 15, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result.profile?.id == profile.id)
        #expect(result.windowDay == "2026-09-17")
    }

    @Test("Sem tolerância, o mesmo horário não dispara")
    func withoutGrace() {
        let cal = makeCalendar()
        let profile = makeProfile(
            window: TimeWindow(startMinutes: 8 * 60, endMinutes: 9 * 60), graceMinutes: 0)
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 17, 9, 15, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result == .skip(reason: .noMatchingProfile))
    }

    @Test("Passar da tolerância não dispara")
    func beyondGrace() {
        let cal = makeCalendar()
        let profile = makeProfile(
            window: TimeWindow(startMinutes: 8 * 60, endMinutes: 9 * 60), graceMinutes: 30)
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result == .skip(reason: .noMatchingProfile))
    }

    @Test("A tolerância respeita o dedupe")
    func graceRespectsDedupe() {
        let cal = makeCalendar()
        let profile = makeProfile(
            window: TimeWindow(startMinutes: 8 * 60, endMinutes: 9 * 60), graceMinutes: 90)
        let log = FireLog(records: [
            FireRecord(
                profileID: profile.id,
                firedAt: date(2026, 9, 17, 8, 10, calendar: cal),
                windowDay: "2026-09-17",
                trigger: .login)
        ])
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 9, 15, calendar: cal), calendar: cal, profiles: [profile],
                fireLog: log))
        #expect(result == .skip(reason: .alreadyFiredToday(profile.id)))
    }

    @Test("A tolerância checa o dia da semana do início da janela")
    func graceChecksStartWeekday() {
        let cal = makeCalendar()
        // Só segunda, 08–09, com tolerância. Terça de manhã não deve pegar carona.
        let profile = makeProfile(
            weekdays: [.monday],
            window: TimeWindow(startMinutes: 8 * 60, endMinutes: 9 * 60),
            graceMinutes: 90)
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 15, 9, 15, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result == .skip(reason: .noMatchingProfile))
    }
}

// MARK: - Wake

@Suite("Threshold de wake")
struct WakeThresholdTests {

    @Test("Sono de 2h com threshold de 4h não dispara")
    func shortSleepSkips() {
        let cal = makeCalendar()
        let profile = makeProfile()
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal, profiles: [profile],
                trigger: .wake, sleepDuration: 2 * 3600, wakeThreshold: 4 * 3600))
        #expect(result == .skip(reason: .sleepTooShort(2 * 3600)))
    }

    @Test("Sono de 5h com threshold de 4h dispara")
    func longSleepFires() {
        let cal = makeCalendar()
        let profile = makeProfile()
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal, profiles: [profile],
                trigger: .wake, sleepDuration: 5 * 3600, wakeThreshold: 4 * 3600))
        #expect(result.profile?.id == profile.id)
    }

    @Test("Login ignora o threshold")
    func loginIgnoresThreshold() {
        let cal = makeCalendar()
        let profile = makeProfile()
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal, profiles: [profile],
                trigger: .login, sleepDuration: 60, wakeThreshold: 4 * 3600))
        #expect(result.profile?.id == profile.id)
    }

    @Test("Disparo manual ignora o threshold")
    func manualIgnoresThreshold() {
        let cal = makeCalendar()
        let profile = makeProfile()
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal, profiles: [profile],
                trigger: .manual, sleepDuration: 60))
        #expect(result.profile?.id == profile.id)
    }
}

// MARK: - Feriados

@Suite("Política de feriado")
struct HolidayTests {

    @Test("Feriado em dia útil, perfil de trabalho: pergunta")
    func weekdayHolidayAsks() {
        let cal = makeCalendar()
        let profile = makeProfile(skipOnHoliday: true)
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 7, 9, 0, calendar: cal), calendar: cal, profiles: [profile],
                holiday: .holiday(names: ["Independência do Brasil"])))
        #expect(
            result
                == .askHolidayConfirmation(
                    profile, windowDay: "2026-09-07",
                    holidayNames: ["Independência do Brasil"]))
    }

    @Test("Feriado no fim de semana não pergunta nada")
    func weekendHolidayIsSilent() {
        let cal = makeCalendar()
        let profile = makeProfile(
            weekdays: Weekday.everyDay, window: TimeWindow(from: 8, to: 17), skipOnHoliday: true)
        // 2026-11-15 é domingo.
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 11, 15, 9, 0, calendar: cal), calendar: cal, profiles: [profile],
                holiday: .holiday(names: ["Proclamação da República"])))
        #expect(result == .skip(reason: .holidaySkipped(profile.id)))
    }

    @Test("Perfil de lazer dispara normalmente no feriado")
    func leisureProfileFiresOnHoliday() {
        let cal = makeCalendar()
        let profile = makeProfile(skipOnHoliday: false)
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 7, 9, 0, calendar: cal), calendar: cal, profiles: [profile],
                holiday: .holiday(names: ["Independência do Brasil"])))
        #expect(result.profile?.id == profile.id)
    }

    @Test("Sem acesso ao calendário, comporta-se como dia normal")
    func unavailableBehavesAsNormalDay() {
        let cal = makeCalendar()
        let profile = makeProfile(skipOnHoliday: true)
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 17, 9, 0, calendar: cal), calendar: cal, profiles: [profile],
                holiday: .unavailable(reason: "permissão negada")))
        #expect(result.profile?.id == profile.id, "falta de permissão nunca bloqueia o usuário")
    }

    @Test("Política .alwaysSkip nunca pergunta")
    func alwaysSkipNeverAsks() {
        let cal = makeCalendar()
        let profile = makeProfile(skipOnHoliday: true)
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 7, 9, 0, calendar: cal), calendar: cal, profiles: [profile],
                holiday: .holiday(names: ["Independência do Brasil"]),
                holidayBehavior: .alwaysSkip))
        #expect(result == .skip(reason: .holidaySkipped(profile.id)))
    }

    @Test("Política .ignore trata feriado como dia comum")
    func ignoreTreatsAsNormal() {
        let cal = makeCalendar()
        let profile = makeProfile(skipOnHoliday: true)
        let result = ProfileResolver.resolve(
            input(
                now: date(2026, 9, 7, 9, 0, calendar: cal), calendar: cal, profiles: [profile],
                holiday: .holiday(names: ["Independência do Brasil"]),
                holidayBehavior: .ignore))
        #expect(result.profile?.id == profile.id)
    }
}

// MARK: - Fusos horários

@Suite("Fusos horários")
struct TimeZoneTests {

    @Test(
        "A mesma regra vale em qualquer fuso",
        arguments: ["America/Sao_Paulo", "UTC", "Pacific/Kiritimati", "America/New_York"])
    func consistentAcrossTimeZones(timeZoneID: String) {
        let cal = makeCalendar(timeZoneID)
        let profile = makeProfile()
        // 10:00 locais é sempre dentro da janela 08–17, seja qual for o fuso.
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 17, 10, 0, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result.profile?.id == profile.id)
        #expect(result.windowDay == "2026-09-17")
    }

    @Test(
        "A virada da meia-noite é consistente em qualquer fuso",
        arguments: ["America/Sao_Paulo", "UTC", "Pacific/Kiritimati"])
    func midnightConsistentAcrossTimeZones(timeZoneID: String) {
        let cal = makeCalendar(timeZoneID)
        let profile = makeProfile(weekdays: [.thursday], window: TimeWindow(from: 22, to: 2))
        // 2026-09-17 é quinta; 01:00 de sexta pertence à janela de quinta.
        let result = ProfileResolver.resolve(
            input(now: date(2026, 9, 18, 1, 0, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result.windowDay == "2026-09-17")
    }
}

// MARK: - Horário de verão

@Suite("Horário de verão")
struct DaylightSavingTests {

    @Test("A hora que não existe no spring-forward não quebra o resolver")
    func springForwardDoesNotCrash() {
        let cal = makeCalendar("America/New_York")
        let profile = makeProfile(
            weekdays: Weekday.everyDay, window: TimeWindow(from: 1, to: 5))
        // 2026-03-08: o relógio pula de 02:00 para 03:00 em Nova York.
        let result = ProfileResolver.resolve(
            input(now: date(2026, 3, 8, 2, 30, calendar: cal), calendar: cal, profiles: [profile]))
        #expect(result.profile != nil)
    }

    @Test("A hora duplicada no fall-back não dispara duas vezes")
    func fallBackDoesNotDoubleFire() {
        let cal = makeCalendar("America/New_York")
        let profile = makeProfile(
            weekdays: Weekday.everyDay, window: TimeWindow(from: 1, to: 5))
        // 2026-11-01: 01:30 acontece duas vezes; ambas caem no mesmo windowDay.
        let first = ProfileResolver.resolve(
            input(now: date(2026, 11, 1, 1, 30, calendar: cal), calendar: cal, profiles: [profile]))
        guard let day = first.windowDay else {
            Issue.record("o primeiro disparo deveria ter um windowDay")
            return
        }

        let log = FireLog(records: [
            FireRecord(
                profileID: profile.id, firedAt: first.profile.map { _ in Date() } ?? Date(),
                windowDay: day, trigger: .login)
        ])
        let second = ProfileResolver.resolve(
            input(
                now: date(2026, 11, 1, 1, 30, calendar: cal).addingTimeInterval(3600),
                calendar: cal, profiles: [profile], fireLog: log))
        #expect(second == .skip(reason: .alreadyFiredToday(profile.id)))
    }
}

// MARK: - Saudação

@Suite("Saudação")
struct GreetingTests {

    @Test(
        "A saudação acompanha o horário",
        arguments: [
            (6, "Bom dia"), (11, "Bom dia"), (12, "Boa tarde"), (17, "Boa tarde"),
            (18, "Boa noite"), (23, "Boa noite"), (3, "Boa noite"),
        ])
    func salutationByHour(hour: Int, expected: String) {
        let cal = makeCalendar()
        let salutation = GreetingResolver.timeOfDaySalutation(
            date(2026, 9, 17, hour, 0, calendar: cal), calendar: cal)
        #expect(salutation == expected)
    }

    @Test("Saudação customizada tem precedência")
    func customGreetingWins() {
        let cal = makeCalendar()
        var profile = makeProfile()
        profile.greeting = Greeting(style: .custom, title: "Fala!", body: "Bora codar")
        let rendered = GreetingResolver.render(
            profile: profile, at: date(2026, 9, 17, 9, 0, calendar: cal), calendar: cal,
            itemCount: 3)
        #expect(rendered.title == "Fala!")
        #expect(rendered.body == "Bora codar")
    }

    @Test("O corpo padrão faz a concordância de singular e plural")
    func defaultBodyPluralization() {
        let cal = makeCalendar()
        let profile = makeProfile(name: "Trabalho")
        let one = GreetingResolver.render(
            profile: profile, at: date(2026, 9, 17, 9, 0, calendar: cal), calendar: cal,
            itemCount: 1)
        #expect(one.body.contains("1 item"))

        let many = GreetingResolver.render(
            profile: profile, at: date(2026, 9, 17, 9, 0, calendar: cal), calendar: cal,
            itemCount: 5)
        #expect(many.body.contains("5 itens"))
    }
}
