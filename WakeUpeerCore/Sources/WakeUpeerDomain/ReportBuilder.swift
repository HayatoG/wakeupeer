import Foundation

// MARK: - Relatório

public struct AppUsage: Sendable, Equatable, Identifiable {
    public var bundleID: String
    public var appName: String
    public var total: TimeInterval

    public var id: String { bundleID }

    public init(bundleID: String, appName: String, total: TimeInterval) {
        self.bundleID = bundleID
        self.appName = appName
        self.total = total
    }
}

public struct DayUsage: Sendable, Equatable, Identifiable {
    public var day: String
    public var date: Date
    public var active: TimeInterval
    public var idle: TimeInterval
    public var perProfile: [UUID: TimeInterval]
    public var firstActivity: Date?
    public var lastActivity: Date?

    public var id: String { day }

    /// Da primeira à última atividade do dia, incluindo as pausas.
    public var span: TimeInterval? {
        guard let first = firstActivity, let last = lastActivity else { return nil }
        return last.timeIntervalSince(first)
    }
}

public struct UsageReport: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var apps: [AppUsage]
    public var days: [DayUsage]
    public var perProfile: [UUID: TimeInterval]
    public var totalActive: TimeInterval
    public var totalIdle: TimeInterval

    public var topApps: [AppUsage] { Array(apps.prefix(10)) }

    public var busiestDay: DayUsage? {
        days.max { $0.active < $1.active }
    }

    /// Média sobre os dias que tiveram alguma atividade, não sobre sete.
    public var dailyAverage: TimeInterval {
        let active = days.filter { $0.active > 0 }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { $0 + $1.active } / Double(active.count)
    }
}

// MARK: - Construção

public enum ReportBuilder {

    /// Agrega eventos num relatório. Função pura: recebe os eventos prontos.
    ///
    /// Eventos são **clipados** nas bordas do intervalo, então uma sessão que
    /// começa no domingo à noite e termina na segunda conta o tanto certo em
    /// cada dia.
    public static func build(
        events: [TrackingEvent],
        from start: Date,
        to end: Date,
        calendar: Calendar,
        appNames: [String: String] = [:]
    ) -> UsageReport {
        var appTotals: [String: TimeInterval] = [:]
        var names: [String: String] = appNames
        var perProfile: [UUID: TimeInterval] = [:]
        var dayBuckets: [String: DayBucket] = [:]
        var totalActive: TimeInterval = 0
        var totalIdle: TimeInterval = 0

        for event in events {
            // Descarta o que está totalmente fora da janela.
            guard event.end > start, event.start < end else { continue }

            let clippedStart = max(event.start, start)
            let clippedEnd = min(event.end, end)
            guard clippedEnd > clippedStart else { continue }

            // Um evento pode atravessar a meia-noite; cada pedaço vai para
            // o seu próprio dia.
            for slice in daySlices(
                from: clippedStart, to: clippedEnd, calendar: calendar)
            {
                let duration = slice.end.timeIntervalSince(slice.start)
                guard duration > 0 else { continue }

                var bucket = dayBuckets[slice.day] ?? DayBucket(day: slice.day, date: slice.dayStart)

                switch event.kind {
                case .foreground:
                    appTotals[event.bundleID, default: 0] += duration
                    names[event.bundleID] = event.appName
                    totalActive += duration
                    bucket.active += duration
                    if let profileID = event.profileID {
                        perProfile[profileID, default: 0] += duration
                        bucket.perProfile[profileID, default: 0] += duration
                    }
                    bucket.firstActivity = min(bucket.firstActivity ?? slice.start, slice.start)
                    bucket.lastActivity = max(bucket.lastActivity ?? slice.end, slice.end)

                case .idle:
                    totalIdle += duration
                    bucket.idle += duration

                case .sleep, .locked:
                    break
                }

                dayBuckets[slice.day] = bucket
            }
        }

        let apps = appTotals
            .map { AppUsage(bundleID: $0.key, appName: names[$0.key] ?? $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }

        let days = dayBuckets.values
            .map {
                DayUsage(
                    day: $0.day, date: $0.date, active: $0.active, idle: $0.idle,
                    perProfile: $0.perProfile,
                    firstActivity: $0.firstActivity, lastActivity: $0.lastActivity)
            }
            .sorted { $0.day < $1.day }

        return UsageReport(
            start: start, end: end, apps: apps, days: days, perProfile: perProfile,
            totalActive: totalActive, totalIdle: totalIdle)
    }

    private struct DayBucket {
        var day: String
        var date: Date
        var active: TimeInterval = 0
        var idle: TimeInterval = 0
        var perProfile: [UUID: TimeInterval] = [:]
        var firstActivity: Date?
        var lastActivity: Date?
    }

    private struct DaySlice {
        var day: String
        var dayStart: Date
        var start: Date
        var end: Date
    }

    /// Divide um intervalo nas fronteiras de meia-noite.
    private static func daySlices(
        from start: Date, to end: Date, calendar: Calendar
    ) -> [DaySlice] {
        var slices: [DaySlice] = []
        var cursor = start
        // Um evento não deve cruzar centenas de dias; o limite evita um laço
        // infinito caso o calendário devolva algo inesperado.
        var guardCount = 0

        while cursor < end, guardCount < 400 {
            guardCount += 1
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
                  let day = ProfileResolver.dayString(cursor, calendar: calendar)
            else { break }

            let sliceEnd = min(end, nextDay)
            slices.append(
                DaySlice(day: day, dayStart: dayStart, start: cursor, end: sliceEnd))
            cursor = sliceEnd
        }

        return slices
    }

    // MARK: Semanas

    /// Início da semana que contém a data. A semana começa na segunda,
    /// conforme o `firstWeekday` do calendário injetado.
    public static func startOfWeek(containing date: Date, calendar: Calendar) -> Date? {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start
    }

    public static func weekInterval(
        containing date: Date, calendar: Calendar
    ) -> (start: Date, end: Date)? {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return nil }
        return (interval.start, interval.end)
    }
}

// MARK: - Formatação

public enum DurationFormat {

    /// "2 h 34 min", "45 min", "12 s". Compacto o bastante para uma linha
    /// de lista, sem sacrificar a leitura.
    public static func short(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        guard total >= 60 else { return "\(total) s" }

        let hours = total / 3600
        let minutes = (total % 3600) / 60

        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return "\(hours) h" }
        return "\(hours) h \(minutes) min"
    }

    /// "2:34" — para tabelas e colunas alinhadas.
    public static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return "\(hours):\(minutes < 10 ? "0" : "")\(minutes)"
    }

    /// "08:42" a partir de uma data, sem depender de locale.
    public static func timeOfDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return "\(hour < 10 ? "0" : "")\(hour):\(minute < 10 ? "0" : "")\(minute)"
    }
}
