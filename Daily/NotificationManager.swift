import Foundation
import UserNotifications

extension Notification.Name {
    static let ritualNotificationAction = Notification.Name("RitualNotificationAction")
}

struct RitualNotificationAction {
    static let complete = "RITUAL_COMPLETE"
    static let skip = "RITUAL_SKIP"
    static let snooze = "RITUAL_SNOOZE"
    static let itemCategory = "RITUAL_ITEM_REMINDER"
}

final class RitualNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RitualNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard [
            RitualNotificationAction.complete,
            RitualNotificationAction.skip,
            RitualNotificationAction.snooze
        ].contains(response.actionIdentifier) else { return }

        NotificationCenter.default.post(
            name: .ritualNotificationAction,
            object: nil,
            userInfo: [
                "action": response.actionIdentifier,
                "itemID": response.notification.request.content.userInfo["itemID"] as? String ?? "",
                "occurrenceID": response.notification.request.content.userInfo["occurrenceID"] as? String ?? "",
                "occurrenceDate": response.notification.request.content.userInfo["occurrenceDate"] as? String
                    ?? response.notification.request.content.userInfo["date"] as? String
                    ?? "",
                "isCarryover": response.notification.request.content.userInfo["isCarryover"] as? Bool ?? false
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
            identifier: RitualNotificationAction.complete,
            title: "Complete",
            options: []
        )
        let skip = UNNotificationAction(
            identifier: RitualNotificationAction.skip,
            title: "Skip occurrence",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: RitualNotificationAction.snooze,
            title: "Snooze",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: RitualNotificationAction.itemCategory,
                actions: [complete, skip, snooze],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func reschedule(
        items: [ChecklistItem],
        groups: [ChecklistGroup],
        eveningMinutes: Int?,
        groupFilter: NotificationGroupFilter
    ) async {
        #if DEBUG
        if ScreenshotSeedData.isEnabled { return }
        #endif
        let pending = await center.pendingNotificationRequests()
        let managed = pending.map(\.identifier).filter {
            $0.hasPrefix("ritual.item.") || $0.hasPrefix("ritual.evening.")
        }
        center.removePendingNotificationRequests(withIdentifiers: managed)

        let calendar = Calendar.current
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        func isPaused(_ item: ChecklistItem, on date: Date) -> Bool {
            if item.isPaused(on: date) { return true }
            guard let groupID = item.groupID else { return false }
            return groupsByID[groupID]?.isPaused(on: date) == true
        }
        var itemReminders: [(
            date: Date,
            item: ChecklistItem,
            occurrenceDateKey: String,
            occurrenceID: String,
            isCarryover: Bool
        )] = []
        for dayOffset in 0..<60 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: .now) else { continue }
            let carryoversByItemID = Dictionary(uniqueKeysWithValues: CarryoverResolver.entries(
                items: items,
                groups: groups,
                asOf: date
            ).map { ($0.item.id, $0) })
            let allCarryoverItemIDs = Set(CarryoverResolver.entries(
                items: items,
                groups: groups,
                asOf: date,
                includeHidden: true
            ).map(\.item.id))
            for item in items {
                if allCarryoverItemIDs.contains(item.id), carryoversByItemID[item.id] == nil {
                    continue
                }
                guard let minutes = item.reminderMinutes,
                      !isPaused(item, on: date),
                      carryoversByItemID[item.id] != nil
                        || item.occurs(on: date)
                        || item.isExplicitlyOpen(on: date) else { continue }
                var fireDate = calendar.dateComponents([.year, .month, .day], from: date)
                fireDate.hour = minutes / 60
                fireDate.minute = minutes % 60
                guard let scheduledDate = calendar.date(from: fireDate), scheduledDate > .now else { continue }
                let carryover = carryoversByItemID[item.id]
                let occurrenceDateKey = carryover?.latestScheduledDateKey ?? DateKey.string(from: date)
                itemReminders.append((
                    scheduledDate,
                    item,
                    occurrenceDateKey,
                    carryover?.latestOccurrenceID ?? ChecklistOccurrenceIdentifier.string(
                        itemID: item.id,
                        scheduleRevision: item.scheduleRevision,
                        scheduledDateKey: occurrenceDateKey
                    ),
                    carryover != nil
                ))
            }
        }

        for reminder in itemReminders.sorted(by: { $0.date < $1.date }).prefix(50) {
            let content = UNMutableNotificationContent()
            content.title = reminder.item.title
            content.body = reminder.isCarryover
                ? "This task is still open from an earlier scheduled date."
                : (reminder.item.notes.isEmpty ? "Time for this task." : reminder.item.notes)
            content.sound = .default
            content.categoryIdentifier = RitualNotificationAction.itemCategory
            content.userInfo = [
                "itemID": reminder.item.id.uuidString,
                "date": DateKey.string(from: reminder.date),
                "occurrenceDate": reminder.occurrenceDateKey,
                "occurrenceID": reminder.occurrenceID,
                "isCarryover": reminder.isCarryover
            ]
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date),
                repeats: false
            )
            try? await center.add(UNNotificationRequest(
                identifier: "ritual.item.\(reminder.item.id).\(DateKey.string(from: reminder.date))",
                content: content,
                trigger: trigger
            ))
        }

        guard let eveningMinutes else { return }
        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: .now) else { continue }
            let carryovers = CarryoverResolver.entries(items: items, groups: groups, asOf: date)
                .filter { groupFilter.includes(item: $0.item) }
            let carryoverItemIDs = Set(CarryoverResolver.entries(
                items: items,
                groups: groups,
                asOf: date,
                includeHidden: true
            ).map(\.item.id))
            let remainingToday = items.filter {
                !isPaused($0, on: date)
                    && groupFilter.includes(item: $0)
                    && !carryoverItemIDs.contains($0.id)
                    && ($0.occurs(on: date) || $0.isExplicitlyOpen(on: date))
                    && !$0.isComplete(on: date)
                    && !$0.isSkipped(on: date)
            }.count
            let stillOpen = carryovers.count
            guard remainingToday + stillOpen > 0 else { continue }

            var fireDate = calendar.dateComponents([.year, .month, .day], from: date)
            fireDate.hour = eveningMinutes / 60
            fireDate.minute = eveningMinutes % 60
            guard let scheduledDate = calendar.date(from: fireDate), scheduledDate > .now else { continue }

            let content = UNMutableNotificationContent()
            if stillOpen == 0 {
                content.title = remainingToday == 1 ? "1 task left today" : "\(remainingToday) tasks left today"
            } else if remainingToday == 0 {
                content.title = stillOpen == 1 ? "1 task still open" : "\(stillOpen) tasks still open"
            } else {
                content.title = "\(remainingToday) today · \(stillOpen) still open"
            }
            content.body = stillOpen > 0
                ? "Your scheduled tasks and missed routines are ready for a quick check-in."
                : "A quick check-in before the day wraps up."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: fireDate, repeats: false)
            try? await center.add(UNNotificationRequest(
                identifier: "ritual.evening.\(DateKey.string(from: date))",
                content: content,
                trigger: trigger
            ))
        }
    }

    func snooze(
        item: ChecklistItem,
        occurrenceDate: Date,
        occurrenceID: String? = nil,
        isCarryover: Bool = false,
        minutes: Int
    ) async {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.notes.isEmpty ? "Snoozed reminder." : item.notes
        content.sound = .default
        content.categoryIdentifier = RitualNotificationAction.itemCategory
        content.userInfo = [
            "itemID": item.id.uuidString,
            "date": DateKey.string(from: occurrenceDate),
            "occurrenceDate": DateKey.string(from: occurrenceDate),
            "occurrenceID": ChecklistOccurrenceIdentifier.string(
                itemID: item.id,
                scheduleRevision: item.scheduleRevision,
                scheduledDateKey: DateKey.string(from: occurrenceDate)
            ),
            "isCarryover": isCarryover
        ]
        if let occurrenceID {
            content.userInfo["occurrenceID"] = occurrenceID
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(1, minutes) * 60), repeats: false)
        try? await center.add(UNNotificationRequest(
            identifier: "ritual.snooze.\(item.id).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        ))
    }
}
