import Foundation

struct RitualWidgetSnapshot: Codable, Equatable {
    var remainingCount: Int
    var scheduledCount: Int
    var completedCount: Int
    var skippedCount: Int
    var reminderMinutes: [Int]
    var nextReminderMinutes: Int?
    var dateKey: String
    var updatedAt: Date
    var hasChecklist: Bool

    static func empty(for date: Date = .now) -> RitualWidgetSnapshot {
        RitualWidgetSnapshot(
            remainingCount: 0,
            scheduledCount: 0,
            completedCount: 0,
            skippedCount: 0,
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
