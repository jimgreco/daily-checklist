import Foundation
import UserNotifications

extension Notification.Name {
    static let dailyNotificationAction = Notification.Name("DailyNotificationAction")
}

struct DailyNotificationAction {
    static let complete = "DAILY_COMPLETE"
    static let skip = "DAILY_SKIP"
    static let snooze = "DAILY_SNOOZE"
    static let itemCategory = "DAILY_ITEM_REMINDER"
}

final class DailyNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DailyNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard [
            DailyNotificationAction.complete,
            DailyNotificationAction.skip,
            DailyNotificationAction.snooze
        ].contains(response.actionIdentifier) else { return }

        NotificationCenter.default.post(
            name: .dailyNotificationAction,
            object: nil,
            userInfo: [
                "action": response.actionIdentifier,
                "itemID": response.notification.request.content.userInfo["itemID"] as? String ?? "",
                "date": response.notification.request.content.userInfo["date"] as? String ?? ""
            ]
        )
    }
}

struct NotificationManager {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        #if DEBUG
        if ScreenshotSeedData.isEnabled { return }
        #endif
        configureCategories()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func configureCategories() {
        let complete = UNNotificationAction(
            identifier: DailyNotificationAction.complete,
            title: "Complete",
            options: []
        )
        let skip = UNNotificationAction(
            identifier: DailyNotificationAction.skip,
            title: "Skip today",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: DailyNotificationAction.snooze,
            title: "Snooze",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: DailyNotificationAction.itemCategory,
                actions: [complete, skip, snooze],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func reschedule(items: [ChecklistItem], eveningMinutes: Int?) async {
        #if DEBUG
        if ScreenshotSeedData.isEnabled { return }
        #endif
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
                guard let minutes = item.reminderMinutes,
                      item.occurs(on: date) || item.isExplicitlyOpen(on: date) else { continue }
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
            content.categoryIdentifier = DailyNotificationAction.itemCategory
            content.userInfo = [
                "itemID": reminder.item.id.uuidString,
                "date": DateKey.string(from: reminder.date)
            ]
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
            let remaining = items.filter {
                ($0.occurs(on: date) || $0.isExplicitlyOpen(on: date))
                    && !$0.isComplete(on: date)
                    && !$0.isSkipped(on: date)
            }.count
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

    func snooze(item: ChecklistItem, minutes: Int) async {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.notes.isEmpty ? "Snoozed reminder." : item.notes
        content.sound = .default
        content.categoryIdentifier = DailyNotificationAction.itemCategory
        content.userInfo = [
            "itemID": item.id.uuidString,
            "date": DateKey.string(from: .now)
        ]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(1, minutes) * 60), repeats: false)
        try? await center.add(UNNotificationRequest(
            identifier: "daily.snooze.\(item.id).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        ))
    }
}
