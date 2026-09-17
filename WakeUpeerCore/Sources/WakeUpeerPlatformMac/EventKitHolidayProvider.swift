import EventKit
import Foundation
import WakeUpeerDomain

/// Lê feriados dos calendários do app Calendário.
///
/// Fica **na frente** do calculador de feriados nacionais, não no lugar
/// dele: serve para pegar feriados municipais, estaduais e datas pessoais
/// que uma tabela fixa não conhece. Se a permissão for negada, o app
/// continua funcionando com a lista nacional.
public final class EventKitHolidayProvider: HolidayProvider, @unchecked Sendable {

    public enum Authorization: Sendable, Equatable {
        case authorized
        case denied
        /// Desde o macOS 14 o acesso pode ser só de escrita, o que não
        /// serve para ler feriados.
        case writeOnly
        case notDetermined
    }

    private let store = EKEventStore()
    private let calendarIDs: [String]
    private let calendar: Calendar

    public init(calendarIDs: [String], calendar: Calendar) {
        self.calendarIDs = calendarIDs
        self.calendar = calendar
    }

    // MARK: - Autorização

    public static var authorization: Authorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .authorized
        case .writeOnly: .writeOnly
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Ler eventos exige acesso completo. O método antigo `requestAccess(to:)`
    /// está obsoleto e, sem a chave NSCalendarsFullAccessUsageDescription no
    /// Info.plist, a chamada encerra o app.
    public func requestAccess() async -> Authorization {
        do {
            let granted = try await store.requestFullAccessToEvents()
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    // MARK: - Calendários

    public struct CalendarInfo: Sendable, Identifiable, Hashable {
        public var id: String
        public var title: String
        public var isSubscribed: Bool
    }

    public func availableCalendars() -> [CalendarInfo] {
        guard Self.authorization == .authorized else { return [] }
        return store.calendars(for: .event)
            .map {
                CalendarInfo(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    isSubscribed: $0.type == .subscription)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Calendários que parecem ser de feriados, para sugerir na primeira vez.
    public func suggestedHolidayCalendarIDs() -> [String] {
        availableCalendars()
            .filter { info in
                let title = info.title.lowercased()
                return title.contains("feriado") || title.contains("holiday")
                    || title.contains("festivo")
            }
            .map(\.id)
    }

    // MARK: - Consulta

    public func lookup(day: Date) async -> HolidayLookup {
        switch Self.authorization {
        case .notDetermined:
            return .unavailable(reason: "Acesso ao Calendário ainda não foi solicitado.")
        case .denied:
            return .unavailable(reason: "Sem acesso ao Calendário.")
        case .writeOnly:
            return .unavailable(reason: "O acesso concedido é somente de escrita.")
        case .authorized:
            break
        }

        let selected = store.calendars(for: .event).filter {
            calendarIDs.contains($0.calendarIdentifier)
        }
        guard !selected.isEmpty else {
            return .unavailable(reason: "Nenhum calendário de feriados selecionado.")
        }

        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return .notHoliday
        }

        let predicate = store.predicateForEvents(
            withStart: dayStart, end: dayEnd, calendars: selected)

        // Feriados são eventos de dia inteiro; compromissos comuns no mesmo
        // calendário não devem virar feriado.
        let names =
            store.events(matching: predicate)
            .filter { $0.isAllDay && isSameDay($0, as: dayStart) }
            .compactMap { $0.title }

        return names.isEmpty ? .notHoliday : .holiday(names: names)
    }

    /// Eventos de dia inteiro vindos de calendários assinados às vezes têm
    /// `startDate` à meia-noite UTC, o que joga a data para o dia anterior
    /// em fusos negativos. A comparação usa o fuso do próprio evento.
    private func isSameDay(_ event: EKEvent, as dayStart: Date) -> Bool {
        var eventCalendar = calendar
        if let timeZone = event.timeZone {
            eventCalendar.timeZone = timeZone
        }
        return eventCalendar.isDate(event.startDate, inSameDayAs: dayStart)
            || calendar.isDate(event.startDate, inSameDayAs: dayStart)
    }
}
