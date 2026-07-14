import Foundation

struct RitualWidgetSnapshot: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case remainingCount
        case scheduledCount
        case completedCount
        case skippedCount
        case carryoverCount
        case reminderMinutes
        case nextReminderMinutes
        case dateKey
        case updatedAt
        case hasChecklist
    }

    var remainingCount: Int
    var scheduledCount: Int
    var completedCount: Int
    var skippedCount: Int
    var carryoverCount: Int
    var reminderMinutes: [Int]
    var nextReminderMinutes: Int?
    var dateKey: String
    var updatedAt: Date
    var hasChecklist: Bool

    init(
        remainingCount: Int,
        scheduledCount: Int,
        completedCount: Int,
        skippedCount: Int,
        carryoverCount: Int = 0,
        reminderMinutes: [Int],
        nextReminderMinutes: Int?,
        dateKey: String,
        updatedAt: Date,
        hasChecklist: Bool
    ) {
        self.remainingCount = remainingCount
        self.scheduledCount = scheduledCount
        self.completedCount = completedCount
        self.skippedCount = skippedCount
        self.carryoverCount = max(0, carryoverCount)
        self.reminderMinutes = reminderMinutes
        self.nextReminderMinutes = nextReminderMinutes
        self.dateKey = dateKey
        self.updatedAt = updatedAt
        self.hasChecklist = hasChecklist
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remainingCount = try container.decode(Int.self, forKey: .remainingCount)
        scheduledCount = try container.decode(Int.self, forKey: .scheduledCount)
        completedCount = try container.decode(Int.self, forKey: .completedCount)
        skippedCount = try container.decode(Int.self, forKey: .skippedCount)
        carryoverCount = max(0, try container.decodeIfPresent(Int.self, forKey: .carryoverCount) ?? 0)
        reminderMinutes = try container.decode([Int].self, forKey: .reminderMinutes)
        nextReminderMinutes = try container.decodeIfPresent(Int.self, forKey: .nextReminderMinutes)
        dateKey = try container.decode(String.self, forKey: .dateKey)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        hasChecklist = try container.decode(Bool.self, forKey: .hasChecklist)
    }

    static func empty(for date: Date = .now) -> RitualWidgetSnapshot {
        RitualWidgetSnapshot(
            remainingCount: 0,
            scheduledCount: 0,
            completedCount: 0,
            skippedCount: 0,
            carryoverCount: 0,
            reminderMinutes: [],
            nextReminderMinutes: nil,
            dateKey: RitualWidgetDateKey.string(from: date),
            updatedAt: date,
            hasChecklist: false
        )
    }

    func isCurrentDay(now: Date = .now) -> Bool {
        dateKey == RitualWidgetDateKey.string(from: now)
    }

    func upcomingReminderMinutes(now: Date = .now) -> Int? {
        guard isCurrentDay(now: now) else { return nil }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let currentMinutes = ((components.hour ?? 0) * 60) + (components.minute ?? 0)
        let upcoming = reminderMinutes.filter { $0 > currentMinutes }.min()
        if let upcoming { return upcoming }
        guard let nextReminderMinutes, nextReminderMinutes > currentMinutes else { return nil }
        return nextReminderMinutes
    }
}

enum RitualWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.jimgreco.dailychecklist"
    static let kind = "RitualCueTodayWidget"
    static let appURL = URL(string: "ritualcue://today")

    private static let snapshotKey = "ritualWidgetSnapshot.v1"
    private static let snapshotsKey = "ritualWidgetSnapshots.v2"

    static func load(now: Date = .now) -> RitualWidgetSnapshot {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return .empty(for: now)
        }
        if let data = defaults.data(forKey: snapshotsKey),
           let snapshots = try? JSONDecoder().decode([RitualWidgetSnapshot].self, from: data),
           let snapshot = snapshots.first(where: { $0.isCurrentDay(now: now) }) {
            return snapshot
        }
        if let data = defaults.data(forKey: snapshotKey),
           let snapshot = try? JSONDecoder().decode(RitualWidgetSnapshot.self, from: data),
           snapshot.isCurrentDay(now: now) {
            return snapshot
        }
        return .empty(for: now)
    }

    static func save(_ snapshot: RitualWidgetSnapshot) -> Bool {
        save([snapshot])
    }

    @discardableResult
    static func save(_ snapshots: [RitualWidgetSnapshot]) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = try? JSONEncoder().encode(snapshots)
        else {
            return false
        }
        defaults.set(data, forKey: snapshotsKey)
        defaults.removeObject(forKey: snapshotKey)
        return true
    }
}

enum RitualWidgetDateKey {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
