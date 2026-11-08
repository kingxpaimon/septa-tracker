import Foundation

/// A scheduled reminder about a trip. Stored on the device; delivered as a local notification.
struct TripAlert: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// "Route 21 leaves Broad & Walnut in 5 min"
        case departure
        /// "Get off soon: Temple University in about 2 min"
        case getOff
        /// "Time to leave for City Hall"
        case leave
    }

    let id: String
    let kind: Kind
    let title: String
    /// Text before the countdown, e.g. "Leaves Broad St & Walnut St".
    let message: String
    /// When the thing happens (departure / arrival / when to start walking).
    var eventTime: Date
    let leadMinutes: Int
    /// SEPTA trip this follows, so live updates can move it.
    let tripID: String?

    var fireDate: Date { eventTime.addingTimeInterval(-Double(leadMinutes) * 60) }
}

enum AlertTiming {
    /// When to deliver an alert for an event `leadMinutes` ahead, or nil if the event has passed.
    /// If the lead window has already started, deliver almost immediately.
    static func fireDate(event: Date, leadMinutes: Int, now: Date = Date()) -> Date? {
        guard event > now else { return nil }
        let fire = event.addingTimeInterval(-Double(leadMinutes) * 60)
        return max(fire, now.addingTimeInterval(1))
    }

    /// Notification text with the countdown as of delivery.
    static func body(for alert: TripAlert) -> String {
        "\(alert.message) in \(alert.leadMinutes) min"
    }
}
