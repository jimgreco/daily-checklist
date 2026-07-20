import Foundation
import UserNotifications

extension Notification.Name {
    static let ritualNotificationAction = Notification.Name("RitualNotificationAction")
}

struct RitualNotificationAction {
    static let complete = "RITUAL_COMPLETE"
    static let skip = "RITUAL_SKIP"
    static let snooze = "RITUAL_SNOOZE"
    static let snooze15 = "RITUAL_SNOOZE_15"
    static let snooze60 = "RITUAL_SNOOZE_60"
    static let itemCategory = "RITUAL_ITEM_REMINDER"
}

enum ReminderSnoozePreset: String, CaseIterable, Identifiable {
    case fifteenMinutes
    case oneHour
    case tomorrowMorning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .tomorrowMorning: "Tomorrow morning"
        }
    }
}

enum NotificationPermissionState: String, Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var allowsScheduling: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .unknown, .notDetermined, .denied: false
        }
    }
}

struct NotificationSchedulingStatus: Equatable {
    var permission: NotificationPermissionState
    var scheduledItemCount: Int
    var scheduledFollowUpCount: Int
    var scheduledEveningCount: Int
    var retainedSnoozeCount: Int
    var droppedCount: Int

    static let unknown = NotificationSchedulingStatus(
        permission: .unknown,
        scheduledItemCount: 0,
        scheduledFollowUpCount: 0,
        scheduledEveningCount: 0,
        retainedSnoozeCount: 0,
        droppedCount: 0
    )

    var isCapacityConstrained: Bool { droppedCount > 0 }

    var scheduledCount: Int {
        scheduledItemCount + scheduledFollowUpCount + scheduledEveningCount + retainedSnoozeCount
    }
}

struct NotificationPlanner {
    static func followUpDates(
        after reminderDate: Date,
        policy: ReminderFollowUpPolicy,
        quietHours: NotificationQuietHours?,
        calendar: Calendar = .current
    ) -> [Date] {
        guard quietHours?.contains(reminderDate, calendar: calendar) != true else { return [] }
        let cutoff = quietHours?.nextStart(after: reminderDate, calendar: calendar)
        var dates: [Date] = []
        for index in 1...policy.maximumCount {
            guard let date = calendar.date(
                byAdding: .minute,
                value: policy.delayMinutes * index,
                to: reminderDate
            ) else { break }
            if quietHours?.contains(date, calendar: calendar) == true { break }
            if let cutoff, date >= cutoff { break }
            dates.append(date)
        }
        return dates
    }

    static func snoozeDate(
        for preset: ReminderSnoozePreset,
        now: Date = .now,
        quietHours: NotificationQuietHours?,
        calendar: Calendar = .current
    ) -> Date {
        let proposed: Date
        switch preset {
        case .fifteenMinutes:
            proposed = calendar.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(15 * 60)
        case .oneHour:
            proposed = calendar.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(60 * 60)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                ?? now.addingTimeInterval(24 * 60 * 60)
            let morningMinutes = quietHours?.endMinutes ?? 8 * 60
            proposed = calendar.date(
                bySettingHour: morningMinutes / 60,
                minute: morningMinutes % 60,
                second: 0,
                of: tomorrow
            ) ?? tomorrow
        }
        return quietHours?.nextAllowedDate(atOrAfter: proposed, calendar: calendar) ?? proposed
    }
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
            RitualNotificationAction.snooze,
            RitualNotificationAction.snooze15,
            RitualNotificationAction.snooze60
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
    private struct ItemReminder {
        var date: Date
        var item: ChecklistItem
        var occurrenceDateKey: String
        var occurrenceID: String
        var isCarryover: Bool
    }

    private struct EveningReminder {
        var date: Date
        var remainingToday: Int
        var stillOpen: Int
    }

    private let center = UNUserNotificationCenter.current()
    private static let maximumManagedRequests = 60
    private static let maximumItemReminders = 50
    private static let maximumEveningReminders = 7

    func requestAuthorization() async -> NotificationPermissionState {
        #if DEBUG
        if ScreenshotSeedData.isEnabled { return .authorized }
        #endif
        configureCategories()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return permissionState(for: await center.notificationSettings().authorizationStatus)
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
        let snooze15 = UNNotificationAction(
            identifier: RitualNotificationAction.snooze15,
            title: "Snooze 15m",
            options: []
        )
        let snooze60 = UNNotificationAction(
            identifier: RitualNotificationAction.snooze60,
            title: "Snooze 1h",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: RitualNotificationAction.itemCategory,
                actions: [complete, skip, snooze15, snooze60],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func reschedule(
        items: [ChecklistItem],
        groups: [ChecklistGroup],
        eveningMinutes: Int?,
        groupFilter: NotificationGroupFilter,
        quietHours: NotificationQuietHours?
    ) async -> NotificationSchedulingStatus {
        #if DEBUG
        if ScreenshotSeedData.isEnabled {
            return NotificationSchedulingStatus(
                permission: .authorized,
                scheduledItemCount: 0,
                scheduledFollowUpCount: 0,
                scheduledEveningCount: 0,
                retainedSnoozeCount: 0,
                droppedCount: 0
            )
        }
        #endif
        configureCategories()
        let permission = permissionState(for: await center.notificationSettings().authorizationStatus)
        let pending = await center.pendingNotificationRequests()
        let scheduledPrefixes = ["ritual.item.", "ritual.followup.", "ritual.evening."]
        let scheduledRequestIDs = pending.map(\.identifier).filter { identifier in
            scheduledPrefixes.contains { identifier.hasPrefix($0) }
        }
        let snoozes = pending.filter { $0.identifier.hasPrefix("ritual.snooze.") }
        let invalidSnoozeIDs = permission.allowsScheduling
            ? snoozes.filter {
                !isPendingSnoozeValid($0, items: items, groups: groups)
            }.map(\.identifier)
            : snoozes.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: scheduledRequestIDs + invalidSnoozeIDs)

        let retainedSnoozeCount = snoozes.count - invalidSnoozeIDs.count
        guard permission.allowsScheduling else {
            return NotificationSchedulingStatus(
                permission: permission,
                scheduledItemCount: 0,
                scheduledFollowUpCount: 0,
                scheduledEveningCount: 0,
                retainedSnoozeCount: retainedSnoozeCount,
                droppedCount: 0
            )
        }
        guard !Task.isCancelled else { return .unknown }

        let unmanagedCount = pending.filter { request in
            !scheduledPrefixes.contains(where: { request.identifier.hasPrefix($0) })
                && !request.identifier.hasPrefix("ritual.snooze.")
        }.count
        var remainingCapacity = max(
            0,
            Self.maximumManagedRequests - unmanagedCount - retainedSnoozeCount
        )
        let itemReminders = itemReminderCandidates(items: items, groups: groups)
        let eveningReminders = eveningReminderCandidates(
            items: items,
            groups: groups,
            eveningMinutes: eveningMinutes,
            groupFilter: groupFilter
        )

        let selectedEvenings = Array(eveningReminders.prefix(min(Self.maximumEveningReminders, remainingCapacity)))
        remainingCapacity -= selectedEvenings.count

        let baseCandidates = Array(itemReminders.prefix(Self.maximumItemReminders))
        let followUps = baseCandidates.flatMap { reminder -> [(Date, ItemReminder, Int)] in
            guard let policy = reminder.item.followUpPolicy else { return [] }
            return NotificationPlanner.followUpDates(
                after: reminder.date,
                policy: policy,
                quietHours: quietHours
            ).enumerated().map { ($0.element, reminder, $0.offset + 1) }
        }
        let itemEvents = (
            baseCandidates.map { ($0.date, $0, Optional<Int>.none) }
                + followUps.map { ($0.0, $0.1, Optional($0.2)) }
        ).sorted { left, right in
            if left.0 != right.0 { return left.0 < right.0 }
            return left.2 == nil && right.2 != nil
        }
        let selectedItemEvents = Array(itemEvents.prefix(remainingCapacity))
        let selectedItems = selectedItemEvents.compactMap { event in
            event.2 == nil ? event.1 : nil
        }
        let selectedFollowUps = selectedItemEvents.compactMap { event -> (Date, ItemReminder, Int)? in
            guard let index = event.2 else { return nil }
            return (event.0, event.1, index)
        }

        var scheduledItemCount = 0
        var scheduledEveningCount = 0
        var scheduledFollowUpCount = 0
        var failedCount = 0

        for reminder in selectedItems {
            guard !Task.isCancelled else { break }
            let content = itemContent(for: reminder, followUpIndex: nil)
            let trigger = calendarTrigger(for: reminder.date)
            do {
                try await center.add(UNNotificationRequest(
                    identifier: "ritual.item.\(reminder.item.id).\(DateKey.string(from: reminder.date))",
                    content: content,
                    trigger: trigger
                ))
                scheduledItemCount += 1
            } catch {
                failedCount += 1
            }
        }

        for reminder in selectedEvenings {
            guard !Task.isCancelled else { break }
            let content = UNMutableNotificationContent()
            if reminder.stillOpen == 0 {
                content.title = reminder.remainingToday == 1
                    ? "1 task left today"
                    : "\(reminder.remainingToday) tasks left today"
            } else if reminder.remainingToday == 0 {
                content.title = reminder.stillOpen == 1
                    ? "1 task still open"
                    : "\(reminder.stillOpen) tasks still open"
            } else {
                content.title = "\(reminder.remainingToday) today · \(reminder.stillOpen) still open"
            }
            content.body = reminder.stillOpen > 0
                ? "Your scheduled tasks and missed routines are ready for a quick check-in."
                : "A quick check-in before the day wraps up."
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(
                    identifier: "ritual.evening.\(DateKey.string(from: reminder.date))",
                    content: content,
                    trigger: calendarTrigger(for: reminder.date)
                ))
                scheduledEveningCount += 1
            } catch {
                failedCount += 1
            }
        }

        for (date, reminder, index) in selectedFollowUps {
            guard !Task.isCancelled else { break }
            let content = itemContent(for: reminder, followUpIndex: index)
            do {
                try await center.add(UNNotificationRequest(
                    identifier: "ritual.followup.\(reminder.item.id).\(DateKey.string(from: reminder.date)).\(index)",
                    content: content,
                    trigger: calendarTrigger(for: date)
                ))
                scheduledFollowUpCount += 1
            } catch {
                failedCount += 1
            }
        }

        let droppedCount = max(0, itemReminders.count - baseCandidates.count)
            + max(0, itemEvents.count - selectedItemEvents.count)
            + max(0, eveningReminders.count - selectedEvenings.count)
            + failedCount
        return NotificationSchedulingStatus(
            permission: permission,
            scheduledItemCount: scheduledItemCount,
            scheduledFollowUpCount: scheduledFollowUpCount,
            scheduledEveningCount: scheduledEveningCount,
            retainedSnoozeCount: retainedSnoozeCount,
            droppedCount: droppedCount
        )
    }

    func snooze(
        item: ChecklistItem,
        occurrenceDate: Date,
        occurrenceID: String? = nil,
        isCarryover: Bool = false,
        preset: ReminderSnoozePreset,
        quietHours: NotificationQuietHours?
    ) async -> Bool {
        let permission = permissionState(for: await center.notificationSettings().authorizationStatus)
        guard permission.allowsScheduling else { return false }
        configureCategories()
        let pending = await center.pendingNotificationRequests()
        let matchingSnoozes = pending.filter { request in
            guard request.identifier.hasPrefix("ritual.snooze."),
                  request.content.userInfo["itemID"] as? String == item.id.uuidString else { return false }
            guard let occurrenceID else { return true }
            return request.content.userInfo["occurrenceID"] as? String == occurrenceID
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: matchingSnoozes)
        guard pending.count - matchingSnoozes.count < 64 else { return false }

        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.notes.isEmpty ? "Snoozed reminder." : item.notes
        content.sound = .default
        content.categoryIdentifier = RitualNotificationAction.itemCategory
        content.userInfo = [
            "itemID": item.id.uuidString,
            "date": DateKey.string(from: occurrenceDate),
            "occurrenceDate": DateKey.string(from: occurrenceDate),
            "occurrenceID": occurrenceID ?? ChecklistOccurrenceIdentifier.string(
                itemID: item.id,
                scheduleRevision: item.scheduleRevision,
                scheduledDateKey: DateKey.string(from: occurrenceDate)
            ),
            "isCarryover": isCarryover
        ]
        let date = NotificationPlanner.snoozeDate(
            for: preset,
            quietHours: quietHours
        )
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(60, date.timeIntervalSinceNow),
            repeats: false
        )
        do {
            try await center.add(UNNotificationRequest(
                identifier: "ritual.snooze.\(item.id).\(Date().timeIntervalSince1970)",
                content: content,
                trigger: trigger
            ))
            return true
        } catch {
            return false
        }
    }

    private func itemReminderCandidates(
        items: [ChecklistItem],
        groups: [ChecklistGroup]
    ) -> [ItemReminder] {
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        func isPaused(_ item: ChecklistItem, on date: Date) -> Bool {
            if item.isPaused(on: date) { return true }
            guard let groupID = item.groupID else { return false }
            return groupsByID[groupID]?.isPaused(on: date) == true
        }
        var reminders: [ItemReminder] = []
        for dayOffset in 0..<60 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let visibleCarryovers = CarryoverResolver.entries(items: items, groups: groups, asOf: date)
            let carryoversByItemID = Dictionary(uniqueKeysWithValues: visibleCarryovers.map { ($0.item.id, $0) })
            let allCarryoverItemIDs = Set(CarryoverResolver.entries(
                items: items,
                groups: groups,
                asOf: date,
                includeHidden: true
            ).map(\.item.id))
            for item in items {
                if allCarryoverItemIDs.contains(item.id), carryoversByItemID[item.id] == nil { continue }
                let carryover = carryoversByItemID[item.id]
                guard let minutes = item.reminderMinutes,
                      !isPaused(item, on: date),
                      carryover != nil || (
                        !item.isComplete(on: date)
                            && !item.isSkipped(on: date)
                            && (item.occurs(on: date) || item.isExplicitlyOpen(on: date))
                      ) else { continue }
                var components = calendar.dateComponents([.year, .month, .day], from: date)
                components.hour = minutes / 60
                components.minute = minutes % 60
                guard let scheduledDate = calendar.date(from: components), scheduledDate > now else { continue }
                let occurrenceDateKey = carryover?.latestScheduledDateKey ?? DateKey.string(from: date)
                reminders.append(ItemReminder(
                    date: scheduledDate,
                    item: item,
                    occurrenceDateKey: occurrenceDateKey,
                    occurrenceID: carryover?.latestOccurrenceID ?? ChecklistOccurrenceIdentifier.string(
                        itemID: item.id,
                        scheduleRevision: item.scheduleRevision,
                        scheduledDateKey: occurrenceDateKey
                    ),
                    isCarryover: carryover != nil
                ))
            }
        }
        return reminders.sorted { $0.date < $1.date }
    }

    private func eveningReminderCandidates(
        items: [ChecklistItem],
        groups: [ChecklistGroup],
        eveningMinutes: Int?,
        groupFilter: NotificationGroupFilter
    ) -> [EveningReminder] {
        guard let eveningMinutes else { return [] }
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        func isPaused(_ item: ChecklistItem, on date: Date) -> Bool {
            if item.isPaused(on: date) { return true }
            guard let groupID = item.groupID else { return false }
            return groupsByID[groupID]?.isPaused(on: date) == true
        }
        var reminders: [EveningReminder] = []
        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
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
            guard remainingToday + carryovers.count > 0 else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: date)
            components.hour = eveningMinutes / 60
            components.minute = eveningMinutes % 60
            guard let scheduledDate = calendar.date(from: components), scheduledDate > now else { continue }
            reminders.append(EveningReminder(
                date: scheduledDate,
                remainingToday: remainingToday,
                stillOpen: carryovers.count
            ))
        }
        return reminders.sorted { $0.date < $1.date }
    }

    private func itemContent(
        for reminder: ItemReminder,
        followUpIndex: Int?
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = reminder.item.title
        if followUpIndex != nil {
            content.body = reminder.isCarryover
                ? "This task is still open from an earlier scheduled date."
                : "Still unfinished. Open Ritual Cue when you are ready."
        } else {
            content.body = reminder.isCarryover
                ? "This task is still open from an earlier scheduled date."
                : (reminder.item.notes.isEmpty ? "Time for this task." : reminder.item.notes)
        }
        content.sound = .default
        content.categoryIdentifier = RitualNotificationAction.itemCategory
        content.userInfo = [
            "itemID": reminder.item.id.uuidString,
            "date": DateKey.string(from: reminder.date),
            "occurrenceDate": reminder.occurrenceDateKey,
            "occurrenceID": reminder.occurrenceID,
            "isCarryover": reminder.isCarryover,
            "followUpIndex": followUpIndex ?? 0
        ]
        return content
    }

    private func calendarTrigger(for date: Date) -> UNCalendarNotificationTrigger {
        UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: date
            ),
            repeats: false
        )
    }

    private func isPendingSnoozeValid(
        _ request: UNNotificationRequest,
        items: [ChecklistItem],
        groups: [ChecklistGroup]
    ) -> Bool {
        let info = request.content.userInfo
        guard let rawItemID = info["itemID"] as? String,
              let itemID = UUID(uuidString: rawItemID),
              let item = items.first(where: { $0.id == itemID }),
              let dateKey = info["occurrenceDate"] as? String,
              let date = DateKey.date(from: dateKey),
              item.isActive(on: date),
              !item.isComplete(on: date),
              !item.isSkipped(on: date) else { return false }
        if item.isPaused(on: date) { return false }
        if let groupID = item.groupID,
           groups.first(where: { $0.id == groupID })?.isPaused(on: date) == true { return false }
        let occurrenceID = info["occurrenceID"] as? String
        if info["isCarryover"] as? Bool == true {
            return CarryoverResolver.entries(
                items: items,
                groups: groups,
                includeHidden: true
            ).contains { entry in
                entry.item.id == itemID
                    && (occurrenceID == nil || entry.occurrences.contains(where: { $0.id == occurrenceID }))
            }
        }
        if let occurrenceID,
           let parsed = ChecklistOccurrenceIdentifier.parse(occurrenceID),
           parsed.itemID == itemID,
           let occurrence = item.occurrence(
                scheduledDate: parsed.scheduledDateKey,
                scheduleRevision: parsed.scheduleRevision
           ),
           [.done, .skipped, .missed].contains(occurrence.outcome) {
            return false
        }
        return item.occurs(on: date) || item.isExplicitlyOpen(on: date)
    }

    private func permissionState(for status: UNAuthorizationStatus) -> NotificationPermissionState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }
}
