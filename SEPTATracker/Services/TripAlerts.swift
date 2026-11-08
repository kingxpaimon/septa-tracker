import Foundation
import Combine
import UserNotifications

/// Schedules trip reminders as local notifications and keeps them in step with live
/// predictions while the app is open. With the app closed, a reminder fires at the last
/// time the app computed. There's no background tracking ("when in use" location only).
@MainActor
final class TripAlerts: ObservableObject {
    @Published private(set) var alerts: [TripAlert] = []
    @Published private(set) var permissionDenied = false

    private let center = UNUserNotificationCenter.current()
    private let defaultsKey = "tripAlerts.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([TripAlert].self, from: data) {
            alerts = saved.filter { $0.eventTime > Date() }
        }
    }

    func alert(id: String) -> TripAlert? { alerts.first { $0.id == id } }

    /// Asks for notification permission if needed, then schedules (or replaces) `alert`.
    func schedule(_ alert: TripAlert) async {
        guard await ensurePermission() else { return }
        alerts.removeAll { $0.id == alert.id }
        guard let fire = AlertTiming.fireDate(event: alert.eventTime, leadMinutes: alert.leadMinutes) else { save(); return }
        alerts.append(alert)
        save()
        await deliver(alert, at: fire)
    }

    func cancel(id: String) {
        alerts.removeAll { $0.id == id }
        center.removePendingNotificationRequests(withIdentifiers: [id])
        save()
    }

    /// Moves alerts whose predicted time changed (call after each refresh).
    /// `eventTimes` maps alert IDs to the new event time.
    func update(eventTimes: [String: Date]) async {
        var changed = false
        for (index, alert) in alerts.enumerated() {
            guard let newTime = eventTimes[alert.id],
                  abs(newTime.timeIntervalSince(alert.eventTime)) >= 30 else { continue }
            alerts[index].eventTime = newTime
            changed = true
            if let fire = AlertTiming.fireDate(event: newTime, leadMinutes: alert.leadMinutes) {
                await deliver(alerts[index], at: fire)
            }
        }
        if changed { save() }
    }

    private func deliver(_ alert: TripAlert, at fire: Date) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = AlertTiming.body(for: alert)
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
        // Same identifier replaces any earlier version of this alert.
        try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger))
    }

    private func ensurePermission() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            permissionDenied = false
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            permissionDenied = !granted
            return granted
        default:
            permissionDenied = true
            return false
        }
    }

    private func save() {
        alerts.removeAll { $0.eventTime < Date().addingTimeInterval(-60) }
        if let data = try? JSONEncoder().encode(alerts) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
}
