import Foundation
import WidgetKit

enum ChecklistSort: String, CaseIterable, Identifiable {
    case manual
    case name
    case reminderTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .reminderTime: "Time"
        }
    }

    var icon: String {
        switch self {
        case .manual: "line.3.horizontal"
        case .name: "textformat.abc"
        case .reminderTime: "clock"
        }
    }
}

enum ChecklistScope: String, CaseIterable, Identifiable {
    case today
    case all
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .all: "All"
        case .archive: "Archive"
        }
    }
}

struct RoutineTemplate: Identifiable {
    let id: String
    let title: String
    let groupName: String
    let items: [String]

    static let builtIns: [RoutineTemplate] = [
        RoutineTemplate(
            id: "morning",
            title: "Morning",
            groupName: "Morning Routine",
            items: ["Medication", "Vitamins", "Review today"]
        ),
        RoutineTemplate(
            id: "evening",
            title: "Evening",
            groupName: "Evening Routine",
            items: ["Tidy up", "Prepare tomorrow", "Skincare"]
        ),
        RoutineTemplate(
            id: "pet-care",
            title: "Pet care",
            groupName: "Pet Care",
            items: ["Food", "Fresh water", "Medication"]
        ),
        RoutineTemplate(
            id: "household",
            title: "Household",
            groupName: "Household",
            items: ["Dishes", "Trash", "Quick reset"]
        )
    ]
}

struct RoutineInsightHighlight: Equatable {
    let title: String
    let count: Int
}

struct RoutineInsightSummary: Equatable {
    let completedCheckIns: Int
    let expectedCheckIns: Int
    let lateCompletedCheckIns: Int
    let trendPercentagePoints: Int?
    let currentStreak: RoutineInsightHighlight?
    let missedWeekday: String?
    let missedWeekdayCount: Int
    let longestDelay: RoutineInsightHighlight?

    var hasEnoughData: Bool { expectedCheckIns >= 3 }

    var completionPercentage: Int {
        guard expectedCheckIns > 0 else { return 0 }
        return Int((Double(completedCheckIns) / Double(expectedCheckIns) * 100).rounded())
    }
}

struct CarryoverOccurrence: Identifiable, Equatable {
    let id: String
    let scheduledDateKey: String
    let scheduleRevision: Int
    let state: ChecklistOccurrence?
}

struct CarryoverEntry: Identifiable, Equatable {
    var id: UUID { item.id }
    let item: ChecklistItem
    let occurrences: [CarryoverOccurrence]

    var scheduledDateKeys: [String] { occurrences.map(\.scheduledDateKey) }
    var oldestScheduledDateKey: String { scheduledDateKeys[0] }
    var latestScheduledDateKey: String { scheduledDateKeys[scheduledDateKeys.count - 1] }
    var latestOccurrenceID: String { occurrences[occurrences.count - 1].id }
    var latestScheduleRevision: Int { occurrences[occurrences.count - 1].scheduleRevision }
    var outstandingOccurrenceCount: Int { occurrences.count }
    var latestCompletionCount: Int {
        if let count = occurrences.last?.state?.completionCount {
            return min(max(0, count), item.quantity)
        }
        guard let date = DateKey.date(from: latestScheduledDateKey) else { return 0 }
        return item.completionCount(on: date)
    }
}

enum CarryoverResolver {
    static func entries(
        items: [ChecklistItem],
        groups: [ChecklistGroup],
        asOf date: Date = .now,
        includeHidden: Bool = false,
        calendar: Calendar = .current
    ) -> [CarryoverEntry] {
        let day = calendar.startOfDay(for: date)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return [] }
        let todayKey = DateKey.string(from: day)
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })

        func isPaused(_ item: ChecklistItem, on targetDate: Date) -> Bool {
            if item.isPaused(on: targetDate) { return true }
            guard let groupID = item.groupID else { return false }
            return groupsByID[groupID]?.isPaused(on: targetDate) == true
        }

        return items.compactMap { item -> CarryoverEntry? in
            guard item.missedBehavior == .keepUntilDone,
                  item.schedule != .everyDay,
                  let startKey = item.carryoverStartDate,
                  let rawStartDate = DateKey.date(from: startKey),
                  (includeHidden || !isPaused(item, on: day)) else { return nil }

            let firstActiveDate = calendar.startOfDay(for: item.startDate ?? item.createdAt)
            var cursor = max(calendar.startOfDay(for: rawStartDate), firstActiveDate)
            var unresolved: [String: CarryoverOccurrence] = [:]

            func addOccurrence(
                scheduledDateKey: String,
                revision: Int,
                state: ChecklistOccurrence?
            ) {
                let identifier = ChecklistOccurrenceIdentifier.string(
                    itemID: item.id,
                    scheduleRevision: revision,
                    scheduledDateKey: scheduledDateKey
                )
                unresolved[identifier] = CarryoverOccurrence(
                    id: identifier,
                    scheduledDateKey: scheduledDateKey,
                    scheduleRevision: revision,
                    state: state
                )
            }

            while cursor <= yesterday {
                let key = DateKey.string(from: cursor)
                let occurrence = item.occurrence(scheduledDate: key)
                let explicitlyReopened = occurrence?.outcome == .open && item.openDates.contains(key)
                let pastResolutionBoundary = item.carryoverResolvedThroughDate.map { key > $0 } ?? true
                if (pastResolutionBoundary || explicitlyReopened),
                   item.isScheduled(on: cursor, calendar: calendar),
                   !isPaused(item, on: cursor),
                   (occurrence?.completionCount ?? item.completionCount(on: cursor)) < item.quantity,
                   (occurrence != nil || !item.isSkipped(on: cursor)),
                   occurrence?.outcome != .done,
                   occurrence?.outcome != .skipped,
                   occurrence?.outcome != .missed {
                    addOccurrence(
                        scheduledDateKey: key,
                        revision: item.scheduleRevision,
                        state: occurrence
                    )
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }

            // Persisted open occurrences survive later schedule edits. A quantity
            // reduction can make previously partial progress complete, so do not
            // keep that occurrence open solely because its stored outcome is stale.
            var todayPersistedOccurrences: [CarryoverOccurrence] = []
            for (identifier, occurrence) in item.occurrences where occurrence.outcome == .open {
                let key = occurrence.scheduledDate
                let appliesAcrossScheduleEdit = occurrence.scheduleRevision < item.scheduleRevision
                let explicitlyReopened = item.openDates.contains(key)
                guard key <= todayKey,
                      (key >= startKey || appliesAcrossScheduleEdit || explicitlyReopened),
                      DateKey.date(from: key) != nil,
                      occurrence.completionCount < item.quantity else { continue }
                let reference = CarryoverOccurrence(
                    id: identifier,
                    scheduledDateKey: key,
                    scheduleRevision: occurrence.scheduleRevision,
                    state: occurrence
                )
                if key == todayKey {
                    todayPersistedOccurrences.append(reference)
                } else {
                    unresolved[identifier] = reference
                }
            }

            // When today's recurrence arrives while an older obligation is still
            // open, it belongs to the same row. The newest occurrence is the one a
            // real-world completion resolves; older dates remain recorded as missed.
            if !unresolved.isEmpty,
               item.isScheduled(on: day, calendar: calendar),
               !isPaused(item, on: day),
               (item.occurrence(scheduledDate: todayKey)?.completionCount
                    ?? item.completionCount(on: day)) < item.quantity,
               (item.occurrence(scheduledDate: todayKey) != nil || !item.isSkipped(on: day)),
               item.occurrence(scheduledDate: todayKey)?.outcome != .done,
               item.occurrence(scheduledDate: todayKey)?.outcome != .skipped,
               item.occurrence(scheduledDate: todayKey)?.outcome != .missed {
                addOccurrence(
                    scheduledDateKey: todayKey,
                    revision: item.scheduleRevision,
                    state: item.occurrence(scheduledDate: todayKey)
                )
            }
            if !unresolved.isEmpty {
                for reference in todayPersistedOccurrences {
                    unresolved[reference.id] = reference
                }
            }

            let sortedOccurrences = unresolved.values.sorted {
                if $0.scheduledDateKey != $1.scheduledDateKey {
                    return $0.scheduledDateKey < $1.scheduledDateKey
                }
                if $0.scheduleRevision != $1.scheduleRevision {
                    return $0.scheduleRevision < $1.scheduleRevision
                }
                return $0.id < $1.id
            }
            guard let latest = sortedOccurrences.last else { return nil }
            if !includeHidden,
               let hiddenUntil = latest.state?.hiddenUntil,
               hiddenUntil > todayKey {
                return nil
            }
            return CarryoverEntry(item: item, occurrences: sortedOccurrences)
        }
        .sorted {
            if $0.oldestScheduledDateKey != $1.oldestScheduledDateKey {
                return $0.oldestScheduledDateKey < $1.oldestScheduledDateKey
            }
            return $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
        }
    }
}

@MainActor
final class ChecklistStore: ObservableObject {
    @Published private(set) var items: [ChecklistItem] = []
    @Published private(set) var groups: [ChecklistGroup] = []
    @Published var showingToday = true
    @Published var scope: ChecklistScope = .today {
        didSet { showingToday = scope == .today }
    }
    @Published var selectedDate = Calendar.current.startOfDay(for: .now)
    @Published var eveningReminderMinutes: Int? = 20 * 60
    @Published var notificationGroupFilter: NotificationGroupFilter = .all
    @Published var notificationQuietHours: NotificationQuietHours? = nil
    @Published private(set) var notificationSchedulingStatus: NotificationSchedulingStatus = .unknown
    @Published private(set) var syncState = "Saved locally"
    @Published private(set) var hasLoaded = false
    @Published var sortMode: ChecklistSort {
        didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: "checklistSortMode") }
    }

    private let api = APIClient()
    private let notifications = NotificationManager()
    private var hasStarted = false
    private var syncTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private weak var authStore: AuthStore?
    private var activeAccountID: String = UserDefaults.standard.string(forKey: "activeAccountID") ?? "anonymous"

    init() {
        sortMode = ChecklistSort(
            rawValue: UserDefaults.standard.string(forKey: "checklistSortMode") ?? ""
        ) ?? .manual
    }
    private var pendingMutations: [SyncMutation] = []

    private var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: "deviceID") { return existing }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }

    var diagnosticDeviceID: String { deviceID }
    var pendingMutationCount: Int { pendingMutations.count }

    private var notificationFilterForScheduling: NotificationGroupFilter {
        notificationGroupFilter.normalized(availableGroupIDs: Set(groups.map(\.id)))
    }

    private var cacheURL: URL {
        cacheURL(for: activeAccountID)
    }

    private func cacheURL(for accountID: String) -> URL {
        URL.documentsDirectory.appending(path: "daily-checklist-\(accountID).json")
    }

    var visibleItems: [ChecklistItem] {
        let scoped: [ChecklistItem]
        switch scope {
        case .today:
            scoped = items.filter { item in
                let paused = isPaused(item, on: selectedDate)
                return isTracked(item, on: selectedDate) && (!paused || item.hasRecordedState(on: selectedDate))
            }
        case .all:
            scoped = items.filter { $0.isActive(on: selectedDate) || $0.hasRecordedState(on: selectedDate) || isPaused($0, on: selectedDate) }
        case .archive:
            scoped = items.filter { $0.endedAt != nil }
        }
        return scoped.sorted(by: sortPredicate)
    }

    var orderedGroups: [ChecklistGroup] {
        groups.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var todoItems: [ChecklistItem] {
        let groupedCarryoverIDs = isSelectedDateToday && scope == .today
            ? carryoverItemIDsIncludingHidden
            : []
        return visibleItems.filter {
            !groupedCarryoverIDs.contains($0.id)
                && !$0.isComplete(on: selectedDate)
                && !$0.isSkipped(on: selectedDate)
                && !isPaused($0, on: selectedDate)
        }
    }

    var completedItems: [ChecklistItem] {
        visibleItems.filter { $0.isComplete(on: selectedDate) }
    }

    var skippedItems: [ChecklistItem] {
        visibleItems.filter { $0.isSkipped(on: selectedDate) && !$0.isComplete(on: selectedDate) }
    }

    var carryoverEntries: [CarryoverEntry] {
        CarryoverResolver.entries(items: items, groups: groups)
    }

    var carryoverItemIDsIncludingHidden: Set<UUID> {
        Set(CarryoverResolver.entries(
            items: items,
            groups: groups,
            includeHidden: true
        ).map(\.item.id))
    }

    func unresolvedCarryoverEntry(for itemID: UUID) -> CarryoverEntry? {
        CarryoverResolver.entries(
            items: items,
            groups: groups,
            includeHidden: true
        ).first { $0.item.id == itemID }
    }

    func unresolvedCarryoverEntries(inGroup groupID: UUID) -> [CarryoverEntry] {
        CarryoverResolver.entries(
            items: items,
            groups: groups,
            includeHidden: true
        ).filter { $0.item.groupID == groupID }
    }

    var isSelectedDateToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    func canDeleteGroup(_ groupID: UUID) -> Bool {
        !items.contains { $0.groupID == groupID && $0.endedAt == nil }
    }

    func isGroupPaused(_ groupID: UUID, on date: Date? = nil) -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }) else { return false }
        return group.isPaused(on: date ?? selectedDate)
    }

    func isPaused(_ item: ChecklistItem, on date: Date? = nil) -> Bool {
        let targetDate = date ?? selectedDate
        if item.isPaused(on: targetDate) { return true }
        guard let groupID = item.groupID else { return false }
        return isGroupPaused(groupID, on: targetDate)
    }

    func isTracked(_ item: ChecklistItem, on date: Date? = nil) -> Bool {
        let targetDate = date ?? selectedDate
        if isPaused(item, on: targetDate) { return true }
        return item.occurs(on: targetDate) || item.hasRecordedState(on: targetDate)
    }

    func historyState(for item: ChecklistItem, on date: Date) -> ChecklistHistoryState {
        let day = Calendar.current.startOfDay(for: date)
        let key = DateKey.string(from: day)
        if let occurrence = Self.latestOccurrence(in: item, scheduledDateKey: key)?.occurrence {
            switch occurrence.outcome {
            case .done: return .done
            case .skipped: return .skipped
            case .missed: return .missed
            case .open: return .open
            }
        }
        if item.isComplete(on: day) { return .done }
        if item.isSkipped(on: day) { return .skipped }
        if item.isExplicitlyOpen(on: day) { return .open }
        if isPaused(item, on: day) { return .paused }
        if item.isScheduled(on: day) {
            return day < Calendar.current.startOfDay(for: .now) ? .missed : .open
        }
        return .off
    }

    func moveSelectedDate(by days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) else { return }
        selectedDate = Calendar.current.startOfDay(for: date)
    }

    func selectToday() {
        selectedDate = Calendar.current.startOfDay(for: .now)
        scope = .today
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        loadCache()
        hasLoaded = true
        persistWidgetSnapshot(reloadTimelines: true)
        let permission = await notifications.requestAuthorization()
        notificationSchedulingStatus.permission = permission
        notificationSchedulingStatus = await notifications.reschedule(
            items: items,
            groups: groups,
            eveningMinutes: eveningReminderMinutes,
            groupFilter: notificationFilterForScheduling,
            quietHours: notificationQuietHours
        )
    }

    func refreshNotificationSchedule() async {
        let status = await notifications.reschedule(
            items: items,
            groups: groups,
            eveningMinutes: eveningReminderMinutes,
            groupFilter: notificationFilterForScheduling,
            quietHours: notificationQuietHours
        )
        guard !Task.isCancelled else { return }
        notificationSchedulingStatus = status
    }

    func connect(to authStore: AuthStore) {
        self.authStore = authStore
    }

    func activateAuthenticatedAccount(_ userID: String) {
        guard activeAccountID != userID else { return }
        if activeAccountID == "anonymous" {
            if FileManager.default.fileExists(atPath: cacheURL(for: userID).path) {
                switchLocalAccount(to: userID)
                return
            }
            activeAccountID = userID
            UserDefaults.standard.set(userID, forKey: "activeAccountID")
            persistAndSchedule()
            clearAnonymousCache()
            return
        }
        switchLocalAccount(to: userID)
    }

    func activateAnonymousAccount() {
        switchLocalAccount(to: "anonymous")
    }

    func toggle(_ item: ChecklistItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let key = DateKey.string(from: selectedDate)
        let wasSkipped = items[index].skippedDates.contains(key)
        let wasOpen = items[index].openDates.contains(key)
        let currentCount = items[index].completionCount(on: selectedDate)
        if items[index].isComplete(on: selectedDate) {
            items[index].setCompletionCount(0, forKey: key)
            if !items[index].occurs(on: selectedDate) {
                items[index].openDates.insert(key)
            }
        } else {
            items[index].setCompletionCount(currentCount + 1, forKey: key)
            items[index].skippedDates.remove(key)
            items[index].openDates.remove(key)
        }
        pendingMutations.append(.completion(
            itemID: item.id,
            date: key,
            completed: items[index].isComplete(on: selectedDate),
            count: items[index].completionCount(on: selectedDate)
        ))
        queueDaySetMutationIfNeeded(for: items[index], wasSkipped: wasSkipped, wasOpen: wasOpen, key: key)
        queueOccurrenceState(for: index, key: key)
        persistAndSchedule()
    }

    func setSkipped(_ item: ChecklistItem, skipped: Bool, on date: Date? = nil) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let targetDate = date ?? selectedDate
        let key = DateKey.string(from: targetDate)
        let wasSkipped = items[index].skippedDates.contains(key)
        let wasOpen = items[index].openDates.contains(key)
        let wasCompletionCount = items[index].completionCount(on: targetDate)
        if skipped {
            items[index].skippedDates.insert(key)
            items[index].setCompletionCount(0, forKey: key)
            items[index].openDates.remove(key)
        } else {
            items[index].skippedDates.remove(key)
            if !items[index].occurs(on: targetDate) {
                items[index].openDates.insert(key)
            }
        }
        queueDaySetMutationIfNeeded(for: items[index], wasSkipped: wasSkipped, wasOpen: wasOpen, key: key)
        if skipped && wasCompletionCount > 0 {
            pendingMutations.append(.completion(itemID: items[index].id, date: key, completed: false, count: 0))
        }
        queueOccurrenceState(for: index, key: key)
        persistAndSchedule()
    }

    func complete(itemID: UUID, on date: Date) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let key = DateKey.string(from: date)
        let wasSkipped = items[index].skippedDates.contains(key)
        let wasOpen = items[index].openDates.contains(key)
        items[index].setCompletionCount(items[index].quantity, forKey: key)
        items[index].skippedDates.remove(key)
        items[index].openDates.remove(key)
        pendingMutations.append(.completion(itemID: itemID, date: key, completed: true, count: items[index].quantity))
        queueDaySetMutationIfNeeded(for: items[index], wasSkipped: wasSkipped, wasOpen: wasOpen, key: key)
        queueOccurrenceState(for: index, key: key)
        persistAndSchedule()
    }

    func skip(itemID: UUID, on date: Date) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        setSkipped(item, skipped: true, on: date)
    }

    func advanceCarryover(_ entry: CarryoverEntry) {
        resolveCarryover(entry, completedCount: min(entry.latestCompletionCount + 1, entry.item.quantity))
    }

    func completeCarryover(itemID: UUID, occurrenceDate: Date) {
        let key = DateKey.string(from: occurrenceDate)
        guard let entry = CarryoverResolver.entries(
            items: items,
            groups: groups,
            includeHidden: true
        ).first(where: {
            $0.item.id == itemID && $0.scheduledDateKeys.contains(key)
        }) else {
            complete(itemID: itemID, on: occurrenceDate)
            return
        }
        resolveCarryover(entry, completedCount: entry.item.quantity)
    }

    func skipCarryover(_ entry: CarryoverEntry) {
        skipCarryover(entry, targetOccurrenceID: nil)
    }

    func completeCarryover(
        itemID: UUID,
        occurrenceID: String,
        occurrenceDate: Date
    ) {
        guard let entry = CarryoverResolver.entries(
            items: items,
            groups: groups,
            includeHidden: true
        ).first(where: {
            $0.item.id == itemID && $0.occurrences.contains(where: { $0.id == occurrenceID })
        }) else {
            guard canActOnCurrentOccurrence(
                itemID: itemID,
                occurrenceID: occurrenceID,
                occurrenceDate: occurrenceDate
            ) else { return }
            complete(itemID: itemID, on: occurrenceDate)
            return
        }
        resolveCarryover(
            entry,
            targetOccurrenceID: occurrenceID,
            completedCount: entry.item.quantity
        )
    }

    func skipCarryover(
        itemID: UUID,
        occurrenceID: String,
        occurrenceDate: Date
    ) {
        guard let entry = CarryoverResolver.entries(
            items: items,
            groups: groups,
            includeHidden: true
        ).first(where: {
            $0.item.id == itemID && $0.occurrences.contains(where: { $0.id == occurrenceID })
        }) else {
            guard canActOnCurrentOccurrence(
                itemID: itemID,
                occurrenceID: occurrenceID,
                occurrenceDate: occurrenceDate
            ) else { return }
            skip(itemID: itemID, on: occurrenceDate)
            return
        }
        skipCarryover(entry, targetOccurrenceID: occurrenceID)
    }

    private func canActOnCurrentOccurrence(
        itemID: UUID,
        occurrenceID: String,
        occurrenceDate: Date
    ) -> Bool {
        guard let parsed = ChecklistOccurrenceIdentifier.parse(occurrenceID),
              parsed.itemID == itemID,
              parsed.scheduledDateKey == DateKey.string(from: occurrenceDate),
              let item = items.first(where: { $0.id == itemID }),
              (parsed.scheduleRevision ?? 0) == item.scheduleRevision,
              item.occurrence(
                scheduledDate: parsed.scheduledDateKey,
                scheduleRevision: item.scheduleRevision
              )?.outcome != .done,
              item.occurrence(
                scheduledDate: parsed.scheduledDateKey,
                scheduleRevision: item.scheduleRevision
              )?.outcome != .skipped,
              item.occurrence(
                scheduledDate: parsed.scheduledDateKey,
                scheduleRevision: item.scheduleRevision
              )?.outcome != .missed,
              !item.isComplete(on: occurrenceDate),
              !item.isSkipped(on: occurrenceDate),
              !isPaused(item, on: occurrenceDate),
              item.occurs(on: occurrenceDate) || item.isExplicitlyOpen(on: occurrenceDate) else {
            return false
        }
        return true
    }

    private func skipCarryover(
        _ entry: CarryoverEntry,
        targetOccurrenceID: String?
    ) {
        guard let index = items.firstIndex(where: { $0.id == entry.item.id }),
              !entry.occurrences.isEmpty else { return }
        let targetIndex = targetOccurrenceID.flatMap { identifier in
            entry.occurrences.firstIndex(where: { $0.id == identifier })
        } ?? (entry.occurrences.count - 1)
        let latest = entry.occurrences[targetIndex]
        let key = latest.scheduledDateKey
        preserveFollowingSameDateOccurrences(
            in: entry,
            after: targetIndex,
            itemIndex: index
        )
        let previousCount = latest.state?.completionCount ?? items[index].completionCounts[key] ?? 0
        let wasSkipped = items[index].skippedDates.contains(key)
        let wasOpen = items[index].openDates.contains(key)

        items[index].setCompletionCount(0, forKey: key)
        items[index].skippedDates.insert(key)
        items[index].openDates.remove(key)
        items[index].carryoverResolvedThroughDate = max(
            items[index].carryoverResolvedThroughDate ?? key,
            key
        )
        let occurrence = ChecklistOccurrence(
            outcome: .skipped,
            resolvedDate: DateKey.string(from: .now),
            scheduleRevision: latest.scheduleRevision,
            scheduledDate: key
        )
        items[index].setOccurrence(
            occurrence,
            scheduledDate: key,
            scheduleRevision: latest.scheduleRevision
        )

        // Schedule edits may have materialized older open records. Close those
        // internal records without adding them to skippedDates: they remain Missed
        // in history, but can no longer resurrect the grouped carryover.
        for older in entry.occurrences.prefix(targetIndex) {
            guard older.state?.outcome == .open || older.state == nil else { continue }
            let olderOccurrence = ChecklistOccurrence(
                outcome: .missed,
                completionCount: older.state?.completionCount ?? 0,
                resolvedDate: DateKey.string(from: .now),
                scheduleRevision: older.scheduleRevision,
                scheduledDate: older.scheduledDateKey
            )
            items[index].setOccurrence(
                olderOccurrence,
                scheduledDate: older.scheduledDateKey,
                scheduleRevision: older.scheduleRevision
            )
            pendingMutations.append(.occurrence(
                itemID: items[index].id,
                occurrenceID: older.id,
                occurrence: olderOccurrence
            ))
        }

        if previousCount > 0 {
            pendingMutations.append(.completion(itemID: items[index].id, date: key, completed: false, count: 0))
        }
        queueDaySetMutationIfNeeded(for: items[index], wasSkipped: wasSkipped, wasOpen: wasOpen, key: key)
        pendingMutations.append(.upsert(item: items[index], changedFields: ["carryoverResolvedThroughDate"]))
        pendingMutations.append(.occurrence(
            itemID: items[index].id,
            occurrenceID: latest.id,
            occurrence: occurrence
        ))
        persistAndSchedule()
    }

    func skipCarryover(itemID: UUID, occurrenceDate: Date) {
        let key = DateKey.string(from: occurrenceDate)
        guard let entry = CarryoverResolver.entries(
            items: items,
            groups: groups,
            includeHidden: true
        ).first(where: {
            $0.item.id == itemID && $0.scheduledDateKeys.contains(key)
        }) else {
            skip(itemID: itemID, on: occurrenceDate)
            return
        }
        skipCarryover(entry)
    }

    func deferCarryoverUntilTomorrow(_ entry: CarryoverEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.item.id }),
              let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)),
              let latest = entry.occurrences.last else { return }
        let key = latest.scheduledDateKey
        var occurrence = latest.state ?? ChecklistOccurrence(
            completionCount: entry.latestCompletionCount,
            scheduleRevision: latest.scheduleRevision,
            scheduledDate: key
        )
        occurrence.outcome = .open
        occurrence.resolvedDate = nil
        occurrence.hiddenUntil = DateKey.string(from: tomorrow)
        items[index].setOccurrence(
            occurrence,
            scheduledDate: key,
            scheduleRevision: latest.scheduleRevision
        )
        pendingMutations.append(.occurrence(
            itemID: items[index].id,
            occurrenceID: latest.id,
            occurrence: occurrence
        ))
        persistAndSchedule()
    }

    private func resolveCarryover(
        _ entry: CarryoverEntry,
        targetOccurrenceID: String? = nil,
        completedCount: Int
    ) {
        guard let index = items.firstIndex(where: { $0.id == entry.item.id }),
              !entry.occurrences.isEmpty else { return }
        let targetIndex = targetOccurrenceID.flatMap { identifier in
            entry.occurrences.firstIndex(where: { $0.id == identifier })
        } ?? (entry.occurrences.count - 1)
        let latest = entry.occurrences[targetIndex]
        let key = latest.scheduledDateKey
        preserveFollowingSameDateOccurrences(
            in: entry,
            after: targetIndex,
            itemIndex: index
        )
        let date = DateKey.date(from: key) ?? .now
        let wasSkipped = items[index].skippedDates.contains(key)
        let wasOpen = items[index].openDates.contains(key)
        let count = min(max(0, completedCount), items[index].quantity)
        let completed = count >= items[index].quantity

        items[index].setCompletionCount(count, forKey: key)
        items[index].skippedDates.remove(key)
        items[index].openDates.remove(key)
        var occurrence = ChecklistOccurrence(
            outcome: completed ? .done : .open,
            completionCount: count,
            resolvedDate: completed ? DateKey.string(from: .now) : nil,
            scheduleRevision: latest.scheduleRevision,
            scheduledDate: key
        )
        occurrence.hiddenUntil = nil
        items[index].setOccurrence(
            occurrence,
            scheduledDate: key,
            scheduleRevision: latest.scheduleRevision
        )
        if completed {
            items[index].carryoverResolvedThroughDate = max(
                items[index].carryoverResolvedThroughDate ?? key,
                key
            )
            for older in entry.occurrences.prefix(targetIndex) {
                guard older.state?.outcome == .open || older.state == nil else { continue }
                let olderOccurrence = ChecklistOccurrence(
                    outcome: .missed,
                    completionCount: older.state?.completionCount ?? 0,
                    resolvedDate: DateKey.string(from: .now),
                    scheduleRevision: older.scheduleRevision,
                    scheduledDate: older.scheduledDateKey
                )
                items[index].setOccurrence(
                    olderOccurrence,
                    scheduledDate: older.scheduledDateKey,
                    scheduleRevision: older.scheduleRevision
                )
                pendingMutations.append(.occurrence(
                    itemID: items[index].id,
                    occurrenceID: older.id,
                    occurrence: olderOccurrence
                ))
            }
        }

        pendingMutations.append(.completion(
            itemID: items[index].id,
            date: DateKey.string(from: date),
            completed: completed,
            count: count
        ))
        queueDaySetMutationIfNeeded(for: items[index], wasSkipped: wasSkipped, wasOpen: wasOpen, key: key)
        if completed {
            pendingMutations.append(.upsert(item: items[index], changedFields: ["carryoverResolvedThroughDate"]))
        }
        pendingMutations.append(.occurrence(
            itemID: items[index].id,
            occurrenceID: latest.id,
            occurrence: occurrence
        ))
        persistAndSchedule()
    }

    private func preserveFollowingSameDateOccurrences(
        in entry: CarryoverEntry,
        after targetIndex: Int,
        itemIndex: Int
    ) {
        guard entry.occurrences.indices.contains(targetIndex),
              items.indices.contains(itemIndex),
              targetIndex + 1 < entry.occurrences.count else { return }
        let targetDateKey = entry.occurrences[targetIndex].scheduledDateKey
        for reference in entry.occurrences[(targetIndex + 1)...]
            where reference.scheduledDateKey == targetDateKey && reference.state == nil {
            let occurrence = ChecklistOccurrence(
                completionCount: 0,
                scheduleRevision: reference.scheduleRevision,
                scheduledDate: reference.scheduledDateKey
            )
            items[itemIndex].setOccurrence(
                occurrence,
                scheduledDate: reference.scheduledDateKey,
                scheduleRevision: reference.scheduleRevision
            )
            pendingMutations.append(.occurrence(
                itemID: items[itemIndex].id,
                occurrenceID: reference.id,
                occurrence: occurrence
            ))
        }
    }

    func delay(_ item: ChecklistItem, from date: Date? = nil) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let change = try items[index].delay(from: date ?? selectedDate)
        queueDateMoveMutation(for: index, change: change)
        persistAndSchedule()
    }

    func bringForward(_ item: ChecklistItem, from date: Date? = nil) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let change = try items[index].bringForward(from: date ?? selectedDate)
        queueDateMoveMutation(for: index, change: change)
        persistAndSchedule()
    }

    private func queueDateMoveMutation(for index: Int, change: ChecklistDateMoveChange) {
        if change.wasSourceCompletionCount > 0 || !change.wasSourceSkipped {
            pendingMutations.append(.completion(itemID: items[index].id, date: change.sourceKey, completed: false, count: 0))
        }
        queueDaySetMutationIfNeeded(
            for: items[index],
            wasSkipped: change.wasSourceSkipped,
            wasOpen: change.wasSourceOpen,
            key: change.sourceKey
        )

        if change.wasTargetCompletionCount > 0 {
            pendingMutations.append(.completion(itemID: items[index].id, date: change.targetKey, completed: false, count: 0))
        }
        queueDaySetMutationIfNeeded(
            for: items[index],
            wasSkipped: change.wasTargetSkipped,
            wasOpen: change.wasTargetOpen,
            key: change.targetKey
        )
        queueOccurrenceState(for: index, key: change.sourceKey)
        queueOccurrenceState(for: index, key: change.targetKey)
    }

    func setHistoryState(_ state: ChecklistHistoryState, for itemID: UUID, on date: Date) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }

        let key = DateKey.string(from: date)
        let wasCompleted = items[index].completedDates.contains(key)
        let wasCompletionCount = items[index].completionCount(on: date)
        let wasSkipped = items[index].skippedDates.contains(key)
        let wasOpen = items[index].openDates.contains(key)
        let wasPauseWindows = items[index].pauseWindows
        let existingOccurrence = Self.latestOccurrence(in: items[index], scheduledDateKey: key)
        let targetRevision = existingOccurrence?.occurrence.scheduleRevision ?? items[index].scheduleRevision
        let wasOccurrence = existingOccurrence?.occurrence
        let wasResolvedThroughDate = items[index].carryoverResolvedThroughDate

        switch state {
        case .done:
            items[index].setCompletionCount(items[index].quantity, forKey: key)
            items[index].skippedDates.remove(key)
            items[index].openDates.remove(key)
            items[index].clearPause(on: date)
            if items[index].schedule != .everyDay {
                items[index].setOccurrence(ChecklistOccurrence(
                    outcome: .done,
                    completionCount: items[index].quantity,
                    resolvedDate: DateKey.string(from: .now),
                    scheduleRevision: targetRevision,
                    scheduledDate: key
                ), scheduledDate: key, scheduleRevision: targetRevision)
            }
        case .skipped:
            items[index].setCompletionCount(0, forKey: key)
            items[index].skippedDates.insert(key)
            items[index].openDates.remove(key)
            items[index].clearPause(on: date)
            if items[index].schedule != .everyDay {
                items[index].setOccurrence(ChecklistOccurrence(
                    outcome: .skipped,
                    resolvedDate: DateKey.string(from: .now),
                    scheduleRevision: targetRevision,
                    scheduledDate: key
                ), scheduledDate: key, scheduleRevision: targetRevision)
            }
        case .open:
            items[index].setCompletionCount(0, forKey: key)
            items[index].skippedDates.remove(key)
            items[index].openDates.insert(key)
            items[index].clearPause(on: date)
            if items[index].schedule != .everyDay {
                items[index].setOccurrence(
                    ChecklistOccurrence(
                        scheduleRevision: targetRevision,
                        scheduledDate: key
                    ),
                    scheduledDate: key,
                    scheduleRevision: targetRevision
                )
            }
        case .paused:
            items[index].setCompletionCount(0, forKey: key)
            items[index].skippedDates.remove(key)
            items[index].openDates.remove(key)
            items[index].pause(from: date, until: date)
        case .missed, .off:
            items[index].setCompletionCount(0, forKey: key)
            items[index].skippedDates.remove(key)
            items[index].openDates.remove(key)
            items[index].clearPause(on: date)
            if items[index].missedBehavior == .keepUntilDone {
                items[index].setOccurrence(ChecklistOccurrence(
                    outcome: .missed,
                    resolvedDate: DateKey.string(from: .now),
                    scheduleRevision: targetRevision,
                    scheduledDate: key
                ), scheduledDate: key, scheduleRevision: targetRevision)
                items[index].carryoverResolvedThroughDate = max(
                    items[index].carryoverResolvedThroughDate ?? key,
                    key
                )
            }
        }

        let isCompleted = items[index].completedDates.contains(key)
        let completionCount = items[index].completionCount(on: date)
        let isSkipped = items[index].skippedDates.contains(key)
        let isOpen = items[index].openDates.contains(key)
        let pauseChanged = items[index].pauseWindows != wasPauseWindows
        let updatedOccurrence = items[index].occurrence(
            scheduledDate: key,
            scheduleRevision: targetRevision
        )
        let occurrenceChanged = wasOccurrence != updatedOccurrence
        let resolutionBoundaryChanged = wasResolvedThroughDate != items[index].carryoverResolvedThroughDate
        guard wasCompleted != isCompleted || wasCompletionCount != completionCount || wasSkipped != isSkipped || wasOpen != isOpen || pauseChanged || occurrenceChanged || resolutionBoundaryChanged else { return }

        if wasCompleted != isCompleted || wasCompletionCount != completionCount || (!isCompleted && (isSkipped || wasSkipped)) {
            pendingMutations.append(.completion(itemID: itemID, date: key, completed: isCompleted, count: completionCount))
        }
        queueDaySetMutationIfNeeded(for: items[index], wasSkipped: wasSkipped, wasOpen: wasOpen, key: key)
        if pauseChanged {
            pendingMutations.append(.upsert(item: items[index], changedFields: ["pauseWindows"]))
        }
        if occurrenceChanged, let occurrence = updatedOccurrence {
            pendingMutations.append(.occurrence(
                itemID: itemID,
                occurrenceID: items[index].occurrenceID(
                    scheduledDate: key,
                    scheduleRevision: targetRevision
                ),
                occurrence: occurrence
            ))
        }
        if resolutionBoundaryChanged {
            pendingMutations.append(.upsert(item: items[index], changedFields: ["carryoverResolvedThroughDate"]))
        }

        persistAndSchedule()
    }

    func snooze(
        itemID: UUID,
        occurrenceDate: Date = .now,
        occurrenceID: String? = nil,
        isCarryover: Bool = false,
        preset: ReminderSnoozePreset = .oneHour
    ) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        if let occurrenceID {
            if isCarryover {
                guard CarryoverResolver.entries(
                    items: items,
                    groups: groups,
                    includeHidden: true
                ).contains(where: {
                    $0.item.id == itemID
                        && $0.occurrences.contains(where: { $0.id == occurrenceID })
                }) else { return }
            } else {
                guard canActOnCurrentOccurrence(
                    itemID: itemID,
                    occurrenceID: occurrenceID,
                    occurrenceDate: occurrenceDate
                ) else { return }
            }
        } else {
            guard item.isActive(on: occurrenceDate),
                  !item.isComplete(on: occurrenceDate),
                  !item.isSkipped(on: occurrenceDate),
                  !isPaused(item, on: occurrenceDate),
                  item.occurs(on: occurrenceDate) || item.isExplicitlyOpen(on: occurrenceDate) else { return }
        }
        Task {
            _ = await notifications.snooze(
                item: item,
                occurrenceDate: occurrenceDate,
                occurrenceID: occurrenceID,
                isCarryover: isCarryover,
                preset: preset,
                quietHours: notificationQuietHours
            )
        }
    }

    func completeAllForSelectedDate() {
        completeAll(itemIDs: Set(todoItems.map(\.id)))
    }

    func completeAll(itemIDs: Set<UUID>) {
        let key = DateKey.string(from: selectedDate)
        var completedItemIDs: [UUID] = []

        for index in items.indices {
            guard itemIDs.contains(items[index].id),
                  !items[index].completedDates.contains(key) else { continue }
            items[index].setCompletionCount(items[index].quantity, forKey: key)
            items[index].skippedDates.remove(key)
            items[index].openDates.remove(key)
            completedItemIDs.append(items[index].id)
        }

        guard !completedItemIDs.isEmpty else { return }
        pendingMutations.append(contentsOf: completedItemIDs.compactMap { itemID in
            guard let item = items.first(where: { $0.id == itemID }) else { return nil }
            return .completion(itemID: itemID, date: key, completed: true, count: item.quantity)
        })
        pendingMutations.append(contentsOf: items.filter { completedItemIDs.contains($0.id) }.map {
            .upsert(item: $0, changedFields: ["skippedDates", "openDates"])
        })
        for itemID in completedItemIDs {
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { continue }
            queueOccurrenceState(for: index, key: key)
        }
        persistAndSchedule()
    }

    func save(_ item: ChecklistItem) {
        var item = item
        if item.schedule == .everyDay {
            item.missedBehavior = .markMissed
        } else if item.missedBehavior == .keepUntilDone,
                  item.carryoverStartDate == nil {
            item.carryoverStartDate = DateKey.string(from: .now)
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let previous = items[index]
            if previous.missedBehavior == .markMissed,
               item.missedBehavior == .keepUntilDone {
                item.carryoverStartDate = DateKey.string(from: .now)
            }
            var occurrenceMutations: [SyncMutation] = []
            let scheduleChanged = previous.schedule != item.schedule
                || previous.customWeekdays != item.customWeekdays
                || previous.recurrence != item.recurrence
                || previous.startDate != item.startDate
                || previous.endedAt != item.endedAt
            let disablingCarryover = previous.missedBehavior == .keepUntilDone
                && item.missedBehavior != .keepUntilDone
            if (scheduleChanged || disablingCarryover),
               previous.missedBehavior == .keepUntilDone {
                let today = Calendar.current.startOfDay(for: .now)
                let todayKey = DateKey.string(from: today)
                var outstanding = CarryoverResolver.entries(
                    items: [previous],
                    groups: groups,
                    includeHidden: true
                ).first?.occurrences ?? []

                // A schedule revision is forward-only, but today's old-revision
                // occurrence has already arrived and must keep its identity.
                if previous.isScheduled(on: today),
                   !previous.isComplete(on: today),
                   !previous.isSkipped(on: today) {
                    let identifier = previous.occurrenceID(scheduledDate: todayKey)
                    if !outstanding.contains(where: { $0.id == identifier }) {
                        outstanding.append(CarryoverOccurrence(
                            id: identifier,
                            scheduledDateKey: todayKey,
                            scheduleRevision: previous.scheduleRevision,
                            state: previous.occurrence(scheduledDate: todayKey)
                        ))
                    }
                }

                for reference in outstanding {
                    let existingOccurrence = item.occurrences[reference.id] ?? reference.state
                    let count = reference.state?.completionCount
                        ?? DateKey.date(from: reference.scheduledDateKey).map(previous.completionCount(on:))
                        ?? 0
                    var occurrence = existingOccurrence ?? ChecklistOccurrence(
                        completionCount: count,
                        scheduleRevision: reference.scheduleRevision,
                        scheduledDate: reference.scheduledDateKey
                    )
                    let shouldTerminalize = disablingCarryover
                        && occurrence.outcome == .open
                    if shouldTerminalize {
                        occurrence.outcome = .missed
                        occurrence.resolvedDate = DateKey.string(from: .now)
                        occurrence.hiddenUntil = nil
                        item.openDates.remove(reference.scheduledDateKey)
                    }
                    guard existingOccurrence == nil || shouldTerminalize else { continue }
                    item.setOccurrence(
                        occurrence,
                        scheduledDate: reference.scheduledDateKey,
                        scheduleRevision: reference.scheduleRevision
                    )
                    occurrenceMutations.append(.occurrence(
                        itemID: item.id,
                        occurrenceID: reference.id,
                        occurrence: occurrence
                    ))
                }
            }
            if scheduleChanged {
                item.scheduleRevision = min(previous.scheduleRevision + 1, 1_000_000)
                if item.missedBehavior == .keepUntilDone {
                    item.carryoverStartDate = DateKey.string(from: .now)
                }
            }
            if items[index].groupID != item.groupID {
                item.sortOrder = nextItemSortOrder(in: item.groupID)
            }
            let changedFields = Self.changedFields(from: previous, to: item)
            items[index] = item
            if !changedFields.isEmpty {
                pendingMutations.append(.upsert(item: item, changedFields: changedFields))
            }
            pendingMutations.append(contentsOf: occurrenceMutations)
        } else {
            item.sortOrder = nextItemSortOrder(in: item.groupID)
            items.append(item)
            pendingMutations.append(.upsert(item: item, changedFields: Self.allFields))
        }
        persistAndSchedule()
    }

    @discardableResult
    func createGroup(named name: String) -> ChecklistGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let group = ChecklistGroup(
            name: trimmed,
            sortOrder: (groups.map(\.sortOrder).max() ?? -1) + 1
        )
        groups.append(group)
        pendingMutations.append(.upsert(group: group, changedFields: Self.allGroupFields))
        persistAndSchedule()
        return group
    }

    func moveGroup(_ groupID: UUID, before targetID: UUID) {
        guard groupID != targetID else { return }
        var reordered = orderedGroups
        guard let sourceIndex = reordered.firstIndex(where: { $0.id == groupID }),
              let targetIndex = reordered.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = reordered.remove(at: sourceIndex)
        reordered.insert(moved, at: min(targetIndex, reordered.count))

        var changedGroups: [ChecklistGroup] = []
        for index in reordered.indices {
            let order = Double(index)
            guard reordered[index].sortOrder != order else { continue }
            reordered[index].sortOrder = order
            changedGroups.append(reordered[index])
        }
        guard !changedGroups.isEmpty else { return }
        groups = reordered
        let changedIDs = Set(changedGroups.map(\.id))
        pendingMutations.removeAll {
            $0.kind == .groupUpsert
                && $0.changedFields == ["sortOrder"]
                && $0.groupID.map(changedIDs.contains) == true
        }
        pendingMutations.append(contentsOf: changedGroups.map {
            .upsert(group: $0, changedFields: ["sortOrder"])
        })
        persistAndSchedule()
    }

    @discardableResult
    func renameGroup(_ groupID: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = groups.firstIndex(where: { $0.id == groupID }),
              groups[index].name != trimmed else { return false }
        guard !groups.contains(where: { $0.id != groupID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return false
        }

        groups[index].name = trimmed
        pendingMutations.removeAll {
            $0.kind == .groupUpsert
                && $0.changedFields == ["name"]
                && $0.groupID == groupID
        }
        pendingMutations.append(.upsert(group: groups[index], changedFields: ["name"]))
        persistAndSchedule()
        return true
    }

    func toggleGroupCollapsed(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].isCollapsed.toggle()
        pendingMutations.removeAll {
            $0.kind == .groupUpsert
                && $0.changedFields == ["isCollapsed"]
                && $0.groupID == groupID
        }
        pendingMutations.append(.upsert(group: groups[index], changedFields: ["isCollapsed"]))
        persistAndSchedule()
    }

    @discardableResult
    func deleteGroup(_ groupID: UUID) -> Bool {
        guard canDeleteGroup(groupID),
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        groups.remove(at: index)
        pendingMutations.removeAll { $0.groupID == groupID && ($0.kind == .groupUpsert || $0.kind == .groupDelete) }
        pendingMutations.append(.delete(groupID: groupID))
        persistAndSchedule()
        return true
    }

    func move(_ itemID: UUID, before targetID: UUID, toGroup groupID: UUID?) {
        guard itemID != targetID,
              let itemIndex = items.firstIndex(where: { $0.id == itemID }),
              let target = items.first(where: { $0.id == targetID }) else { return }
        let sourceGroupID = items[itemIndex].groupID
        let destinationGroupID = groupID ?? target.groupID
        items[itemIndex].groupID = destinationGroupID

        var destinationIDs = orderedItemIDs(in: destinationGroupID).filter { $0 != itemID }
        guard let targetIndex = destinationIDs.firstIndex(of: targetID) else { return }
        destinationIDs.insert(itemID, at: targetIndex)
        let changedItems = normalizeItemOrder(
            orderedIDs: destinationIDs,
            alsoNormalizeGroup: sourceGroupID == destinationGroupID ? nil : sourceGroupID,
            movedItemID: itemID
        )
        queueItemOrderingChanges(changedItems)
    }

    func move(_ itemID: UUID, toGroup groupID: UUID?) {
        guard let itemIndex = items.firstIndex(where: { $0.id == itemID }) else { return }
        let sourceGroupID = items[itemIndex].groupID
        guard sourceGroupID != groupID else { return }
        items[itemIndex].groupID = groupID
        var destinationIDs = orderedItemIDs(in: groupID).filter { $0 != itemID }
        destinationIDs.append(itemID)
        let changedItems = normalizeItemOrder(
            orderedIDs: destinationIDs,
            alsoNormalizeGroup: sourceGroupID,
            movedItemID: itemID
        )
        queueItemOrderingChanges(changedItems)
    }

    private func queueItemOrderingChanges(_ changedItems: [ChecklistItem]) {
        guard !changedItems.isEmpty else { return }
        let changedIDs = Set(changedItems.map(\.id))
        pendingMutations.removeAll {
            $0.kind == .upsert
                && ($0.changedFields == ["sortOrder"] || $0.changedFields == ["groupID", "sortOrder"])
                && $0.itemID.map(changedIDs.contains) == true
        }
        pendingMutations.append(contentsOf: changedItems.map {
            .upsert(item: $0, changedFields: ["groupID", "sortOrder"])
        })
        persistAndSchedule()
    }

    func delete(_ item: ChecklistItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].endedAt = Calendar.current.startOfDay(for: .now)
        items[index].scheduleRevision = min(items[index].scheduleRevision + 1, 1_000_000)
        pendingMutations.append(.upsert(
            item: items[index],
            changedFields: ["endedAt", "scheduleRevision"]
        ))
        persistAndSchedule()
    }

    func permanentlyDelete(_ item: ChecklistItem) {
        items.removeAll { $0.id == item.id }
        pendingMutations.append(.delete(itemID: item.id))
        persistAndSchedule()
    }

    func applyTemplate(_ template: RoutineTemplate) {
        let group = createGroup(named: template.groupName) ?? groups.first { $0.name == template.groupName }
        let groupID = group?.id
        let existingTitles = Set(items
            .filter { $0.groupID == groupID && $0.endedAt == nil }
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let missingTitles = template.items.filter {
            !existingTitles.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        guard !missingTitles.isEmpty else { return }
        let firstOrder = nextItemSortOrder(in: groupID)
        let createdItems = missingTitles.enumerated().map { offset, title in
            ChecklistItem(
                title: title,
                schedule: .everyDay,
                createdAt: .now,
                groupID: groupID,
                sortOrder: firstOrder + Double(offset)
            )
        }
        items.append(contentsOf: createdItems)
        pendingMutations.append(contentsOf: createdItems.map { .upsert(item: $0, changedFields: Self.allFields) })
        persistAndSchedule()
    }

    func applyBuiltInTemplates() {
        RoutineTemplate.builtIns.forEach(applyTemplate)
    }

    func skipGroup(_ groupID: UUID?) {
        let groupItems = visibleItems.filter { $0.groupID == groupID && !$0.isComplete(on: selectedDate) && !isPaused($0, on: selectedDate) }
        groupItems.forEach { setSkipped($0, skipped: true) }
    }

    func pause(_ item: ChecklistItem, days: Int = 7) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let start = Calendar.current.startOfDay(for: selectedDate)
        guard let end = Calendar.current.date(byAdding: .day, value: max(1, days) - 1, to: start) else { return }
        items[index].pause(from: start, until: end)
        pendingMutations.append(.upsert(item: items[index], changedFields: ["pauseWindows"]))
        persistAndSchedule()
    }

    func resume(_ item: ChecklistItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let before = items[index].pauseWindows
        items[index].resume(on: selectedDate)
        guard before != items[index].pauseWindows else { return }
        pendingMutations.append(.upsert(item: items[index], changedFields: ["pauseWindows"]))
        persistAndSchedule()
    }

    func pauseGroup(_ groupID: UUID, days: Int = 7) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let start = Calendar.current.startOfDay(for: selectedDate)
        guard let end = Calendar.current.date(byAdding: .day, value: max(1, days) - 1, to: start) else { return }
        groups[index].pause(from: start, until: end)
        pendingMutations.append(.upsert(group: groups[index], changedFields: ["pauseWindows"]))
        persistAndSchedule()
    }

    func resumeGroup(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let before = groups[index].pauseWindows
        groups[index].resume(on: selectedDate)
        guard before != groups[index].pauseWindows else { return }
        pendingMutations.append(.upsert(group: groups[index], changedFields: ["pauseWindows"]))
        persistAndSchedule()
    }

    func endGroupToday(_ groupID: UUID) {
        let end = Calendar.current.startOfDay(for: .now)
        var changed: [ChecklistItem] = []
        for index in items.indices where items[index].groupID == groupID && items[index].endedAt == nil {
            items[index].endedAt = end
            items[index].scheduleRevision = min(items[index].scheduleRevision + 1, 1_000_000)
            changed.append(items[index])
        }
        guard !changed.isEmpty else { return }
        pendingMutations.append(contentsOf: changed.map {
            .upsert(item: $0, changedFields: ["endedAt", "scheduleRevision"])
        })
        persistAndSchedule()
    }

    func startGroupTomorrow(_ groupID: UUID) {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) else { return }
        for carryover in unresolvedCarryoverEntries(inGroup: groupID) {
            guard let index = items.firstIndex(where: { $0.id == carryover.item.id }) else { continue }
            for reference in carryover.occurrences where items[index].occurrences[reference.id] == nil {
                let count = reference.state?.completionCount
                    ?? DateKey.date(from: reference.scheduledDateKey).map(items[index].completionCount(on:))
                    ?? 0
                let occurrence = reference.state ?? ChecklistOccurrence(
                    completionCount: count,
                    scheduleRevision: reference.scheduleRevision,
                    scheduledDate: reference.scheduledDateKey
                )
                items[index].setOccurrence(
                    occurrence,
                    scheduledDate: reference.scheduledDateKey,
                    scheduleRevision: reference.scheduleRevision
                )
                pendingMutations.append(.occurrence(
                    itemID: items[index].id,
                    occurrenceID: reference.id,
                    occurrence: occurrence
                ))
            }
        }
        var changed: [ChecklistItem] = []
        for index in items.indices where items[index].groupID == groupID && items[index].endedAt == nil {
            items[index].startDate = tomorrow
            items[index].scheduleRevision = min(items[index].scheduleRevision + 1, 1_000_000)
            if items[index].missedBehavior == .keepUntilDone {
                items[index].carryoverStartDate = DateKey.string(from: tomorrow)
            }
            changed.append(items[index])
        }
        guard !changed.isEmpty else { return }
        pendingMutations.append(contentsOf: changed.map {
            .upsert(
                item: $0,
                changedFields: ["startDate", "scheduleRevision", "carryoverStartDate"]
            )
        })
        persistAndSchedule()
    }

    func duplicateGroup(_ groupID: UUID) {
        guard let source = groups.first(where: { $0.id == groupID }) else { return }
        let baseName = "\(source.name) Copy"
        let group = createGroup(named: uniqueGroupName(baseName)) ?? source
        let sourceItems = items.filter { $0.groupID == groupID && $0.endedAt == nil }.sorted(by: Self.isOrderedBefore)
        let copied = sourceItems.enumerated().map { offset, item in
            ChecklistItem(
                title: item.title,
                notes: item.notes,
                schedule: item.schedule,
                customWeekdays: item.customWeekdays,
                recurrence: item.recurrence,
                reminderMinutes: item.reminderMinutes,
                followUpPolicy: item.followUpPolicy,
                quantity: item.quantity,
                createdAt: .now,
                startDate: item.startDate,
                groupID: group.id,
                sortOrder: Double(offset),
                missedBehavior: item.missedBehavior,
                carryoverStartDate: item.missedBehavior == .keepUntilDone
                    ? DateKey.string(from: .now)
                    : nil
            )
        }
        items.append(contentsOf: copied)
        pendingMutations.append(contentsOf: copied.map { .upsert(item: $0, changedFields: Self.allFields) })
        persistAndSchedule()
    }

    func completionHistory(for item: ChecklistItem, days: Int = 21) -> [(date: Date, state: ChecklistHistoryState)] {
        (0..<days).compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: selectedDate)) else {
                return nil
            }
            return (date, historyState(for: item, on: date))
        }
    }

    func routineInsights(
        asOf date: Date = .now,
        days: Int = 21,
        calendar: Calendar = .current
    ) -> RoutineInsightSummary {
        let anchor = min(calendar.startOfDay(for: date), calendar.startOfDay(for: .now))
        let windowLength = max(1, days)
        let completedDays = (1...windowLength).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: anchor).map {
                calendar.startOfDay(for: $0)
            }
        }
        var completedCheckIns = 0
        var expectedCheckIns = 0
        var lateCompletedCheckIns = 0
        var recentCompleted = 0
        var recentExpected = 0
        var priorCompleted = 0
        var priorExpected = 0
        var missedWeekdays: [Int: Int] = [:]

        for item in items {
            for (index, day) in completedDays.enumerated() {
                let state = historyState(for: item, on: day)
                let isExpected = state == .done || state == .missed || state == .open
                guard isExpected else { continue }

                expectedCheckIns += 1
                if state == .done {
                    completedCheckIns += 1
                    let key = DateKey.string(from: day)
                    if let resolvedDate = Self.latestOccurrence(
                        in: item,
                        scheduledDateKey: key
                    )?.occurrence.resolvedDate,
                       resolvedDate > key {
                        lateCompletedCheckIns += 1
                    }
                }

                if index < 7 {
                    recentExpected += 1
                    if state == .done { recentCompleted += 1 }
                } else if index < 14 {
                    priorExpected += 1
                    if state == .done { priorCompleted += 1 }
                }

                if state == .missed || state == .open {
                    missedWeekdays[calendar.component(.weekday, from: day), default: 0] += 1
                }
            }
        }

        let trendPercentagePoints: Int?
        if recentExpected >= 3, priorExpected >= 3 {
            let recentRate = Int((Double(recentCompleted) / Double(recentExpected) * 100).rounded())
            let priorRate = Int((Double(priorCompleted) / Double(priorExpected) * 100).rounded())
            trendPercentagePoints = recentRate - priorRate
        } else {
            trendPercentagePoints = nil
        }

        let activeItems = items.filter { $0.endedAt == nil }
        let currentStreak = activeItems
            .map { RoutineInsightHighlight(
                title: $0.title,
                count: completionStreak(for: $0, asOf: anchor, days: windowLength, calendar: calendar)
            ) }
            .filter { $0.count > 0 }
            .sorted(by: insightHighlightComesFirst)
            .first

        var longestDelays: [RoutineInsightHighlight] = []
        for item in activeItems {
            let longest = (0..<windowLength).compactMap { offset -> Int? in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: anchor),
                      !isPaused(item, on: day) else { return nil }
                return item.delayedDays(asOf: day, calendar: calendar)
            }.max() ?? 0
            if longest > 0 {
                longestDelays.append(RoutineInsightHighlight(title: item.title, count: longest))
            }
        }

        let missedPattern = missedWeekdays
            .map { (weekday: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.weekday < $1.weekday
            }
            .first
        let missedWeekday = missedPattern.flatMap { pattern -> String? in
            guard pattern.count >= 2,
                  calendar.weekdaySymbols.indices.contains(pattern.weekday - 1) else { return nil }
            return calendar.weekdaySymbols[pattern.weekday - 1]
        }

        return RoutineInsightSummary(
            completedCheckIns: completedCheckIns,
            expectedCheckIns: expectedCheckIns,
            lateCompletedCheckIns: lateCompletedCheckIns,
            trendPercentagePoints: trendPercentagePoints,
            currentStreak: currentStreak,
            missedWeekday: missedWeekday,
            missedWeekdayCount: missedWeekday == nil ? 0 : missedPattern?.count ?? 0,
            longestDelay: longestDelays.sorted(by: insightHighlightComesFirst).first
        )
    }

    private func completionStreak(
        for item: ChecklistItem,
        asOf date: Date,
        days: Int,
        calendar: Calendar
    ) -> Int {
        var cursor = calendar.startOfDay(for: date)
        var streak = 0
        var inspectedDays = 0

        if historyState(for: item, on: cursor) != .done,
           let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = previousDay
        }

        while inspectedDays < days {
            switch historyState(for: item, on: cursor) {
            case .done:
                streak += 1
            case .off, .paused:
                break
            case .skipped, .missed, .open:
                return streak
            }
            inspectedDays += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previousDay
        }
        return streak
    }

    private func insightHighlightComesFirst(
        _ left: RoutineInsightHighlight,
        _ right: RoutineInsightHighlight
    ) -> Bool {
        if left.count != right.count { return left.count > right.count }
        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }

    func updateEveningReminder(_ minutes: Int?) {
        eveningReminderMinutes = minutes
        pendingMutations.append(.evening(minutes: minutes))
        persistAndSchedule()
    }

    func updateNotificationGroupFilter(_ filter: NotificationGroupFilter) {
        let normalized = filter.normalized(availableGroupIDs: Set(groups.map(\.id)))
        guard notificationGroupFilter != normalized else { return }
        notificationGroupFilter = normalized
        pendingMutations.append(.notificationFilter(normalized))
        persistAndSchedule()
    }

    func updateNotificationQuietHours(_ quietHours: NotificationQuietHours?) {
        guard notificationQuietHours != quietHours else { return }
        notificationQuietHours = quietHours
        pendingMutations.append(.quietHours(quietHours))
        persistAndSchedule()
    }

    @discardableResult
    func sync(using authStore: AuthStore) async -> Bool {
        guard let token = await authStore.validAccessToken() else {
            syncState = pendingMutations.isEmpty ? "Saved locally" : "Waiting to sync"
            return false
        }
        let sent = pendingMutations
        syncState = "Syncing…"
        do {
            let request = SyncRequest(deviceID: deviceID, mutations: sent)
            let response: SyncResponse
            do {
                response = try await api.sync(request, token: token)
            } catch APIClient.APIError.badResponse(401) {
                guard let refreshed = await authStore.refreshAccessToken() else { throw APIClient.APIError.badResponse(401) }
                response = try await api.sync(request, token: refreshed)
            }
            let accepted = Set(response.acceptedMutationIDs)
            pendingMutations.removeAll { accepted.contains($0.id) }
            items = response.items
            groups = response.groups ?? groups
            eveningReminderMinutes = response.eveningReminderMinutes
            notificationGroupFilter = response.notificationGroupFilter ?? .all
            notificationQuietHours = response.notificationQuietHours
            persistAndSchedule()
            let didFinishSyncing = pendingMutations.isEmpty
            syncState = didFinishSyncing ? "Synced" : "Changes pending"
            return didFinishSyncing
        } catch {
            syncState = "Saved offline"
            return false
        }
    }

    func applyImportedState(_ response: SyncResponse) {
        syncTask?.cancel()
        pendingMutations = []
        items = response.items
        groups = response.groups ?? []
        eveningReminderMinutes = response.eveningReminderMinutes
        notificationGroupFilter = response.notificationGroupFilter ?? .all
        notificationQuietHours = response.notificationQuietHours
        persistAndSchedule()
        syncState = "Restored from export"
    }

    func widgetSnapshot(now: Date = .now) -> RitualWidgetSnapshot {
        widgetSnapshot(for: Calendar.current.startOfDay(for: now), now: now)
    }

    private func widgetSnapshots(now: Date = .now, days: Int = 7) -> [RitualWidgetSnapshot] {
        let today = Calendar.current.startOfDay(for: now)
        return (0..<max(1, days)).compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: today) else { return nil }
            return widgetSnapshot(for: date, now: now)
        }
    }

    private func widgetSnapshot(for date: Date, now: Date) -> RitualWidgetSnapshot {
        let today = Calendar.current.startOfDay(for: date)
        let carryovers = CarryoverResolver.entries(items: items, groups: groups, asOf: today)
        let carryoverItemIDs = Set(CarryoverResolver.entries(
            items: items,
            groups: groups,
            asOf: today,
            includeHidden: true
        ).map(\.item.id))
        let visibleTodayItems = items.filter { item in
            let paused = isPaused(item, on: today)
            return !carryoverItemIDs.contains(item.id)
                && isTracked(item, on: today)
                && (!paused || item.hasRecordedState(on: today))
        }
        let remainingItems = visibleTodayItems.filter {
            !$0.isComplete(on: today) && !$0.isSkipped(on: today) && !isPaused($0, on: today)
        }
        let completedCount = visibleTodayItems.filter { $0.isComplete(on: today) }.count
        let skippedCount = visibleTodayItems.filter { $0.isSkipped(on: today) && !$0.isComplete(on: today) }.count
        let reminderMinutes = widgetReminderMinutes(
            remainingItems: remainingItems,
            carryoverItems: carryovers.map(\.item)
        )

        return RitualWidgetSnapshot(
            remainingCount: remainingItems.count + carryovers.count,
            scheduledCount: visibleTodayItems.count + carryovers.count,
            completedCount: completedCount,
            skippedCount: skippedCount,
            carryoverCount: carryovers.count,
            reminderMinutes: reminderMinutes,
            nextReminderMinutes: nextWidgetReminderMinutes(on: today, now: now, reminderMinutes: reminderMinutes),
            dateKey: DateKey.string(from: today),
            updatedAt: now,
            hasChecklist: !items.isEmpty
        )
    }

    private func loadCache() {
        var sourceURL = cacheURL
        if activeAccountID == "anonymous", !FileManager.default.fileExists(atPath: sourceURL.path) {
            let legacyURL = URL.documentsDirectory.appending(path: "daily-checklist.json")
            if FileManager.default.fileExists(atPath: legacyURL.path) { sourceURL = legacyURL }
        }
        guard let data = try? Data(contentsOf: sourceURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let envelope = try? decoder.decode(LocalEnvelope.self, from: data) {
            items = envelope.items
            groups = envelope.groups ?? []
            eveningReminderMinutes = envelope.eveningReminderMinutes
            notificationGroupFilter = envelope.notificationGroupFilter ?? .all
            notificationQuietHours = envelope.notificationQuietHours
            pendingMutations = envelope.pendingMutations
            return
        }
        if let legacy = try? decoder.decode(LegacyEnvelope.self, from: data) {
            items = legacy.items
            groups = []
            eveningReminderMinutes = legacy.eveningReminderMinutes
            notificationGroupFilter = .all
            notificationQuietHours = nil
            pendingMutations = legacy.items.map { .upsert(item: $0, changedFields: Self.allFields) }
            if let minutes = legacy.eveningReminderMinutes {
                pendingMutations.append(.evening(minutes: minutes))
            }
        }
    }

    private func persistAndSchedule() {
        let envelope = LocalEnvelope(
            items: items,
            groups: groups,
            eveningReminderMinutes: eveningReminderMinutes,
            notificationGroupFilter: notificationGroupFilter,
            notificationQuietHours: notificationQuietHours,
            pendingMutations: pendingMutations
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(envelope) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        persistWidgetSnapshot(reloadTimelines: true)

        notificationTask?.cancel()
        notificationTask = Task {
            await refreshNotificationSchedule()
        }
        if !pendingMutations.isEmpty {
            syncState = "Changes pending"
            syncTask?.cancel()
            syncTask = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let authStore else { return }
                await sync(using: authStore)
            }
        }
    }

    private func switchLocalAccount(to accountID: String) {
        guard activeAccountID != accountID else { return }
        syncTask?.cancel()
        activeAccountID = accountID
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")
        items = []
        groups = []
        pendingMutations = []
        eveningReminderMinutes = 20 * 60
        notificationGroupFilter = .all
        notificationQuietHours = nil
        loadCache()
        persistAndSchedule()
    }

    private func clearAnonymousCache() {
        let empty = LocalEnvelope(
            items: [],
            groups: [],
            eveningReminderMinutes: 20 * 60,
            notificationGroupFilter: .all,
            notificationQuietHours: nil,
            pendingMutations: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(empty) else { return }
        let url = URL.documentsDirectory.appending(path: "daily-checklist-anonymous.json")
        try? data.write(to: url, options: .atomic)
    }

    private func widgetReminderMinutes(
        remainingItems: [ChecklistItem],
        carryoverItems: [ChecklistItem]
    ) -> [Int] {
        var candidates = remainingItems.compactMap(\.reminderMinutes)
        if let eveningReminderMinutes {
            let eveningRemainingCount = (remainingItems + carryoverItems)
                .filter { notificationFilterForScheduling.includes(item: $0) }
                .count
            if eveningRemainingCount > 0 {
                candidates.append(eveningReminderMinutes)
            }
        }
        return Array(Set(candidates)).sorted()
    }

    private func nextWidgetReminderMinutes(
        on date: Date,
        now: Date,
        reminderMinutes: [Int]
    ) -> Int? {
        let calendar = Calendar.current
        return reminderMinutes.filter { minutes in
            var components = calendar.dateComponents([.year, .month, .day], from: date)
            components.hour = minutes / 60
            components.minute = minutes % 60
            guard let reminderDate = calendar.date(from: components) else { return false }
            return reminderDate > now
        }.min()
    }

    private func persistWidgetSnapshot(reloadTimelines: Bool) {
        guard RitualWidgetSnapshotStore.save(widgetSnapshots()) else { return }
        guard reloadTimelines else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: RitualWidgetSnapshotStore.kind)
    }

    static let allFields: Set<String> = [
        "title", "notes", "schedule", "customWeekdays", "recurrence", "reminderMinutes", "followUpPolicy", "quantity", "skippedDates", "openDates", "createdAt", "startDate", "endedAt", "groupID", "sortOrder", "pauseWindows", "scheduleRevision", "missedBehavior", "carryoverStartDate", "carryoverResolvedThroughDate"
    ]
    static let allGroupFields: Set<String> = ["name", "sortOrder", "isCollapsed", "pauseWindows"]

    private static func changedFields(from old: ChecklistItem, to new: ChecklistItem) -> Set<String> {
        var changed: Set<String> = []
        if old.title != new.title { changed.insert("title") }
        if old.notes != new.notes { changed.insert("notes") }
        if old.schedule != new.schedule { changed.insert("schedule") }
        if old.customWeekdays != new.customWeekdays { changed.insert("customWeekdays") }
        if old.recurrence != new.recurrence { changed.insert("recurrence") }
        if old.reminderMinutes != new.reminderMinutes { changed.insert("reminderMinutes") }
        if old.followUpPolicy != new.followUpPolicy { changed.insert("followUpPolicy") }
        if old.quantity != new.quantity { changed.insert("quantity") }
        if old.skippedDates != new.skippedDates { changed.insert("skippedDates") }
        if old.openDates != new.openDates { changed.insert("openDates") }
        if old.startDate != new.startDate { changed.insert("startDate") }
        if old.endedAt != new.endedAt { changed.insert("endedAt") }
        if old.groupID != new.groupID { changed.insert("groupID") }
        if old.sortOrder != new.sortOrder { changed.insert("sortOrder") }
        if old.pauseWindows != new.pauseWindows { changed.insert("pauseWindows") }
        if old.scheduleRevision != new.scheduleRevision { changed.insert("scheduleRevision") }
        if old.missedBehavior != new.missedBehavior { changed.insert("missedBehavior") }
        if old.carryoverStartDate != new.carryoverStartDate { changed.insert("carryoverStartDate") }
        if old.carryoverResolvedThroughDate != new.carryoverResolvedThroughDate { changed.insert("carryoverResolvedThroughDate") }
        return changed
    }

    private func queueDaySetMutationIfNeeded(
        for item: ChecklistItem,
        wasSkipped: Bool,
        wasOpen: Bool,
        key: String
    ) {
        let changedFields = [
            wasSkipped != item.skippedDates.contains(key) ? "skippedDates" : nil,
            wasOpen != item.openDates.contains(key) ? "openDates" : nil
        ].compactMap { $0 }
        guard !changedFields.isEmpty else { return }
        pendingMutations.append(.upsert(item: item, changedFields: Set(changedFields)))
    }

    private func queueOccurrenceState(for index: Int, key: String) {
        guard items.indices.contains(index),
              items[index].schedule != .everyDay,
              let date = DateKey.date(from: key) else { return }
        let count = items[index].completionCount(on: date)
        let outcome: ChecklistOccurrence.Outcome
        if items[index].isComplete(on: date) {
            outcome = .done
        } else if items[index].isSkipped(on: date) {
            outcome = .skipped
        } else {
            outcome = .open
        }
        let occurrence = ChecklistOccurrence(
            outcome: outcome,
            completionCount: count,
            resolvedDate: outcome == .open ? nil : DateKey.string(from: .now),
            scheduleRevision: items[index].scheduleRevision,
            scheduledDate: key
        )
        guard items[index].occurrence(scheduledDate: key) != occurrence else { return }
        let occurrenceID = items[index].setOccurrence(occurrence, scheduledDate: key)
        pendingMutations.append(.occurrence(
            itemID: items[index].id,
            occurrenceID: occurrenceID,
            occurrence: occurrence
        ))
    }

    private static func latestOccurrence(
        in item: ChecklistItem,
        scheduledDateKey: String
    ) -> (id: String, occurrence: ChecklistOccurrence)? {
        item.occurrences
            .filter { $0.value.scheduledDate == scheduledDateKey }
            .max {
                if $0.value.scheduleRevision != $1.value.scheduleRevision {
                    return $0.value.scheduleRevision < $1.value.scheduleRevision
                }
                return $0.key < $1.key
            }
            .map { (id: $0.key, occurrence: $0.value) }
    }

    private static func isOrderedBefore(_ lhs: ChecklistItem, _ rhs: ChecklistItem) -> Bool {
        switch (lhs.sortOrder, rhs.sortOrder) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func sortPredicate(_ lhs: ChecklistItem, _ rhs: ChecklistItem) -> Bool {
        switch sortMode {
        case .manual:
            return Self.isOrderedBefore(lhs, rhs)
        case .name:
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return Self.isOrderedBefore(lhs, rhs)
        case .reminderTime:
            switch (lhs.reminderMinutes, rhs.reminderMinutes) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return Self.isOrderedBefore(lhs, rhs)
            }
        }
    }

    private func nextItemSortOrder(in groupID: UUID?) -> Double {
        let orders = items.filter { $0.groupID == groupID }.compactMap(\.sortOrder)
        return (orders.max() ?? -1) + 1
    }

    private func uniqueGroupName(_ base: String) -> String {
        if !groups.contains(where: { $0.name.caseInsensitiveCompare(base) == .orderedSame }) {
            return base
        }
        var index = 2
        while true {
            let candidate = "\(base) \(index)"
            if !groups.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return candidate
            }
            index += 1
        }
    }

    private func orderedItemIDs(in groupID: UUID?) -> [UUID] {
        items.filter { $0.groupID == groupID }.sorted(by: Self.isOrderedBefore).map(\.id)
    }

    private func normalizeItemOrder(
        orderedIDs: [UUID],
        alsoNormalizeGroup groupID: UUID?,
        movedItemID: UUID
    ) -> [ChecklistItem] {
        var changed: [ChecklistItem] = []
        var orderings: [(UUID, Double)] = orderedIDs.enumerated().map { ($0.element, Double($0.offset)) }
        if let groupID {
            orderings += orderedItemIDs(in: groupID).enumerated().map { ($0.element, Double($0.offset)) }
        }
        for (id, order) in orderings {
            guard let index = items.firstIndex(where: { $0.id == id }),
                  items[index].sortOrder != order || id == movedItemID else { continue }
            items[index].sortOrder = order
            changed.append(items[index])
        }
        if let index = items.firstIndex(where: { $0.id == movedItemID }),
           !changed.contains(where: { $0.id == movedItemID }) {
            changed.append(items[index])
        }
        return changed
    }
}
