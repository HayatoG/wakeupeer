import Foundation
import Testing

@testable import WakeUpeerDomain

@Suite("Feriados brasileiros")
struct BrazilianHolidaysTests {

    /// Domingos de Páscoa conferidos contra a tabela litúrgica oficial.
    @Test(
        "Domingo de Páscoa",
        arguments: [
            (2020, 4, 12), (2021, 4, 4), (2022, 4, 17), (2023, 4, 9), (2024, 3, 31),
            (2025, 4, 20), (2026, 4, 5), (2027, 3, 28), (2028, 4, 16), (2029, 4, 1),
            (2030, 4, 21), (2031, 4, 13), (2032, 3, 28), (2033, 4, 17), (2034, 4, 9),
            (2035, 3, 25),
        ])
    func easterDates(year: Int, month: Int, day: Int) {
        let easter = BrazilianHolidays.easterSunday(year: year)
        #expect(easter.month == month, "mês da Páscoa de \(year)")
        #expect(easter.day == day, "dia da Páscoa de \(year)")
    }

    @Test("Feriados móveis de 2026 derivam da Páscoa em 5 de abril")
    func movableHolidays2026() {
        let holidays = BrazilianHolidays.holidays(year: 2026)

        func has(_ month: Int, _ day: Int, _ name: String) -> Bool {
            holidays.contains { $0.month == month && $0.day == day && $0.name == name }
        }

        #expect(has(2, 16, "Carnaval"), "segunda de carnaval")
        #expect(has(2, 17, "Carnaval"), "terça de carnaval")
        #expect(has(4, 3, "Sexta-feira Santa"))
        #expect(has(6, 4, "Corpus Christi"))
    }

    @Test("Feriados fixos estão todos presentes")
    func fixedHolidays() {
        let holidays = BrazilianHolidays.holidays(year: 2026)
        let fixed = [(1, 1), (4, 21), (5, 1), (9, 7), (10, 12), (11, 2), (11, 15), (12, 25)]
        for (month, day) in fixed {
            #expect(
                holidays.contains { $0.month == month && $0.day == day },
                "faltou o feriado de \(day)/\(month)")
        }
    }

    @Test("Consciência Negra é nacional a partir de 2024")
    func consciencianegraFrom2024() {
        func hasNov20(_ year: Int) -> Bool {
            BrazilianHolidays.holidays(year: year).contains { $0.month == 11 && $0.day == 20 }
        }
        #expect(hasNov20(2023) == false)
        #expect(hasNov20(2024))
        #expect(hasNov20(2026))
    }

    @Test("A consulta por data identifica o feriado")
    func lookupFindsHoliday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!

        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 7
        components.hour = 10
        let independenceDay = cal.date(from: components)!

        let result = BrazilianHolidays.lookup(date: independenceDay, calendar: cal)
        #expect(result.isHoliday)
        #expect(result.names.contains("Independência do Brasil"))
    }

    @Test("Um dia comum não é feriado")
    func lookupOrdinaryDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!

        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 17
        components.hour = 10

        let result = BrazilianHolidays.lookup(date: cal.date(from: components)!, calendar: cal)
        #expect(result == .notHoliday)
    }

    @Test("O provider de reserva responde sem depender de permissão")
    func providerWorks() async {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!

        var components = DateComponents()
        components.year = 2026
        components.month = 12
        components.day = 25
        components.hour = 10

        let provider = BrazilianHolidayProvider(calendar: cal)
        let result = await provider.lookup(day: cal.date(from: components)!)
        #expect(result.names.contains("Natal"))
    }

    @Test("O encadeamento usa o reserva quando o principal não sabe")
    func chainedFallsBack() async {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!

        struct DeniedProvider: HolidayProvider {
            func lookup(day: Date) async -> HolidayLookup {
                .unavailable(reason: "permissão negada")
            }
        }

        var components = DateComponents()
        components.year = 2026
        components.month = 12
        components.day = 25
        components.hour = 10

        let chained = ChainedHolidayProvider(
            primary: DeniedProvider(),
            fallback: BrazilianHolidayProvider(calendar: cal))
        let result = await chained.lookup(day: cal.date(from: components)!)
        #expect(result.isHoliday)
        #expect(result.names.contains("Natal"))
    }
}

@Suite("TimeWindow")
struct TimeWindowTests {

    @Test("Janela normal")
    func normalWindow() {
        let window = TimeWindow(from: 8, to: 17)
        #expect(window.crossesMidnight == false)
        #expect(window.isAllDay == false)
        #expect(window.durationMinutes == 9 * 60)
        #expect(window.contains(minutes: 8 * 60))
        #expect(window.contains(minutes: 16 * 60 + 59))
        #expect(window.contains(minutes: 17 * 60) == false)
        #expect(window.contains(minutes: 7 * 60 + 59) == false)
    }

    @Test("Janela que atravessa a meia-noite")
    func midnightWindow() {
        let window = TimeWindow(from: 22, to: 2)
        #expect(window.crossesMidnight)
        #expect(window.durationMinutes == 4 * 60)
        #expect(window.contains(minutes: 23 * 60))
        #expect(window.contains(minutes: 1 * 60))
        #expect(window.contains(minutes: 3 * 60) == false)
        #expect(window.isInPostMidnightSegment(minutes: 1 * 60))
        #expect(window.isInPostMidnightSegment(minutes: 23 * 60) == false)
    }

    @Test("Janela de dia inteiro")
    func allDayWindow() {
        let window = TimeWindow(startMinutes: 0, endMinutes: 0)
        #expect(window.isAllDay)
        #expect(window.crossesMidnight == false)
        #expect(window.durationMinutes == 1440)
        #expect(window.contains(minutes: 0))
        #expect(window.contains(minutes: 1439))
    }

    @Test("Valores fora do intervalo são limitados")
    func clampsOutOfRange() {
        let window = TimeWindow(startMinutes: -100, endMinutes: 9999)
        #expect(window.startMinutes == 0)
        #expect(window.endMinutes == 1439)
    }
}

@Suite("Weekday")
struct WeekdayTests {

    @Test("Os números batem com os do Calendar da Apple")
    func rawValuesMatchCalendar() {
        #expect(Weekday.sunday.rawValue == 1)
        #expect(Weekday.monday.rawValue == 2)
        #expect(Weekday.saturday.rawValue == 7)
    }

    @Test("O dia anterior dá a volta corretamente")
    func previousWraps() {
        #expect(Weekday.sunday.previous == .saturday)
        #expect(Weekday.monday.previous == .sunday)
        #expect(Weekday.friday.previous == .thursday)
    }

    @Test("Fim de semana e dias úteis")
    func weekendClassification() {
        #expect(Weekday.saturday.isWeekend)
        #expect(Weekday.sunday.isWeekend)
        #expect(Weekday.monday.isWorkday)
        #expect(Weekday.workdays.count == 5)
        #expect(Weekday.weekend.count == 2)
        #expect(Weekday.everyDay.count == 7)
    }
}
