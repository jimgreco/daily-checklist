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

    func consecutiveMissedDays(asOf date: Date, calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: .now)
        var cursor = min(calendar.startOfDay(for: date), today)
        let firstEligibleDate = calendar.startOfDay(for: startDate ?? createdAt)
        var missedDays = 0

        // The current day is still in progress, so it cannot be considered missed yet.
        if cursor >= today {
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                return 0
            }
            cursor = previousDay
        }

        while cursor >= firstEligibleDate {
            if occurs(on: cursor, calendar: calendar) {
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
        let firstEligibleDate = calendar.startOfDay(for: startDate ?? createdAt)
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
            if occurs(on: cursor, calendar: calendar) {
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

    var scheduleSummary: String {
        guard schedule == .custom else { return schedule.title }
        return (1...7)
            .filter(customWeekdays.contains)
            .map { WeekdayAbbreviation.twoLetter[$0 - 1] }
            .joined(separator: " · ")
    }
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
