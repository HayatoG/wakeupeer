import Foundation
import Testing

@testable import WakeUpeerDomain

private func makeCalendar(_ timeZoneID: String = "America/Sao_Paulo") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneID)!
    calendar.firstWeekday = 2
    return calendar
}

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

private func event(
    _ start: Date, _ end: Date,
    bundleID: String = "com.example.app",
    appName: String = "Exemplo",
    profileID: UUID? = nil,
    kind: TrackingEvent.Kind = .foreground
) -> TrackingEvent {
    TrackingEvent(
        start: start, end: end, bundleID: bundleID, appName: appName,
        profileID: profileID, kind: kind)
}

@Suite("Agregação do relatório")
struct ReportBuilderTests {

    @Test("Soma o tempo por app")
    func sumsPerApp() {
        let cal = makeCalendar()
        let events = [
            event(
                date(2026, 9, 14, 9, 0, calendar: cal), date(2026, 9, 14, 10, 0, calendar: cal),
                bundleID: "a", appName: "App A"),
            event(
                date(2026, 9, 14, 10, 0, calendar: cal), date(2026, 9, 14, 10, 30, calendar: cal),
                bundleID: "b", appName: "App B"),
            event(
                date(2026, 9, 14, 11, 0, calendar: cal), date(2026, 9, 14, 11, 30, calendar: cal),
                bundleID: "a", appName: "App A"),
        ]

        let report = ReportBuilder.build(
            events: events,
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 15, 0, 0, calendar: cal),
            calendar: cal)

        #expect(report.apps.count == 2)
        #expect(report.apps.first?.bundleID == "a", "o mais usado vem primeiro")
        #expect(report.apps.first?.total == 5400)  // 1h + 30min
        #expect(report.totalActive == 7200)
    }

    @Test("Clipa eventos nas bordas do intervalo")
    func clipsAtBoundaries() {
        let cal = makeCalendar()
        // Começa antes e termina depois da janela; só a parte de dentro conta.
        let events = [
            event(
                date(2026, 9, 13, 22, 0, calendar: cal), date(2026, 9, 14, 2, 0, calendar: cal))
        ]

        let report = ReportBuilder.build(
            events: events,
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 15, 0, 0, calendar: cal),
            calendar: cal)

        #expect(report.totalActive == 7200, "só as 2h dentro da janela")
    }

    @Test("Um evento que atravessa a meia-noite conta em cada dia")
    func splitsAcrossMidnight() {
        let cal = makeCalendar()
        let events = [
            event(
                date(2026, 9, 14, 23, 0, calendar: cal), date(2026, 9, 15, 1, 0, calendar: cal))
        ]

        let report = ReportBuilder.build(
            events: events,
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 16, 0, 0, calendar: cal),
            calendar: cal)

        #expect(report.days.count == 2)
        #expect(report.days[0].active == 3600, "1h no dia 14")
        #expect(report.days[1].active == 3600, "1h no dia 15")
        #expect(report.totalActive == 7200, "o total não muda com a divisão")
    }

    @Test("O total é igual à soma das partes")
    func totalEqualsSumOfParts() {
        let cal = makeCalendar()
        var events: [TrackingEvent] = []
        for day in 14...18 {
            for hour in 9..<12 {
                events.append(
                    event(
                        date(2026, 9, day, hour, 0, calendar: cal),
                        date(2026, 9, day, hour, 30, calendar: cal),
                        bundleID: "app\(hour)"))
            }
        }

        let report = ReportBuilder.build(
            events: events,
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 19, 0, 0, calendar: cal),
            calendar: cal)

        let sumOfApps = report.apps.reduce(0) { $0 + $1.total }
        let sumOfDays = report.days.reduce(0) { $0 + $1.active }
        #expect(sumOfApps == report.totalActive)
        #expect(sumOfDays == report.totalActive)
    }

    @Test("Eventos fora do intervalo são ignorados")
    func ignoresOutsideEvents() {
        let cal = makeCalendar()
        let events = [
            event(date(2026, 9, 1, 9, 0, calendar: cal), date(2026, 9, 1, 10, 0, calendar: cal)),
            event(date(2026, 9, 30, 9, 0, calendar: cal), date(2026, 9, 30, 10, 0, calendar: cal)),
        ]

        let report = ReportBuilder.build(
            events: events,
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 15, 0, 0, calendar: cal),
            calendar: cal)

        #expect(report.totalActive == 0)
        #expect(report.apps.isEmpty)
    }

    @Test("Uma semana sem eventos gera um relatório vazio válido")
    func emptyWeekIsValid() {
        let cal = makeCalendar()
        let report = ReportBuilder.build(
            events: [],
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 21, 0, 0, calendar: cal),
            calendar: cal)

        #expect(report.apps.isEmpty)
        #expect(report.days.isEmpty)
        #expect(report.totalActive == 0)
        #expect(report.dailyAverage == 0)
        #expect(report.busiestDay == nil)
    }

    @Test("Ocioso entra no total de ocioso, nunca no de ativo")
    func idleIsSeparate() {
        let cal = makeCalendar()
        let events = [
            event(date(2026, 9, 14, 9, 0, calendar: cal), date(2026, 9, 14, 10, 0, calendar: cal)),
            event(
                date(2026, 9, 14, 10, 0, calendar: cal), date(2026, 9, 14, 10, 30, calendar: cal),
                bundleID: "system.idle", appName: "Ocioso", kind: .idle),
        ]

        let report = ReportBuilder.build(
            events: events,
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 15, 0, 0, calendar: cal),
            calendar: cal)

        #expect(report.totalActive == 3600)
        #expect(report.totalIdle == 1800)
        #expect(report.apps.count == 1, "o ocioso não é um app")
    }

    @Test("Sono e bloqueio não contam em lugar nenhum")
    func sleepAndLockAreExcluded() {
        let cal = makeCalendar()
        let events = [
            event(
                date(2026, 9, 14, 9, 0, calendar: cal), date(2026, 9, 14, 17, 0, calendar: cal),
                bundleID: "system.sleep", appName: "Suspenso", kind: .sleep),
            event(
                date(2026, 9, 14, 17, 0, calendar: cal), date(2026, 9, 14, 18, 0, calendar: cal),
                bundleID: "system.locked", appName: "Bloqueado", kind: .locked),
        ]

        let report = ReportBuilder.build(
            events: events,
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 15, 0, 0, calendar: cal),
            calendar: cal)

        #expect(report.totalActive == 0)
        #expect(report.totalIdle == 0)
    }

    @Test("Agrega por perfil")
    func aggregatesPerProfile() {
        let cal = makeCalendar()
        let work = UUID()
        let leisure = UUID()
        let events = [
            event(
                date(2026, 9, 14, 9, 0, calendar: cal), date(2026, 9, 14, 12, 0, calendar: cal),
                profileID: work),
            event(
                date(2026, 9, 14, 19, 0, calendar: cal), date(2026, 9, 14, 20, 0, calendar: cal),
                profileID: leisure),
        ]

        let report = ReportBuilder.build(
            events: events,
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 15, 0, 0, calendar: cal),
            calendar: cal)

        #expect(report.perProfile[work] == 10800)
        #expect(report.perProfile[leisure] == 3600)
    }

    @Test("Registra a primeira e a última atividade do dia")
    func tracksFirstAndLastActivity() {
        let cal = makeCalendar()
        let events = [
            event(date(2026, 9, 14, 8, 42, calendar: cal), date(2026, 9, 14, 9, 0, calendar: cal)),
            event(date(2026, 9, 14, 17, 0, calendar: cal), date(2026, 9, 14, 18, 15, calendar: cal)),
        ]

        let report = ReportBuilder.build(
            events: events,
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 15, 0, 0, calendar: cal),
            calendar: cal)

        let day = report.days.first
        #expect(DurationFormat.timeOfDay(day!.firstActivity!, calendar: cal) == "08:42")
        #expect(DurationFormat.timeOfDay(day!.lastActivity!, calendar: cal) == "18:15")
        #expect(day?.span == TimeInterval(9 * 3600 + 33 * 60), "da primeira à última, incluindo a pausa")
    }

    @Test("A média diária ignora os dias sem atividade")
    func dailyAverageSkipsEmptyDays() {
        let cal = makeCalendar()
        // Dois dias com 2h cada, dentro de uma janela de sete dias.
        let events = [
            event(date(2026, 9, 14, 9, 0, calendar: cal), date(2026, 9, 14, 11, 0, calendar: cal)),
            event(date(2026, 9, 16, 9, 0, calendar: cal), date(2026, 9, 16, 11, 0, calendar: cal)),
        ]

        let report = ReportBuilder.build(
            events: events,
            from: date(2026, 9, 14, 0, 0, calendar: cal),
            to: date(2026, 9, 21, 0, 0, calendar: cal),
            calendar: cal)

        #expect(report.dailyAverage == 7200, "média sobre 2 dias ativos, não sobre 7")
    }

    @Test("A semana começa na segunda-feira")
    func weekStartsOnMonday() {
        let cal = makeCalendar()
        // 2026-09-17 é quinta; a semana dela começa na segunda, 14.
        let start = ReportBuilder.startOfWeek(
            containing: date(2026, 9, 17, 15, 0, calendar: cal), calendar: cal)
        #expect(ProfileResolver.dayString(start!, calendar: cal) == "2026-09-14")
    }
}

@Suite("Formatação de duração")
struct DurationFormatTests {

    @Test(
        "Forma curta",
        arguments: [
            (12.0, "12 s"), (59.0, "59 s"), (60.0, "1 min"), (1800.0, "30 min"),
            (3600.0, "1 h"), (5400.0, "1 h 30 min"), (9240.0, "2 h 34 min"),
        ])
    func shortForm(interval: TimeInterval, expected: String) {
        #expect(DurationFormat.short(interval) == expected)
    }

    @Test(
        "Forma de relógio",
        arguments: [(3600.0, "1:00"), (5400.0, "1:30"), (9240.0, "2:34"), (300.0, "0:05")])
    func clockForm(interval: TimeInterval, expected: String) {
        #expect(DurationFormat.clock(interval) == expected)
    }
}
