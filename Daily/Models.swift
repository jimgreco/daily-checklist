import Foundation

enum WeekdayAbbreviation {
    static let twoLetter = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
}

enum ScheduleKind: String, Codable, CaseIterable, Identifiable {
    case everyDay
    case weekdays
    case weekends
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyDay: "Every day"
        case .weekdays: "Weekdays"
        case .weekends: "Weekends"
        case .custom: "Custom"
        }
    }
}

struct ChecklistGroup: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var sortOrder: Double

    init(id: UUID = UUID(), name: String, sortOrder: Double = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

struct ChecklistItem: Identifiable, Codable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case notes
        case schedule
        case customWeekdays
        case reminderMinutes
        case completedDates
        case skippedDates
        case openDates
        case createdAt
        case startDate
        case endedAt
        case groupID
        case sortOrder
    }

    var id: UUID
    var title: String
    var notes: String
    var schedule: ScheduleKind
    var customWeekdays: Set<Int>
    var reminderMinutes: Int?
    var completedDates: Set<String>
    var skippedDates: Set<String>
    var openDates: Set<String>
    var createdAt: Date
    var startDate: Date?
    var endedAt: Date?
    var groupID: UUID?
    var sortOrder: Double?

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        schedule: ScheduleKind = .everyDay,
        customWeekdays: Set<Int> = [],
        reminderMinutes: Int? = nil,
        completedDates: Set<String> = [],
        skippedDates: Set<String> = [],
        openDates: Set<String> = [],
        createdAt: Date = .now,
        startDate: Date? = nil,
        endedAt: Date? = nil,
        groupID: UUID? = nil,
        sortOrder: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.schedule = schedule
        self.customWeekdays = customWeekdays
        self.reminderMinutes = reminderMinutes
        self.completedDates = completedDates
        self.skippedDates = skippedDates
        self.openDates = openDates
        self.createdAt = createdAt
        self.startDate = startDate
        self.endedAt = endedAt
        self.groupID = groupID
        self.sortOrder = sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        schedule = try container.decodeIfPresent(ScheduleKind.self, forKey: .schedule) ?? .everyDay
        customWeekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .customWeekdays) ?? []
        reminderMinutes = try container.decodeIfPresent(Int.self, forKey: .reminderMinutes)
        completedDates = try container.decodeIfPresent(Set<String>.self, forKey: .completedDates) ?? []
        skippedDates = try container.decodeIfPresent(Set<String>.self, forKey: .skippedDates) ?? []
        openDates = try container.decodeIfPresent(Set<String>.self, forKey: .openDates) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder)
    }

    func isActive(on date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        let firstDay = calendar.startOfDay(for: startDate ?? createdAt)
        guard day >= firstDay else { return false }
        guard let endedAt else { return true }
        return day < calendar.startOfDay(for: endedAt)
    }

    func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        guard isActive(on: date, calendar: calendar) else { return false }
        let weekday = calendar.component(.weekday, from: date)
        switch schedule {
        case .everyDay: return true
        case .weekdays: return (2...6).contains(weekday)
        case .weekends: return weekday == 1 || weekday == 7
        case .custom: return customWeekdays.contains(weekday)
        }
    }

    func isComplete(on date: Date) -> Bool {
        completedDates.contains(DateKey.string(from: date))
    }

    func isSkipped(on date: Date) -> Bool {
        skippedDates.contains(DateKey.string(from: date))
    }

    func isExplicitlyOpen(on date: Date) -> Bool {
        openDates.contains(DateKey.string(from: date))
    }

    func hasRecordedState(on date: Date) -> Bool {
        isComplete(on: date) || isSkipped(on: date) || isExplicitlyOpen(on: date)
    }

    func isTracked(on date: Date, calendar: Calendar = .current) -> Bool {
        occurs(on: date, calendar: calendar) || hasRecordedState(on: date)
    }

    func firstTrackedDate(calendar: Calendar = .current) -> Date {
        let firstActiveDate = calendar.startOfDay(for: startDate ?? createdAt)
        let recordedDates = (completedDates.union(skippedDates).union(openDates))
            .compactMap(DateKey.date(from:))
            .map { calendar.startOfDay(for: $0) }
        guard let firstRecordedDate = recordedDates.min() else { return firstActiveDate }
        return min(firstActiveDate, firstRecordedDate)
    }

    func historyState(on date: Date, calendar: Calendar = .current) -> ChecklistHistoryState {
        let day = calendar.startOfDay(for: date)
        if isComplete(on: day) { return .done }
        if isSkipped(on: day) { return .skipped }
        if isExplicitlyOpen(on: day) { return .open }
        if occurs(on: day, calendar: calendar) {
            return day < calendar.startOfDay(for: .now) ? .missed : .open
        }
        return .off
    }

    func consecutiveMissedDays(asOf date: Date, calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: .now)
        var cursor = min(calendar.startOfDay(for: date), today)
        let firstEligibleDate = firstTrackedDate(calendar: calendar)
        var missedDays = 0

        // The current day is still in progress, so it cannot be considered missed yet.
        if cursor >= today {
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                return 0
            }
            cursor = previousDay
        }

        while cursor >= firstEligibleDate {
            if isTracked(on: cursor, calendar: calendar) {
                if isComplete(on: cursor) || isSkipped(on: cursor) {
                    break
                }
                missedDays += 1
            }

            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previousDay
        }

        return missedDays
    }

    func consecutiveCompletedDays(asOf date: Date, calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: .now)
        let selectedDay = calendar.startOfDay(for: date)
        var cursor = min(selectedDay, today)
        let firstEligibleDate = firstTrackedDate(calendar: calendar)
        var completedDays = 0

        if cursor >= today && !isComplete(on: cursor) {
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                return 0
            }
            cursor = previousDay
        } else if selectedDay < today && !isComplete(on: cursor) {
            return 0
        }

        while cursor >= firstEligibleDate {
            if isTracked(on: cursor, calendar: calendar) {
                guard isComplete(on: cursor) else { break }
                completedDays += 1
            }

            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previousDay
        }

        return completedDays
    }

    func delayedDays(asOf date: Date, calendar: Calendar = .current) -> Int {
        let day = calendar.startOfDay(for: date)
        guard isExplicitlyOpen(on: day), !isComplete(on: day), !isSkipped(on: day) else { return 0 }

        var cursor = day
        var delayedDays = 0
        while let previousDate = calendar.date(byAdding: .day, value: -1, to: cursor) {
            let previousDay = calendar.startOfDay(for: previousDate)
            guard isSkipped(on: previousDay) else { break }
            delayedDays += 1
            cursor = previousDay
        }
        return delayedDays
    }

    var scheduleSummary: String {
        guard schedule == .custom else { return schedule.title }
        return (1...7)
            .filter(customWeekdays.contains)
            .map { WeekdayAbbreviation.twoLetter[$0 - 1] }
            .joined(separator: " · ")
    }

    mutating func delay(from date: Date, calendar: Calendar = .current) throws -> ChecklistDateMoveChange {
        guard schedule != .everyDay else { throw ChecklistDelayError.dailyItem }
        let sourceDate = calendar.startOfDay(for: date)
        guard let nextDate = calendar.date(byAdding: .day, value: 1, to: sourceDate) else {
            throw ChecklistDelayError.nextDateUnavailable
        }
        return moveOpenDate(from: sourceDate, to: calendar.startOfDay(for: nextDate))
    }

    mutating func bringForward(from date: Date, to targetDate: Date = .now, calendar: Calendar = .current) throws -> ChecklistDateMoveChange {
        guard schedule != .everyDay else { throw ChecklistBringForwardError.dailyItem }
        let sourceDate = calendar.startOfDay(for: date)
        let targetDate = calendar.startOfDay(for: targetDate)
        guard sourceDate > targetDate else { throw ChecklistBringForwardError.notInFuture }
        return moveOpenDate(from: sourceDate, to: targetDate)
    }

    private mutating func moveOpenDate(from sourceDate: Date, to targetDate: Date) -> ChecklistDateMoveChange {
        let sourceKey = DateKey.string(from: sourceDate)
        let targetKey = DateKey.string(from: targetDate)
        let change = ChecklistDateMoveChange(
            sourceKey: sourceKey,
            targetKey: targetKey,
            wasSourceCompleted: completedDates.contains(sourceKey),
            wasSourceSkipped: skippedDates.contains(sourceKey),
            wasSourceOpen: openDates.contains(sourceKey),
            wasTargetCompleted: completedDates.contains(targetKey),
            wasTargetSkipped: skippedDates.contains(targetKey),
            wasTargetOpen: openDates.contains(targetKey)
        )

        completedDates.remove(sourceKey)
        skippedDates.insert(sourceKey)
        openDates.remove(sourceKey)
        completedDates.remove(targetKey)
        skippedDates.remove(targetKey)
        openDates.insert(targetKey)
        return change
    }
}

enum ChecklistDelayError: LocalizedError, Equatable {
    case dailyItem
    case nextDateUnavailable

    var errorDescription: String? {
        switch self {
        case .dailyItem:
            "Daily items already appear tomorrow. Delay is only for items scheduled a few times a week."
        case .nextDateUnavailable:
            "This item could not be delayed to the next day."
        }
    }
}

enum ChecklistBringForwardError: LocalizedError, Equatable {
    case dailyItem
    case notInFuture

    var errorDescription: String? {
        switch self {
        case .dailyItem:
            "Daily items already appear today. Bring forward is only for items scheduled a few times a week."
        case .notInFuture:
            "Only future items can be brought forward to today."
        }
    }
}

struct ChecklistDateMoveChange {
    var sourceKey: String
    var targetKey: String
    var wasSourceCompleted: Bool
    var wasSourceSkipped: Bool
    var wasSourceOpen: Bool
    var wasTargetCompleted: Bool
    var wasTargetSkipped: Bool
    var wasTargetOpen: Bool
}

struct LocalEnvelope: Codable {
    var items: [ChecklistItem]
    var groups: [ChecklistGroup]?
    var eveningReminderMinutes: Int?
    var pendingMutations: [SyncMutation]
}

struct LegacyEnvelope: Codable {
    var items: [ChecklistItem]
    var eveningReminderMinutes: Int?
    var updatedAt: Date
}

struct ItemPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case title
        case notes
        case schedule
        case customWeekdays
        case reminderMinutes
        case skippedDates
        case openDates
        case createdAt
        case startDate
        case endedAt
        case groupID
        case sortOrder
    }

    var title: String
    var notes: String
    var schedule: ScheduleKind
    var customWeekdays: Set<Int>
    var reminderMinutes: Int?
    var skippedDates: Set<String>
    var openDates: Set<String>
    var createdAt: Date
    var startDate: Date?
    var endedAt: Date?
    var groupID: UUID?
    var sortOrder: Double?

    init(
        title: String,
        notes: String,
        schedule: ScheduleKind,
        customWeekdays: Set<Int>,
        reminderMinutes: Int?,
        skippedDates: Set<String>,
        openDates: Set<String>,
        createdAt: Date,
        startDate: Date?,
        endedAt: Date?,
        groupID: UUID?,
        sortOrder: Double?
    ) {
        self.title = title
        self.notes = notes
        self.schedule = schedule
        self.customWeekdays = customWeekdays
        self.reminderMinutes = reminderMinutes
        self.skippedDates = skippedDates
        self.openDates = openDates
        self.createdAt = createdAt
        self.startDate = startDate
        self.endedAt = endedAt
        self.groupID = groupID
        self.sortOrder = sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        schedule = try container.decodeIfPresent(ScheduleKind.self, forKey: .schedule) ?? .everyDay
        customWeekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .customWeekdays) ?? []
        reminderMinutes = try container.decodeIfPresent(Int.self, forKey: .reminderMinutes)
        skippedDates = try container.decodeIfPresent(Set<String>.self, forKey: .skippedDates) ?? []
        openDates = try container.decodeIfPresent(Set<String>.self, forKey: .openDates) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder)
    }
}

struct GroupPayload: Codable {
    var name: String
    var sortOrder: Double
}

struct SyncMutation: Identifiable, Codable {
    enum Kind: String, Codable {
        case upsert
        case delete
        case completion
        case eveningReminder
        case groupUpsert
        case groupDelete
    }

    var id: UUID
    var itemID: UUID?
    var groupID: UUID?
    var kind: Kind
    var stamp: String
    var changedFields: Set<String>?
    var item: ItemPayload?
    var group: GroupPayload?
    var completionDate: String?
    var completed: Bool?
    var eveningReminderMinutes: Int?

    static func upsert(item: ChecklistItem, changedFields: Set<String>) -> SyncMutation {
        SyncMutation(
            id: UUID(),
            itemID: item.id,
            kind: .upsert,
            stamp: SyncStamp.now,
            changedFields: changedFields,
            item: ItemPayload(
                title: item.title,
                notes: item.notes,
                schedule: item.schedule,
                customWeekdays: item.customWeekdays,
                reminderMinutes: item.reminderMinutes,
                skippedDates: item.skippedDates,
                openDates: item.openDates,
                createdAt: item.createdAt,
                startDate: item.startDate,
                endedAt: item.endedAt,
                groupID: item.groupID,
                sortOrder: item.sortOrder
            )
        )
    }

    static func upsert(group: ChecklistGroup, changedFields: Set<String>) -> SyncMutation {
        SyncMutation(
            id: UUID(),
            groupID: group.id,
            kind: .groupUpsert,
            stamp: SyncStamp.now,
            changedFields: changedFields,
            group: GroupPayload(name: group.name, sortOrder: group.sortOrder)
        )
    }

    static func delete(groupID: UUID) -> SyncMutation {
        SyncMutation(id: UUID(), groupID: groupID, kind: .groupDelete, stamp: SyncStamp.now)
    }

    static func delete(itemID: UUID) -> SyncMutation {
        SyncMutation(id: UUID(), itemID: itemID, kind: .delete, stamp: SyncStamp.now)
    }

    static func completion(itemID: UUID, date: String, completed: Bool) -> SyncMutation {
        SyncMutation(
            id: UUID(),
            itemID: itemID,
            kind: .completion,
            stamp: SyncStamp.now,
            completionDate: date,
            completed: completed
        )
    }

    static func evening(minutes: Int?) -> SyncMutation {
        SyncMutation(
            id: UUID(),
            kind: .eveningReminder,
            stamp: SyncStamp.now,
            eveningReminderMinutes: minutes
        )
    }
}

struct SyncRequest: Codable {
    var deviceID: String
    var mutations: [SyncMutation]
}

struct SyncResponse: Codable {
    var items: [ChecklistItem]
    var groups: [ChecklistGroup]?
    var eveningReminderMinutes: Int?
    var acceptedMutationIDs: [UUID]
}

struct AppUser: Codable {
    var id: String
    var email: String
    var name: String
    var profileImageURL: URL?
}

struct AuthResponse: Codable {
    var token: String
    var refreshToken: String
    var user: AppUser
}

enum SyncStamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var now: String {
        formatter.string(from: Date())
    }
}

enum ChecklistHistoryState: String, CaseIterable, Identifiable {
    case done = "Done"
    case skipped = "Skipped"
    case missed = "Missed"
    case open = "Open"
    case off = "Off"

    var id: String { rawValue }
}

enum DateKey {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from key: String) -> Date? {
        formatter.date(from: key)
    }
}
