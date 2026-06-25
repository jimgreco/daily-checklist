import Foundation
import UserNotifications

struct NotificationManager {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func reschedule(items: [ChecklistItem], eveningMinutes: Int?) async {
        let pending = await center.pendingNotificationRequests()
        let managed = pending.map(\.identifier).filter {
            $0.hasPrefix("daily.item.") || $0.hasPrefix("daily.evening.")
        }
        center.removePendingNotificationRequests(withIdentifiers: managed)

        let calendar = Calendar.current
        var itemReminders: [(date: Date, item: ChecklistItem)] = []
        for dayOffset in 0..<60 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: .now) else { continue }
            for item in items {
                guard let minutes = item.reminderMinutes, item.occurs(on: date) else { continue }
                var fireDate = calendar.dateComponents([.year, .month, .day], from: date)
                fireDate.hour = minutes / 60
                fireDate.minute = minutes % 60
                guard let scheduledDate = calendar.date(from: fireDate), scheduledDate > .now else { continue }
                itemReminders.append((scheduledDate, item))
            }
        }

        for reminder in itemReminders.sorted(by: { $0.date < $1.date }).prefix(50) {
            let content = UNMutableNotificationContent()
            content.title = reminder.item.title
            content.body = reminder.item.notes.isEmpty ? "Time for your daily task." : reminder.item.notes
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date),
                repeats: false
            )
            try? await center.add(UNNotificationRequest(
                identifier: "daily.item.\(reminder.item.id).\(DateKey.string(from: reminder.date))",
                content: content,
                trigger: trigger
            ))
        }

        guard let eveningMinutes else { return }
        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: .now) else { continue }
            let remaining = items.filter { $0.occurs(on: date) && !$0.isComplete(on: date) }.count
            guard remaining > 0 else { continue }

            var fireDate = calendar.dateComponents([.year, .month, .day], from: date)
            fireDate.hour = eveningMinutes / 60
            fireDate.minute = eveningMinutes % 60
            guard let scheduledDate = calendar.date(from: fireDate), scheduledDate > .now else { continue }

            let content = UNMutableNotificationContent()
            content.title = remaining == 1 ? "1 task left today" : "\(remaining) tasks left today"
            content.body = "A quick check-in before the day wraps up."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: fireDate, repeats: false)
            try? await center.add(UNNotificationRequest(
                identifier: "daily.evening.\(DateKey.string(from: date))",
                content: content,
                trigger: trigger
            ))
        }
    }
}
