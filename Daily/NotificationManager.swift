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

        for item in items {
            guard let minutes = item.reminderMinutes else { continue }
            for weekday in weekdays(for: item) {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.notes.isEmpty ? "Time for your daily task." : item.notes
                content.sound = .default

                var components = DateComponents()
                components.weekday = weekday
                components.hour = minutes / 60
                components.minute = minutes % 60
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                let request = UNNotificationRequest(
                    identifier: "daily.item.\(item.id).\(weekday)",
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }

        guard let eveningMinutes else { return }
        let calendar = Calendar.current
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

    private func weekdays(for item: ChecklistItem) -> [Int] {
        switch item.schedule {
        case .everyDay: Array(1...7)
        case .weekdays: Array(2...6)
        case .weekends: [1, 7]
        case .custom: item.customWeekdays.sorted()
        }
    }
}

