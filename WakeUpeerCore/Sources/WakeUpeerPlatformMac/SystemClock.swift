import Foundation
import WakeUpeerDomain

/// Relógio do sistema com a timezone e o `firstWeekday` do usuário.
/// A semana começa na segunda, como se espera no Brasil.
public struct SystemClock: Clock {
    private let timeZoneID: String?

    public init(timeZoneID: String? = nil) {
        self.timeZoneID = timeZoneID
    }

    public var now: Date { Date() }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZoneID, let timeZone = TimeZone(identifier: timeZoneID) {
            calendar.timeZone = timeZone
        }
        calendar.firstWeekday = 2
        return calendar
    }
}
