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
        case tasks
        case accountID
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
    /// The open tasks the widget can act on, in display order. Older snapshots omit it.
    var tasks: [RitualWidgetTask]
    /// The local account the snapshot was built for, so widget taps are never applied to another account.
    var accountID: String?

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
        hasChecklist: Bool,
        tasks: [RitualWidgetTask] = [],
        accountID: String? = nil
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
        self.tasks = tasks
        self.accountID = accountID
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
        tasks = try container.decodeIfPresent([RitualWidgetTask].self, forKey: .tasks) ?? []
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
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

    /// Overlays taps recorded by the widget that the app has not applied yet, so the
    /// widget stays correct even if the app rewrites the snapshot before draining them.
    func applying(_ actions: [RitualWidgetAction]) -> RitualWidgetSnapshot {
        let relevant = actions.filter { $0.dateKey == dateKey && $0.accountID == accountID }
        guard !relevant.isEmpty else { return self }
        var result = self
        var updatedTasks: [RitualWidgetTask] = []
        for var task in tasks {
            let target = relevant
                .filter { $0.taskID == task.id }
                .map(\.targetCount)
                .max() ?? task.completionCount
            task.completionCount = min(task.quantity, max(task.completionCount, target))
            if task.completionCount >= task.quantity {
                result.remainingCount = max(0, result.remainingCount - 1)
                if task.isCarryover {
                    // A resolved carryover leaves the day's list entirely, as it does in the app.
                    result.carryoverCount = max(0, result.carryoverCount - 1)
                    result.scheduledCount = max(0, result.scheduledCount - 1)
                } else {
                    result.completedCount += 1
                }
            } else {
                updatedTasks.append(task)
            }
        }
        result.tasks = updatedTasks
        return result
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

struct RitualWidgetTask: Codable, Equatable, Identifiable {
    var itemID: UUID
    var title: String
    var quantity: Int
    var completionCount: Int
    /// The carryover occurrence a tap resolves; nil for an ordinary scheduled task.
    var occurrenceID: String?
    var isCarryover: Bool

    var id: String { occurrenceID ?? itemID.uuidString }
    var hasQuantity: Bool { quantity > 1 }
}

enum RitualWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.jimgreco.dailychecklist"
    static let kind = "RitualCueTodayWidget"
    static let appURL = URL(string: "ritualcue://today")

    private static let snapshotKey = "ritualWidgetSnapshot.v1"
    private static let snapshotsKey = "ritualWidgetSnapshots.v2"
    private static let lastSaveKey = "ritualWidgetLastSave.v1"
    private static let lastReadKey = "ritualWidgetLastRead.v1"

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
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return false }
        guard let data = try? JSONEncoder().encode(snapshots) else {
            defaults.set("failed \(Date().ISO8601Format())", forKey: lastSaveKey)
            return false
        }
        defaults.set(data, forKey: snapshotsKey)
        defaults.removeObject(forKey: snapshotKey)
        let today = snapshots.first { $0.isCurrentDay() }
        defaults.set(
            "ok \(Date().ISO8601Format()) bytes=\(data.count) days=\(snapshots.count) todayTasks=\(today.map { String($0.tasks.count) } ?? "none")",
            forKey: lastSaveKey
        )
        return true
    }

    /// Called by the widget so diagnostics can show what it actually rendered.
    static func recordRead(_ snapshot: RitualWidgetSnapshot, now: Date = .now) {
        UserDefaults(suiteName: appGroupIdentifier)?.set(
            "\(now.ISO8601Format()) date=\(snapshot.dateKey) remaining=\(snapshot.remainingCount) tasks=\(snapshot.tasks.count) hasChecklist=\(snapshot.hasChecklist)",
            forKey: lastReadKey
        )
    }

    /// Counts only, never task titles, for the support diagnostics text.
    static func diagnosticLines(now: Date = .now) -> [String] {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return ["Widget Storage: App Group unavailable"]
        }
        var lines: [String] = []
        if let data = defaults.data(forKey: snapshotsKey) {
            do {
                let snapshots = try JSONDecoder().decode([RitualWidgetSnapshot].self, from: data)
                if let today = snapshots.first(where: { $0.isCurrentDay(now: now) }) {
                    lines.append("Widget Stored Today: remaining=\(today.remainingCount) tasks=\(today.tasks.count) updated=\(today.updatedAt.ISO8601Format()) hasAccount=\(today.accountID != nil)")
                } else {
                    lines.append("Widget Stored Today: none of \(snapshots.count) snapshots match \(RitualWidgetDateKey.string(from: now))")
                }
            } catch {
                lines.append("Widget Stored Today: decode failed (\(data.count) bytes): \(error)")
            }
        } else {
            lines.append("Widget Stored Today: no data")
        }
        lines.append("Widget Last Save: \(defaults.string(forKey: lastSaveKey) ?? "never")")
        lines.append("Widget Last Read: \(defaults.string(forKey: lastReadKey) ?? "never")")
        lines.append("Widget Pending Taps: \(RitualWidgetActionInbox.load().count)")
        return lines
    }
}

enum RitualWidgetDateKey {
    static func string(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
