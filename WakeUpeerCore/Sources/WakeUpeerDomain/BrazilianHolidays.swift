import Foundation

/// Feriados nacionais brasileiros calculados localmente.
///
/// Serve de rede de segurança para quando o EventKit não está disponível
/// (permissão negada, nenhum calendário de feriados assinado) e, de quebra,
/// já funciona em Linux quando chegar a hora de portar.
public enum BrazilianHolidays {

    public struct Holiday: Sendable, Hashable {
        public var month: Int
        public var day: Int
        public var name: String
    }

    /// Domingo de Páscoa pelo algoritmo de Meeus/Jones/Butcher (calendário gregoriano).
    public static func easterSunday(year: Int) -> (month: Int, day: Int) {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return (month, day)
    }

    /// Feriados nacionais do ano, fixos e móveis.
    public static func holidays(year: Int) -> [Holiday] {
        var result: [Holiday] = [
            Holiday(month: 1, day: 1, name: "Confraternização Universal"),
            Holiday(month: 4, day: 21, name: "Tiradentes"),
            Holiday(month: 5, day: 1, name: "Dia do Trabalho"),
            Holiday(month: 9, day: 7, name: "Independência do Brasil"),
            Holiday(month: 10, day: 12, name: "Nossa Senhora Aparecida"),
            Holiday(month: 11, day: 2, name: "Finados"),
            Holiday(month: 11, day: 15, name: "Proclamação da República"),
            Holiday(month: 12, day: 25, name: "Natal"),
        ]

        // Feriado nacional desde 2024 (Lei 14.759/2023).
        if year >= 2024 {
            result.append(Holiday(month: 11, day: 20, name: "Consciência Negra"))
        }

        let easter = easterSunday(year: year)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        var components = DateComponents()
        components.year = year
        components.month = easter.month
        components.day = easter.day
        components.hour = 12

        guard let easterDate = calendar.date(from: components) else { return result }

        // Deslocamentos a partir do Domingo de Páscoa.
        let movable: [(offset: Int, name: String)] = [
            (-48, "Carnaval"),        // segunda-feira de carnaval
            (-47, "Carnaval"),        // terça-feira de carnaval
            (-2, "Sexta-feira Santa"),
            (60, "Corpus Christi"),
        ]

        for entry in movable {
            guard let date = calendar.date(byAdding: .day, value: entry.offset, to: easterDate)
            else { continue }
            let parts = calendar.dateComponents([.month, .day], from: date)
            guard let month = parts.month, let day = parts.day else { continue }
            result.append(Holiday(month: month, day: day, name: entry.name))
        }

        return result
    }

    /// Consulta um dia específico. `calendar` define a timezone de referência.
    public static func lookup(date: Date, calendar: Calendar) -> HolidayLookup {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return .notHoliday
        }

        let names = holidays(year: year)
            .filter { $0.month == month && $0.day == day }
            .map(\.name)

        return names.isEmpty ? .notHoliday : .holiday(names: names)
    }
}

/// Provider de feriados que não depende de permissão alguma.
/// Em produção fica como fallback do `EventKitHolidayProvider`.
public struct BrazilianHolidayProvider: HolidayProvider {
    private let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public func lookup(day: Date) async -> HolidayLookup {
        BrazilianHolidays.lookup(date: day, calendar: calendar)
    }
}

/// Tenta o provider principal e cai no reserva quando ele não sabe responder.
public struct ChainedHolidayProvider: HolidayProvider {
    private let primary: any HolidayProvider
    private let fallback: any HolidayProvider

    public init(primary: any HolidayProvider, fallback: any HolidayProvider) {
        self.primary = primary
        self.fallback = fallback
    }

    public func lookup(day: Date) async -> HolidayLookup {
        let result = await primary.lookup(day: day)
        switch result {
        case .holiday:
            return result
        case .notHoliday, .unavailable:
            // Mesmo quando o primário diz "não é feriado", o reserva pode conhecer
            // um feriado nacional que o calendário assinado não lista.
            let backup = await fallback.lookup(day: day)
            return backup.isHoliday ? backup : result
        }
    }
}
