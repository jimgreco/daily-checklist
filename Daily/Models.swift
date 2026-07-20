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

struct RecurrenceRule: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case interval
        case monthlyDay
        case monthlyOrdinal

        var id: String { rawValue }
    }

    enum IntervalUnit: String, Codable, CaseIterable, Identifiable {
        case day
        case week

        var id: String { rawValue }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case interval
        case anchorDate
        case unit
        case dayOfMonth
        case ordinal
        case weekday
    }

    var kind: Kind
    var interval: Int
    var anchorDate: String
    var unit: IntervalUnit?
    var dayOfMonth: Int?
    var ordinal: Int?
    var weekday: Int?

    init(
        kind: Kind,
        interval: Int = 1,
        anchorDate: String = DateKey.string(from: .now),
        unit: IntervalUnit? = nil,
        dayOfMonth: Int? = nil,
        ordinal: Int? = nil,
        weekday: Int? = nil
    ) {
        self.kind = kind
        self.interval = Self.normalizedInterval(interval, for: kind, unit: unit)
        self.anchorDate = DateKey.date(from: anchorDate) == nil ? DateKey.string(from: .now) : anchorDate
        self.unit = kind == .interval ? (unit ?? .day) : nil
        self.dayOfMonth = kind == .monthlyDay ? min(max(1, dayOfMonth ?? 1), 31) : nil
        self.ordinal = kind == .monthlyOrdinal && Self.validOrdinals.contains(ordinal ?? 1) ? (ordinal ?? 1) : (kind == .monthlyOrdinal ? 1 : nil)
        self.weekday = kind == .monthlyOrdinal ? min(max(1, weekday ?? 1), 7) : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let unit = try container.decodeIfPresent(IntervalUnit.self, forKey: .unit)
        self.init(
            kind: kind,
            interval: try container.decodeIfPresent(Int.self, forKey: .interval) ?? 1,
            anchorDate: try container.decodeIfPresent(String.self, forKey: .anchorDate) ?? DateKey.string(from: .now),
            unit: unit,
            dayOfMonth: try container.decodeIfPresent(Int.self, forKey: .dayOfMonth),
            ordinal: try container.decodeIfPresent(Int.self, forKey: .ordinal),
            weekday: try container.decodeIfPresent(Int.self, forKey: .weekday)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(interval, forKey: .interval)
        try container.encode(anchorDate, forKey: .anchorDate)
        try container.encodeIfPresent(unit, forKey: .unit)
        try container.encodeIfPresent(dayOfMonth, forKey: .dayOfMonth)
        try container.encodeIfPresent(ordinal, forKey: .ordinal)
        try container.encodeIfPresent(weekday, forKey: .weekday)
    }

    static func every(_ interval: Int, unit: IntervalUnit, anchoredOn date: Date = .now) -> RecurrenceRule {
        RecurrenceRule(
            kind: .interval,
            interval: interval,
            anchorDate: DateKey.string(from: date),
            unit: unit
        )
    }

    static func monthly(
        every interval: Int = 1,
        dayOfMonth: Int,
        anchoredOn date: Date = .now
    ) -> RecurrenceRule {
        RecurrenceRule(
            kind: .monthlyDay,
            interval: interval,
            anchorDate: DateKey.string(from: date),
            dayOfMonth: dayOfMonth
        )
    }

    static func monthly(
        every interval: Int = 1,
        ordinal: Int,
        weekday: Int,
        anchoredOn date: Date = .now
    ) -> RecurrenceRule {
        RecurrenceRule(
            kind: .monthlyOrdinal,
            interval: interval,
            anchorDate: DateKey.string(from: date),
            ordinal: ordinal,
            weekday: weekday
        )
    }

    func isScheduled(on date: Date, calendar: Calendar = .current) -> Bool {
        let calendar = Self.gregorianCalendar(matching: calendar)
        let day = calendar.startOfDay(for: date)
        guard let anchor = DateKey.date(from: anchorDate, calendar: calendar), day >= anchor else { return false }

        switch kind {
        case .interval:
            let days = calendar.dateComponents([.day], from: anchor, to: day).day ?? -1
            let multiplier = unit == .week ? 7 : 1
            return days >= 0 && days.isMultiple(of: max(1, interval * multiplier))

        case .monthlyDay, .monthlyOrdinal:
            let anchorParts = calendar.dateComponents([.year, .month], from: anchor)
            let dayParts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let anchorYear = anchorParts.year,
                  let anchorMonth = anchorParts.month,
                  let year = dayParts.year,
                  let month = dayParts.month,
                  let dayNumber = dayParts.day else { return false }
            let elapsedMonths = (year - anchorYear) * 12 + month - anchorMonth
            guard elapsedMonths >= 0, elapsedMonths.isMultiple(of: max(1, interval)) else { return false }
            guard let daysInMonth = calendar.range(of: .day, in: .month, for: day)?.count else { return false }

            if kind == .monthlyDay {
                return dayNumber == min(dayOfMonth ?? 1, daysInMonth)
            }

            guard let weekday, let ordinal else { return false }
            let expectedDay: Int?
            if ordinal == -1 {
                var lastComponents = DateComponents()
                lastComponents.calendar = calendar
                lastComponents.timeZone = calendar.timeZone
                lastComponents.year = year
                lastComponents.month = month
                lastComponents.day = daysInMonth
                guard let lastDate = calendar.date(from: lastComponents) else { return false }
                let lastWeekday = calendar.component(.weekday, from: lastDate)
                expectedDay = daysInMonth - (lastWeekday - weekday + 7) % 7
            } else {
                var firstComponents = DateComponents()
                firstComponents.calendar = calendar
                firstComponents.timeZone = calendar.timeZone
                firstComponents.year = year
                firstComponents.month = month
                firstComponents.day = 1
                guard let firstDate = calendar.date(from: firstComponents) else { return false }
                let firstWeekday = calendar.component(.weekday, from: firstDate)
                let candidate = 1 + (weekday - firstWeekday + 7) % 7 + (ordinal - 1) * 7
                expectedDay = candidate <= daysInMonth ? candidate : nil
            }
            return expectedDay == dayNumber
        }
    }

    var summary: String {
        switch kind {
        case .interval:
            let unitName = unit == .week ? "week" : "day"
            if interval == 1 {
                return unit == .week ? "Every week" : "Every day"
            }
            return "Every \(interval) \(unitName)s"
        case .monthlyDay:
            let cadence = interval == 1 ? "Monthly" : "Every \(interval) months"
            let day = dayOfMonth ?? 1
            return day >= 29
                ? "\(cadence) on day \(day) (last day in shorter months)"
                : "\(cadence) on day \(day)"
        case .monthlyOrdinal:
            let cadence = interval == 1 ? "monthly" : "every \(interval) months"
            let ordinalName = Self.ordinalNames[ordinal ?? 1] ?? "First"
            let weekdayName = Self.weekdayNames[min(max(1, weekday ?? 1), 7) - 1]
            return "\(ordinalName) \(weekdayName) \(cadence)"
        }
    }

    var normalized: RecurrenceRule {
        RecurrenceRule(
            kind: kind,
            interval: interval,
            anchorDate: anchorDate,
            unit: unit,
            dayOfMonth: dayOfMonth,
            ordinal: ordinal,
            weekday: weekday
        )
    }

    static let validOrdinals: Set<Int> = [-1, 1, 2, 3, 4]
    static let ordinalNames: [Int: String] = [-1: "Last", 1: "First", 2: "Second", 3: "Third", 4: "Fourth"]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private static func normalizedInterval(_ value: Int, for kind: Kind, unit: IntervalUnit?) -> Int {
        let maximum = kind == .interval ? (unit == .week ? 52 : 365) : 24
        return min(max(1, value), maximum)
    }

    private static func gregorianCalendar(matching source: Calendar) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = source.timeZone
        return calendar
    }
}

enum MissedOccurrenceBehavior: String, Codable, CaseIterable, Identifiable {
    case markMissed
    case keepUntilDone

    var id: String { rawValue }
}

struct ChecklistOccurrence: Codable, Hashable {
    enum Outcome: String, Codable {
        case open
        case done
        case skipped
        case missed
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case completionCount
        case resolvedDate
        case hiddenUntil
        case scheduleRevision
        case scheduledDate
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case originalScheduledDate
    }

    var outcome: Outcome
    var completionCount: Int
    var resolvedDate: String?
    var hiddenUntil: String?
    var scheduleRevision: Int
    var scheduledDate: String

    init(
        outcome: Outcome = .open,
        completionCount: Int = 0,
        resolvedDate: String? = nil,
        hiddenUntil: String? = nil,
        scheduleRevision: Int = 0,
        scheduledDate: String = ""
    ) {
        self.outcome = outcome
        self.completionCount = Self.normalizedCompletionCount(completionCount)
        self.resolvedDate = resolvedDate
        self.hiddenUntil = hiddenUntil
        self.scheduleRevision = Self.normalizedScheduleRevision(scheduleRevision)
        self.scheduledDate = scheduledDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try container.decodeIfPresent(Outcome.self, forKey: .outcome) ?? .open
        completionCount = Self.normalizedCompletionCount(
            try container.decodeIfPresent(Int.self, forKey: .completionCount) ?? 0
        )
        resolvedDate = try container.decodeIfPresent(String.self, forKey: .resolvedDate)
        hiddenUntil = try container.decodeIfPresent(String.self, forKey: .hiddenUntil)
        scheduleRevision = Self.normalizedScheduleRevision(
            try container.decodeIfPresent(Int.self, forKey: .scheduleRevision) ?? 0
        )
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        scheduledDate = try container.decodeIfPresent(String.self, forKey: .scheduledDate)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .originalScheduledDate)
            ?? ""
    }

    private static func normalizedCompletionCount(_ count: Int) -> Int {
        min(max(0, count), 99)
    }

    private static func normalizedScheduleRevision(_ revision: Int) -> Int {
        min(max(0, revision), 1_000_000)
    }
}

enum ChecklistOccurrenceIdentifier {
    struct Parsed: Equatable {
        var itemID: UUID
        var scheduleRevision: Int?
        var scheduledDateKey: String

        var isLegacy: Bool { scheduleRevision == nil }
    }

    static func string(itemID: UUID, scheduleRevision: Int, scheduledDateKey: String) -> String {
        "\(itemID.uuidString.lowercased()):\(min(max(0, scheduleRevision), 1_000_000)):\(scheduledDateKey)"
    }

    /// The two-part form remains available for notification payloads created by older clients.
    static func string(itemID: UUID, scheduledDateKey: String) -> String {
        "\(itemID.uuidString.lowercased()):\(scheduledDateKey)"
    }

    static func parse(_ identifier: String) -> Parsed? {
        let parts = identifier.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let itemID = UUID(uuidString: String(parts[0])) else {
            return nil
        }

        let revision: Int?
        let datePart: Substring
        if parts.count == 3 {
            guard let parsedRevision = Int(parts[1]), parsedRevision >= 0 else { return nil }
            revision = parsedRevision
            datePart = parts[2]
        } else {
            revision = nil
            datePart = parts[1]
        }

        let dateKey = String(datePart)
        guard DateKey.date(from: dateKey) != nil else { return nil }
        return Parsed(itemID: itemID, scheduleRevision: revision, scheduledDateKey: dateKey)
    }

    static func scheduledDateKey(from identifier: String, itemID: UUID) -> String? {
        guard let parsed = parse(identifier), parsed.itemID == itemID else { return nil }
        return parsed.scheduledDateKey
    }

    static func scheduleRevision(from identifier: String, itemID: UUID) -> Int? {
        guard let parsed = parse(identifier), parsed.itemID == itemID else { return nil }
        return parsed.scheduleRevision
    }
}

struct NotificationGroupFilter: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case all
        case include
        case exclude

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .include: "Only"
            case .exclude: "Except"
            }
        }
    }

    var mode: Mode
    var groupIDs: Set<UUID>

    static let all = NotificationGroupFilter(mode: .all)

    init(mode: Mode = .all, groupIDs: Set<UUID> = []) {
        self.mode = mode
        self.groupIDs = mode == .all ? [] : groupIDs
    }

    func normalized(availableGroupIDs: Set<UUID>? = nil) -> NotificationGroupFilter {
        let selected = availableGroupIDs.map { groupIDs.intersection($0) } ?? groupIDs
        return NotificationGroupFilter(mode: mode, groupIDs: selected)
    }

    func includes(item: ChecklistItem) -> Bool {
        switch mode {
        case .all:
            return true
        case .include:
            guard let groupID = item.groupID else { return false }
            return groupIDs.contains(groupID)
        case .exclude:
            guard let groupID = item.groupID else { return true }
            return !groupIDs.contains(groupID)
        }
    }
}

struct ReminderFollowUpPolicy: Codable, Equatable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case delayMinutes
        case maximumCount
    }

    static let standard = ReminderFollowUpPolicy(delayMinutes: 60, maximumCount: 2)

    var delayMinutes: Int
    var maximumCount: Int

    init(delayMinutes: Int = 60, maximumCount: Int = 2) {
        self.delayMinutes = min(max(5, delayMinutes), 720)
        self.maximumCount = min(max(1, maximumCount), 5)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            delayMinutes: try container.decodeIfPresent(Int.self, forKey: .delayMinutes) ?? 60,
            maximumCount: try container.decodeIfPresent(Int.self, forKey: .maximumCount) ?? 2
        )
    }
}

struct NotificationQuietHours: Codable, Equatable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case startMinutes
        case endMinutes
    }

    static let standard = NotificationQuietHours(startMinutes: 22 * 60, endMinutes: 7 * 60)

    var startMinutes: Int
    var endMinutes: Int

    init(startMinutes: Int = 22 * 60, endMinutes: Int = 7 * 60) {
        self.startMinutes = min(max(0, startMinutes), 1439)
        self.endMinutes = min(max(0, endMinutes), 1439)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startMinutes: try container.decodeIfPresent(Int.self, forKey: .startMinutes) ?? 22 * 60,
            endMinutes: try container.decodeIfPresent(Int.self, forKey: .endMinutes) ?? 7 * 60
        )
    }

    func contains(minutes: Int) -> Bool {
        guard startMinutes != endMinutes else { return false }
        let value = min(max(0, minutes), 1439)
        if startMinutes < endMinutes {
            return value >= startMinutes && value < endMinutes
        }
        return value >= startMinutes || value < endMinutes
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        contains(minutes: calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
    }

    func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        guard startMinutes != endMinutes else { return nil }
        return nextBoundary(after: date, minutes: startMinutes, calendar: calendar)
    }

    func nextEnd(after date: Date, calendar: Calendar = .current) -> Date? {
        guard startMinutes != endMinutes else { return nil }
        return nextBoundary(after: date, minutes: endMinutes, calendar: calendar)
    }

    func nextAllowedDate(atOrAfter date: Date, calendar: Calendar = .current) -> Date {
        guard contains(date, calendar: calendar) else { return date }
        return nextEnd(after: date.addingTimeInterval(-1), calendar: calendar) ?? date
    }

    private func nextBoundary(after date: Date, minutes: Int, calendar: Calendar) -> Date? {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: minutes / 60, minute: minutes % 60),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

struct PauseWindow: Codable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case startDate
        case endDate
    }

    var startDate: String
    var endDate: String?

    init(startDate: String, endDate: String? = nil) {
        self.startDate = startDate
        self.endDate = endDate
    }

    func contains(_ date: Date) -> Bool {
        contains(DateKey.string(from: date))
    }

    func contains(_ key: String) -> Bool {
        guard key >= startDate else { return false }
        guard let endDate else { return true }
        return key <= endDate
    }

    static func normalized(_ windows: [PauseWindow]) -> [PauseWindow] {
        var merged: [PauseWindow] = []
        for window in windows
            .filter({ DateKey.date(from: $0.startDate) != nil && ($0.endDate == nil || DateKey.date(from: $0.endDate ?? "") != nil) })
            .filter({ $0.endDate == nil || $0.startDate <= ($0.endDate ?? "") })
            .sorted(by: { $0.startDate < $1.startDate }) {
            guard var last = merged.popLast() else {
                merged.append(window)
                continue
            }
            guard let lastEnd = last.endDate else {
                merged.append(last)
                continue
            }
            if window.startDate <= lastEnd {
                if let endDate = window.endDate {
                    last.endDate = max(lastEnd, endDate)
                } else {
                    last.endDate = nil
                }
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(window)
            }
        }
        return merged
    }

    static func clearing(_ windows: [PauseWindow], on date: Date, calendar: Calendar = .current) -> [PauseWindow] {
        let key = DateKey.string(from: date)
        let previousKey = calendar
            .date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))
            .map(DateKey.string(from:))
        let nextKey = calendar
            .date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            .map(DateKey.string(from:))

        return normalized(windows.flatMap { window -> [PauseWindow] in
            guard window.contains(key) else { return [window] }
            var result: [PauseWindow] = []
            if window.startDate < key, let previousKey {
                result.append(PauseWindow(startDate: window.startDate, endDate: previousKey))
            }
            if let nextKey {
                if let endDate = window.endDate {
                    if key < endDate {
                        result.append(PauseWindow(startDate: nextKey, endDate: endDate))
                    }
                } else {
                    result.append(PauseWindow(startDate: nextKey))
                }
            }
            return result
        })
    }
}

struct ChecklistGroup: Identifiable, Codable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder
        case isCollapsed
        case pauseWindows
    }

    var id: UUID
    var name: String
    var sortOrder: Double
    var isCollapsed: Bool
    var pauseWindows: [PauseWindow]

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Double = 0,
        isCollapsed: Bool = false,
        pauseWindows: [PauseWindow] = []
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.isCollapsed = isCollapsed
        self.pauseWindows = PauseWindow.normalized(pauseWindows)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        pauseWindows = PauseWindow.normalized(try container.decodeIfPresent([PauseWindow].self, forKey: .pauseWindows) ?? [])
    }

    func isPaused(on date: Date) -> Bool {
        pauseWindows.contains { $0.contains(date) }
    }

    mutating func pause(from startDate: Date, until endDate: Date) {
        let startKey = DateKey.string(from: startDate)
        let endKey = DateKey.string(from: endDate)
        guard startKey <= endKey else { return }
        pauseWindows = PauseWindow.normalized(pauseWindows + [PauseWindow(startDate: startKey, endDate: endKey)])
    }

    mutating func resume(on date: Date = .now, calendar: Calendar = .current) {
        let key = DateKey.string(from: date)
        let previousKey = calendar
            .date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))
            .map(DateKey.string(from:))
        pauseWindows = PauseWindow.normalized(pauseWindows.compactMap { window in
            guard window.contains(key) else { return window }
            guard window.startDate < key, let previousKey else { return nil }
            var closed = window
            closed.endDate = previousKey
            return closed
        })
    }

    mutating func clearPause(on date: Date, calendar: Calendar = .current) {
        pauseWindows = PauseWindow.clearing(pauseWindows, on: date, calendar: calendar)
    }
}

struct ChecklistItem: Identifiable, Codable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case notes
        case schedule
        case customWeekdays
        case recurrence
        case reminderMinutes
        case followUpPolicy
        case quantity
        case completedDates
        case completionCounts
        case skippedDates
        case openDates
        case createdAt
        case startDate
        case endedAt
        case groupID
        case sortOrder
        case pauseWindows
        case scheduleRevision
        case missedBehavior
        case carryoverStartDate
        case carryoverResolvedThroughDate
        case occurrences
    }

    var id: UUID
    var title: String
    var notes: String
    var schedule: ScheduleKind
    var customWeekdays: Set<Int>
    var recurrence: RecurrenceRule?
    var reminderMinutes: Int?
    var followUpPolicy: ReminderFollowUpPolicy?
    var quantity: Int
    var completedDates: Set<String>
    var completionCounts: [String: Int]
    var skippedDates: Set<String>
    var openDates: Set<String>
    var createdAt: Date
    var startDate: Date?
    var endedAt: Date?
    var groupID: UUID?
    var sortOrder: Double?
    var pauseWindows: [PauseWindow]
    var scheduleRevision: Int
    var missedBehavior: MissedOccurrenceBehavior
    var carryoverStartDate: String?
    var carryoverResolvedThroughDate: String?
    var occurrences: [String: ChecklistOccurrence]

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        schedule: ScheduleKind = .everyDay,
        customWeekdays: Set<Int> = [],
        recurrence: RecurrenceRule? = nil,
        reminderMinutes: Int? = nil,
        followUpPolicy: ReminderFollowUpPolicy? = nil,
        quantity: Int = 1,
        completedDates: Set<String> = [],
        completionCounts: [String: Int] = [:],
        skippedDates: Set<String> = [],
        openDates: Set<String> = [],
        createdAt: Date = .now,
        startDate: Date? = nil,
        endedAt: Date? = nil,
        groupID: UUID? = nil,
        sortOrder: Double? = nil,
        pauseWindows: [PauseWindow] = [],
        scheduleRevision: Int = 0,
        missedBehavior: MissedOccurrenceBehavior = .markMissed,
        carryoverStartDate: String? = nil,
        carryoverResolvedThroughDate: String? = nil,
        occurrences: [String: ChecklistOccurrence] = [:]
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.schedule = schedule
        self.customWeekdays = customWeekdays
        self.recurrence = recurrence
        self.reminderMinutes = reminderMinutes
        self.followUpPolicy = followUpPolicy
        self.quantity = Self.normalizedQuantity(quantity)
        self.completedDates = completedDates
        self.completionCounts = Self.normalizedCompletionCounts(completionCounts)
        self.skippedDates = skippedDates
        self.openDates = openDates
        self.createdAt = createdAt
        self.startDate = startDate
        self.endedAt = endedAt
        self.groupID = groupID
        self.sortOrder = sortOrder
        self.pauseWindows = PauseWindow.normalized(pauseWindows)
        self.scheduleRevision = min(max(0, scheduleRevision), 1_000_000)
        self.missedBehavior = missedBehavior
        self.carryoverStartDate = carryoverStartDate
        self.carryoverResolvedThroughDate = carryoverResolvedThroughDate
        self.occurrences = Self.migratedOccurrences(occurrences, itemID: id)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        schedule = try container.decodeIfPresent(ScheduleKind.self, forKey: .schedule) ?? .everyDay
        customWeekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .customWeekdays) ?? []
        recurrence = try container.decodeIfPresent(RecurrenceRule.self, forKey: .recurrence)
        reminderMinutes = try container.decodeIfPresent(Int.self, forKey: .reminderMinutes)
        followUpPolicy = try container.decodeIfPresent(ReminderFollowUpPolicy.self, forKey: .followUpPolicy)
        quantity = Self.normalizedQuantity(try container.decodeIfPresent(Int.self, forKey: .quantity) ?? 1)
        completedDates = try container.decodeIfPresent(Set<String>.self, forKey: .completedDates) ?? []
        completionCounts = Self.normalizedCompletionCounts(
            try container.decodeIfPresent([String: Int].self, forKey: .completionCounts) ?? [:]
        )
        skippedDates = try container.decodeIfPresent(Set<String>.self, forKey: .skippedDates) ?? []
        openDates = try container.decodeIfPresent(Set<String>.self, forKey: .openDates) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder)
        pauseWindows = PauseWindow.normalized(try container.decodeIfPresent([PauseWindow].self, forKey: .pauseWindows) ?? [])
        scheduleRevision = min(max(0, try container.decodeIfPresent(Int.self, forKey: .scheduleRevision) ?? 0), 1_000_000)
        missedBehavior = try container.decodeIfPresent(MissedOccurrenceBehavior.self, forKey: .missedBehavior) ?? .markMissed
        carryoverStartDate = try container.decodeIfPresent(String.self, forKey: .carryoverStartDate)
        carryoverResolvedThroughDate = try container.decodeIfPresent(String.self, forKey: .carryoverResolvedThroughDate)
        occurrences = Self.migratedOccurrences(
            try container.decodeIfPresent([String: ChecklistOccurrence].self, forKey: .occurrences) ?? [:],
            itemID: id
        )
    }

    func occurrenceID(scheduledDate: String, scheduleRevision: Int? = nil) -> String {
        ChecklistOccurrenceIdentifier.string(
            itemID: id,
            scheduleRevision: min(max(0, scheduleRevision ?? self.scheduleRevision), 1_000_000),
            scheduledDateKey: scheduledDate
        )
    }

    func occurrence(
        scheduledDate: String,
        scheduleRevision: Int? = nil
    ) -> ChecklistOccurrence? {
        let revision = min(max(0, scheduleRevision ?? self.scheduleRevision), 1_000_000)
        let identifier = occurrenceID(
            scheduledDate: scheduledDate,
            scheduleRevision: revision
        )
        if let occurrence = occurrences[identifier] {
            return occurrence
        }

        // Revision zero is the only unambiguous interpretation of legacy date-only keys.
        guard revision == 0 else { return nil }
        return occurrences[scheduledDate]
            ?? occurrences[ChecklistOccurrenceIdentifier.string(itemID: id, scheduledDateKey: scheduledDate)]
    }

    func latestOccurrence(scheduledDate: String) -> ChecklistOccurrence? {
        occurrences.values
            .filter { $0.scheduledDate == scheduledDate }
            .max {
                $0.scheduleRevision < $1.scheduleRevision
            }
    }

    @discardableResult
    mutating func setOccurrence(
        _ occurrence: ChecklistOccurrence,
        scheduledDate: String,
        scheduleRevision: Int? = nil
    ) -> String {
        let revision = min(max(0, scheduleRevision ?? self.scheduleRevision), 1_000_000)
        let identifier = occurrenceID(
            scheduledDate: scheduledDate,
            scheduleRevision: revision
        )
        var identifiedOccurrence = occurrence
        identifiedOccurrence.scheduleRevision = revision
        identifiedOccurrence.scheduledDate = scheduledDate
        occurrences[identifier] = identifiedOccurrence

        if revision == 0 {
            occurrences.removeValue(forKey: scheduledDate)
            occurrences.removeValue(
                forKey: ChecklistOccurrenceIdentifier.string(
                    itemID: id,
                    scheduledDateKey: scheduledDate
                )
            )
        }
        return identifier
    }

    @discardableResult
    mutating func removeOccurrence(
        scheduledDate: String,
        scheduleRevision: Int? = nil
    ) -> ChecklistOccurrence? {
        let revision = min(max(0, scheduleRevision ?? self.scheduleRevision), 1_000_000)
        let identifier = occurrenceID(
            scheduledDate: scheduledDate,
            scheduleRevision: revision
        )
        let removed = occurrences.removeValue(forKey: identifier)
        guard revision == 0 else { return removed }
        let removedDateKey = occurrences.removeValue(forKey: scheduledDate)
        let removedLegacyIdentifier = occurrences.removeValue(
            forKey: ChecklistOccurrenceIdentifier.string(
                itemID: id,
                scheduledDateKey: scheduledDate
            )
        )
        return removed ?? removedDateKey ?? removedLegacyIdentifier
    }

    func isActive(on date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        let firstDay = calendar.startOfDay(for: startDate ?? createdAt)
        guard day >= firstDay else { return false }
        guard let endedAt else { return true }
        return day < calendar.startOfDay(for: endedAt)
    }

    func isScheduled(on date: Date, calendar: Calendar = .current) -> Bool {
        guard isActive(on: date, calendar: calendar) else { return false }
        if let recurrence {
            return recurrence.isScheduled(on: date, calendar: calendar)
        }
        let weekday = calendar.component(.weekday, from: date)
        switch schedule {
        case .everyDay: return true
        case .weekdays: return (2...6).contains(weekday)
        case .weekends: return weekday == 1 || weekday == 7
        case .custom: return customWeekdays.contains(weekday)
        }
    }

    func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        isScheduled(on: date, calendar: calendar) && !isPaused(on: date)
    }

    func isComplete(on date: Date) -> Bool {
        completionCount(on: date) >= quantity
    }

    func completionCount(on date: Date) -> Int {
        let key = DateKey.string(from: date)
        if let count = completionCounts[key] {
            return min(max(0, count), quantity)
        }
        return completedDates.contains(key) ? quantity : 0
    }

    mutating func setCompletionCount(_ count: Int, forKey key: String) {
        let clamped = min(max(0, count), quantity)
        if clamped > 0 {
            completionCounts[key] = clamped
        } else {
            completionCounts.removeValue(forKey: key)
        }
        if clamped >= quantity {
            completedDates.insert(key)
        } else {
            completedDates.remove(key)
        }
    }

    func isSkipped(on date: Date) -> Bool {
        skippedDates.contains(DateKey.string(from: date))
    }

    func isExplicitlyOpen(on date: Date) -> Bool {
        openDates.contains(DateKey.string(from: date))
    }

    func isPaused(on date: Date) -> Bool {
        pauseWindows.contains { $0.contains(date) }
    }

    func hasRecordedState(on date: Date) -> Bool {
        completionCount(on: date) > 0 || isSkipped(on: date) || isExplicitlyOpen(on: date)
    }

    func isTracked(on date: Date, calendar: Calendar = .current) -> Bool {
        occurs(on: date, calendar: calendar) || hasRecordedState(on: date) || isPaused(on: date)
    }

    func firstTrackedDate(calendar: Calendar = .current) -> Date {
        let firstActiveDate = calendar.startOfDay(for: startDate ?? createdAt)
        let pausedDates = pauseWindows.compactMap { DateKey.date(from: $0.startDate) }
        let recordedDates = (completedDates.union(Set(completionCounts.keys)).union(skippedDates).union(openDates))
            .compactMap(DateKey.date(from:))
            .map { calendar.startOfDay(for: $0) } + pausedDates.map { calendar.startOfDay(for: $0) }
        guard let firstRecordedDate = recordedDates.min() else { return firstActiveDate }
        return min(firstActiveDate, firstRecordedDate)
    }

    func historyState(on date: Date, calendar: Calendar = .current) -> ChecklistHistoryState {
        let day = calendar.startOfDay(for: date)
        if let occurrence = latestOccurrence(scheduledDate: DateKey.string(from: day)) {
            switch occurrence.outcome {
            case .done: return .done
            case .skipped: return .skipped
            case .missed: return .missed
            case .open: return .open
            }
        }
        if isComplete(on: day) { return .done }
        if isSkipped(on: day) { return .skipped }
        if isExplicitlyOpen(on: day) { return .open }
        if isPaused(on: day) { return .paused }
        if isScheduled(on: day, calendar: calendar) {
            return day < calendar.startOfDay(for: .now) ? .missed : .open
        }
        return .off
    }

    mutating func pause(from startDate: Date, until endDate: Date) {
        let startKey = DateKey.string(from: startDate)
        let endKey = DateKey.string(from: endDate)
        guard startKey <= endKey else { return }
        pauseWindows = PauseWindow.normalized(pauseWindows + [PauseWindow(startDate: startKey, endDate: endKey)])
    }

    mutating func resume(on date: Date = .now, calendar: Calendar = .current) {
        let key = DateKey.string(from: date)
        let previousKey = calendar
            .date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))
            .map(DateKey.string(from:))
        pauseWindows = PauseWindow.normalized(pauseWindows.compactMap { window in
            guard window.contains(key) else { return window }
            guard window.startDate < key, let previousKey else { return nil }
            var closed = window
            closed.endDate = previousKey
            return closed
        })
    }

    mutating func clearPause(on date: Date, calendar: Calendar = .current) {
        pauseWindows = PauseWindow.clearing(pauseWindows, on: date, calendar: calendar)
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
                if isPaused(on: cursor) {
                    guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                        break
                    }
                    cursor = previousDay
                    continue
                }
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
                if isPaused(on: cursor) {
                    guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                        break
                    }
                    cursor = previousDay
                    continue
                }
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
        if let recurrence { return recurrence.summary }
        guard schedule == .custom else { return schedule.title }
        return (1...7)
            .filter(customWeekdays.contains)
            .map { WeekdayAbbreviation.twoLetter[$0 - 1] }
            .joined(separator: " · ")
    }

    func nextScheduledDates(
        startingAt date: Date = .now,
        count: Int = 5,
        calendar: Calendar = .current
    ) -> [Date] {
        guard count > 0 else { return [] }
        var cursor = max(
            calendar.startOfDay(for: date),
            calendar.startOfDay(for: startDate ?? createdAt)
        )
        var dates: [Date] = []
        var inspectedDays = 0
        while dates.count < count, inspectedDays < 20_000 {
            if let endedAt, cursor >= calendar.startOfDay(for: endedAt) { break }
            if occurs(on: cursor, calendar: calendar) {
                dates.append(cursor)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            inspectedDays += 1
        }
        return dates
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
            wasSourceCompletionCount: completionCounts[sourceKey] ?? (completedDates.contains(sourceKey) ? quantity : 0),
            wasSourceSkipped: skippedDates.contains(sourceKey),
            wasSourceOpen: openDates.contains(sourceKey),
            wasTargetCompleted: completedDates.contains(targetKey),
            wasTargetCompletionCount: completionCounts[targetKey] ?? (completedDates.contains(targetKey) ? quantity : 0),
            wasTargetSkipped: skippedDates.contains(targetKey),
            wasTargetOpen: openDates.contains(targetKey)
        )

        completedDates.remove(sourceKey)
        completionCounts.removeValue(forKey: sourceKey)
        skippedDates.insert(sourceKey)
        openDates.remove(sourceKey)
        completedDates.remove(targetKey)
        completionCounts.removeValue(forKey: targetKey)
        skippedDates.remove(targetKey)
        openDates.insert(targetKey)
        return change
    }

    private static func migratedOccurrences(
        _ rawOccurrences: [String: ChecklistOccurrence],
        itemID: UUID
    ) -> [String: ChecklistOccurrence] {
        var migrated: [String: ChecklistOccurrence] = [:]

        // Canonical entries win if a payload contains both canonical and legacy keys.
        for key in rawOccurrences.keys.sorted() {
            guard let occurrence = rawOccurrences[key],
                  let parsed = ChecklistOccurrenceIdentifier.parse(key),
                  parsed.itemID == itemID,
                  let revision = parsed.scheduleRevision else {
                continue
            }
            let identifier = ChecklistOccurrenceIdentifier.string(
                itemID: itemID,
                scheduleRevision: revision,
                scheduledDateKey: parsed.scheduledDateKey
            )
            var identifiedOccurrence = occurrence
            identifiedOccurrence.scheduleRevision = revision
            identifiedOccurrence.scheduledDate = parsed.scheduledDateKey
            migrated[identifier] = identifiedOccurrence
        }

        for key in rawOccurrences.keys.sorted() {
            guard var occurrence = rawOccurrences[key] else { continue }
            if let parsed = ChecklistOccurrenceIdentifier.parse(key),
               parsed.itemID == itemID,
               parsed.scheduleRevision != nil {
                continue
            }

            let scheduledDate: String
            if DateKey.date(from: key) != nil {
                scheduledDate = key
            } else if let parsed = ChecklistOccurrenceIdentifier.parse(key),
                      parsed.itemID == itemID,
                      parsed.isLegacy {
                scheduledDate = parsed.scheduledDateKey
            } else if DateKey.date(from: occurrence.scheduledDate) != nil {
                scheduledDate = occurrence.scheduledDate
            } else {
                migrated[key] = occurrence
                continue
            }

            let revision = min(max(0, occurrence.scheduleRevision), 1_000_000)
            let identifier = ChecklistOccurrenceIdentifier.string(
                itemID: itemID,
                scheduleRevision: revision,
                scheduledDateKey: scheduledDate
            )
            occurrence.scheduleRevision = revision
            occurrence.scheduledDate = scheduledDate
            if migrated[identifier] == nil {
                migrated[identifier] = occurrence
            }
        }
        return migrated
    }

    private static func normalizedQuantity(_ value: Int) -> Int {
        min(max(1, value), 99)
    }

    private static func normalizedCompletionCounts(_ counts: [String: Int]) -> [String: Int] {
        counts.filter { DateKey.date(from: $0.key) != nil && $0.value > 0 }
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
    var wasSourceCompletionCount: Int
    var wasSourceSkipped: Bool
    var wasSourceOpen: Bool
    var wasTargetCompleted: Bool
    var wasTargetCompletionCount: Int
    var wasTargetSkipped: Bool
    var wasTargetOpen: Bool
}

struct LocalEnvelope: Codable {
    var items: [ChecklistItem]
    var groups: [ChecklistGroup]?
    var eveningReminderMinutes: Int?
    var notificationGroupFilter: NotificationGroupFilter?
    var notificationQuietHours: NotificationQuietHours?
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
        case recurrence
        case reminderMinutes
        case followUpPolicy
        case quantity
        case skippedDates
        case openDates
        case createdAt
        case startDate
        case endedAt
        case groupID
        case sortOrder
        case pauseWindows
        case scheduleRevision
        case missedBehavior
        case carryoverStartDate
        case carryoverResolvedThroughDate
        case occurrences
    }

    var title: String
    var notes: String
    var schedule: ScheduleKind
    var customWeekdays: Set<Int>
    var recurrence: RecurrenceRule?
    var reminderMinutes: Int?
    var followUpPolicy: ReminderFollowUpPolicy?
    var quantity: Int
    var skippedDates: Set<String>
    var openDates: Set<String>
    var createdAt: Date
    var startDate: Date?
    var endedAt: Date?
    var groupID: UUID?
    var sortOrder: Double?
    var pauseWindows: [PauseWindow]
    var scheduleRevision: Int
    var missedBehavior: MissedOccurrenceBehavior
    var carryoverStartDate: String?
    var carryoverResolvedThroughDate: String?
    var occurrences: [String: ChecklistOccurrence]

    init(
        title: String,
        notes: String,
        schedule: ScheduleKind,
        customWeekdays: Set<Int>,
        recurrence: RecurrenceRule? = nil,
        reminderMinutes: Int?,
        followUpPolicy: ReminderFollowUpPolicy? = nil,
        quantity: Int,
        skippedDates: Set<String>,
        openDates: Set<String>,
        createdAt: Date,
        startDate: Date?,
        endedAt: Date?,
        groupID: UUID?,
        sortOrder: Double?,
        pauseWindows: [PauseWindow],
        scheduleRevision: Int = 0,
        missedBehavior: MissedOccurrenceBehavior = .markMissed,
        carryoverStartDate: String? = nil,
        carryoverResolvedThroughDate: String? = nil,
        occurrences: [String: ChecklistOccurrence] = [:]
    ) {
        self.title = title
        self.notes = notes
        self.schedule = schedule
        self.customWeekdays = customWeekdays
        self.recurrence = recurrence
        self.reminderMinutes = reminderMinutes
        self.followUpPolicy = followUpPolicy
        self.quantity = min(max(1, quantity), 99)
        self.skippedDates = skippedDates
        self.openDates = openDates
        self.createdAt = createdAt
        self.startDate = startDate
        self.endedAt = endedAt
        self.groupID = groupID
        self.sortOrder = sortOrder
        self.pauseWindows = PauseWindow.normalized(pauseWindows)
        self.scheduleRevision = min(max(0, scheduleRevision), 1_000_000)
        self.missedBehavior = missedBehavior
        self.carryoverStartDate = carryoverStartDate
        self.carryoverResolvedThroughDate = carryoverResolvedThroughDate
        self.occurrences = occurrences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        schedule = try container.decodeIfPresent(ScheduleKind.self, forKey: .schedule) ?? .everyDay
        customWeekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .customWeekdays) ?? []
        recurrence = try container.decodeIfPresent(RecurrenceRule.self, forKey: .recurrence)
        reminderMinutes = try container.decodeIfPresent(Int.self, forKey: .reminderMinutes)
        followUpPolicy = try container.decodeIfPresent(ReminderFollowUpPolicy.self, forKey: .followUpPolicy)
        quantity = min(max(1, try container.decodeIfPresent(Int.self, forKey: .quantity) ?? 1), 99)
        skippedDates = try container.decodeIfPresent(Set<String>.self, forKey: .skippedDates) ?? []
        openDates = try container.decodeIfPresent(Set<String>.self, forKey: .openDates) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder)
        pauseWindows = PauseWindow.normalized(try container.decodeIfPresent([PauseWindow].self, forKey: .pauseWindows) ?? [])
        scheduleRevision = min(max(0, try container.decodeIfPresent(Int.self, forKey: .scheduleRevision) ?? 0), 1_000_000)
        missedBehavior = try container.decodeIfPresent(MissedOccurrenceBehavior.self, forKey: .missedBehavior) ?? .markMissed
        carryoverStartDate = try container.decodeIfPresent(String.self, forKey: .carryoverStartDate)
        carryoverResolvedThroughDate = try container.decodeIfPresent(String.self, forKey: .carryoverResolvedThroughDate)
        occurrences = try container.decodeIfPresent([String: ChecklistOccurrence].self, forKey: .occurrences) ?? [:]
    }
}

struct GroupPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case sortOrder
        case isCollapsed
        case pauseWindows
    }

    var name: String
    var sortOrder: Double
    var isCollapsed: Bool
    var pauseWindows: [PauseWindow]

    init(name: String, sortOrder: Double, isCollapsed: Bool, pauseWindows: [PauseWindow]) {
        self.name = name
        self.sortOrder = sortOrder
        self.isCollapsed = isCollapsed
        self.pauseWindows = PauseWindow.normalized(pauseWindows)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        pauseWindows = PauseWindow.normalized(try container.decodeIfPresent([PauseWindow].self, forKey: .pauseWindows) ?? [])
    }
}

struct SyncMutation: Identifiable, Codable {
    enum Kind: String, Codable {
        case upsert
        case delete
        case completion
        case eveningReminder
        case notificationGroupFilter
        case notificationQuietHours
        case groupUpsert
        case groupDelete
        case occurrence
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
    var completionCount: Int?
    var occurrenceDate: String?
    var occurrenceID: String?
    var occurrence: ChecklistOccurrence?
    var eveningReminderMinutes: Int?
    var notificationGroupFilter: NotificationGroupFilter?
    var notificationQuietHours: NotificationQuietHours?

    static func upsert(item: ChecklistItem, changedFields: Set<String>) -> SyncMutation {
        return SyncMutation(
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
                recurrence: item.recurrence,
                reminderMinutes: item.reminderMinutes,
                followUpPolicy: item.followUpPolicy,
                quantity: item.quantity,
                skippedDates: item.skippedDates,
                openDates: item.openDates,
                createdAt: item.createdAt,
                startDate: item.startDate,
                endedAt: item.endedAt,
                groupID: item.groupID,
                sortOrder: item.sortOrder,
                pauseWindows: item.pauseWindows,
                scheduleRevision: item.scheduleRevision,
                missedBehavior: item.missedBehavior,
                carryoverStartDate: item.carryoverStartDate,
                carryoverResolvedThroughDate: item.carryoverResolvedThroughDate,
                occurrences: item.occurrences
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
            group: GroupPayload(
                name: group.name,
                sortOrder: group.sortOrder,
                isCollapsed: group.isCollapsed,
                pauseWindows: group.pauseWindows
            )
        )
    }

    static func delete(groupID: UUID) -> SyncMutation {
        SyncMutation(id: UUID(), groupID: groupID, kind: .groupDelete, stamp: SyncStamp.now)
    }

    static func delete(itemID: UUID) -> SyncMutation {
        SyncMutation(id: UUID(), itemID: itemID, kind: .delete, stamp: SyncStamp.now)
    }

    static func completion(itemID: UUID, date: String, completed: Bool, count: Int? = nil) -> SyncMutation {
        SyncMutation(
            id: UUID(),
            itemID: itemID,
            kind: .completion,
            stamp: SyncStamp.now,
            completionDate: date,
            completed: completed,
            completionCount: count
        )
    }

    static func occurrence(
        itemID: UUID,
        occurrenceDate: String,
        occurrence: ChecklistOccurrence
    ) -> SyncMutation {
        let revision = min(max(0, occurrence.scheduleRevision), 1_000_000)
        var identifiedOccurrence = occurrence
        identifiedOccurrence.scheduleRevision = revision
        identifiedOccurrence.scheduledDate = occurrenceDate
        return .occurrence(
            itemID: itemID,
            occurrenceID: ChecklistOccurrenceIdentifier.string(
                itemID: itemID,
                scheduleRevision: revision,
                scheduledDateKey: occurrenceDate
            ),
            occurrence: identifiedOccurrence
        )
    }

    static func occurrence(
        itemID: UUID,
        occurrenceID: String,
        occurrence: ChecklistOccurrence
    ) -> SyncMutation {
        var identifiedOccurrence = occurrence
        if let parsed = ChecklistOccurrenceIdentifier.parse(occurrenceID),
           parsed.itemID == itemID,
           let revision = parsed.scheduleRevision {
            identifiedOccurrence.scheduleRevision = revision
            identifiedOccurrence.scheduledDate = parsed.scheduledDateKey
        }
        return SyncMutation(
            id: UUID(),
            itemID: itemID,
            kind: .occurrence,
            stamp: SyncStamp.now,
            occurrenceDate: identifiedOccurrence.scheduledDate,
            occurrenceID: occurrenceID,
            occurrence: identifiedOccurrence
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

    static func notificationFilter(_ filter: NotificationGroupFilter) -> SyncMutation {
        SyncMutation(
            id: UUID(),
            kind: .notificationGroupFilter,
            stamp: SyncStamp.now,
            notificationGroupFilter: filter
        )
    }

    static func quietHours(_ quietHours: NotificationQuietHours?) -> SyncMutation {
        SyncMutation(
            id: UUID(),
            kind: .notificationQuietHours,
            stamp: SyncStamp.now,
            notificationQuietHours: quietHours
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
    var notificationGroupFilter: NotificationGroupFilter?
    var notificationQuietHours: NotificationQuietHours?
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
    case paused = "Paused"
    case off = "Off"

    var id: String { rawValue }
}

enum DateKey {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from key: String) -> Date? {
        formatter.date(from: key)
    }

    static func date(from key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }
}
