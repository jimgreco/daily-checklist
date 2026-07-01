import Foundation

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
    @Published private(set) var syncState = "Saved locally"
    @Published private(set) var hasLoaded = false
    @Published var sortMode: ChecklistSort {
        didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: "checklistSortMode") }
    }

    private let api = APIClient()
    private let notifications = NotificationManager()
    private var hasStarted = false
    private var syncTask: Task<Void, Never>?
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

    private var cacheURL: URL {
        URL.documentsDirectory.appending(path: "daily-checklist-\(activeAccountID).json")
    }

    var visibleItems: [ChecklistItem] {
        let scoped: [ChecklistItem]
        switch scope {
        case .today:
            scoped = items.filter { $0.occurs(on: selectedDate) }
        case .all:
            scoped = items.filter { $0.isActive(on: selectedDate) }
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
        visibleItems.filter { !$0.isComplete(on: selectedDate) && !$0.isSkipped(on: selectedDate) }
    }

    var completedItems: [ChecklistItem] {
        visibleItems.filter { $0.isComplete(on: selectedDate) }
    }

    var skippedItems: [ChecklistItem] {
        visibleItems.filter { $0.isSkipped(on: selectedDate) && !$0.isComplete(on: selectedDate) }
    }

    var isSelectedDateToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    func canDeleteGroup(_ groupID: UUID) -> Bool {
        !items.contains { $0.groupID == groupID && $0.endedAt == nil }
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
        await notifications.requestAuthorization()
        await notifications.reschedule(items: items, eveningMinutes: eveningReminderMinutes)
    }

    func connect(to authStore: AuthStore) {
        self.authStore = authStore
    }

    func activateAuthenticatedAccount(_ userID: String) {
        guard activeAccountID != userID else { return }
        if activeAccountID == "anonymous" {
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
        if items[index].completedDates.contains(key) {
            items[index].completedDates.remove(key)
        } else {
            items[index].completedDates.insert(key)
            items[index].skippedDates.remove(key)
        }
        pendingMutations.append(.completion(
            itemID: item.id,
            date: key,
            completed: items[index].completedDates.contains(key)
        ))
        pendingMutations.append(.upsert(item: items[index], changedFields: ["skippedDates"]))
        persistAndSchedule()
    }

    func setSkipped(_ item: ChecklistItem, skipped: Bool, on date: Date? = nil) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let key = DateKey.string(from: date ?? selectedDate)
        if skipped {
            items[index].skippedDates.insert(key)
            items[index].completedDates.remove(key)
        } else {
            items[index].skippedDates.remove(key)
        }
        pendingMutations.append(.upsert(item: items[index], changedFields: ["skippedDates"]))
        if skipped {
            pendingMutations.append(.completion(itemID: items[index].id, date: key, completed: false))
        }
        persistAndSchedule()
    }

    func complete(itemID: UUID, on date: Date) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let key = DateKey.string(from: date)
        items[index].completedDates.insert(key)
        items[index].skippedDates.remove(key)
        pendingMutations.append(.completion(itemID: itemID, date: key, completed: true))
        pendingMutations.append(.upsert(item: items[index], changedFields: ["skippedDates"]))
        persistAndSchedule()
    }

    func skip(itemID: UUID, on date: Date) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        setSkipped(item, skipped: true, on: date)
    }

    func setHistoryState(_ state: ChecklistHistoryState, for itemID: UUID, on date: Date) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }

        let key = DateKey.string(from: date)
        let wasCompleted = items[index].completedDates.contains(key)
        let wasSkipped = items[index].skippedDates.contains(key)

        switch state {
        case .done:
            items[index].completedDates.insert(key)
            items[index].skippedDates.remove(key)
        case .skipped:
            items[index].completedDates.remove(key)
            items[index].skippedDates.insert(key)
        case .missed, .open, .off:
            items[index].completedDates.remove(key)
            items[index].skippedDates.remove(key)
        }

        let isCompleted = items[index].completedDates.contains(key)
        let isSkipped = items[index].skippedDates.contains(key)
        guard wasCompleted != isCompleted || wasSkipped != isSkipped else { return }

        if wasCompleted != isCompleted || (!isCompleted && (isSkipped || wasSkipped)) {
            pendingMutations.append(.completion(itemID: itemID, date: key, completed: isCompleted))
        }
        if wasSkipped != isSkipped {
            pendingMutations.append(.upsert(item: items[index], changedFields: ["skippedDates"]))
        }

        persistAndSchedule()
    }

    func snooze(itemID: UUID, minutes: Int = 60) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        Task { await notifications.snooze(item: item, minutes: minutes) }
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
            items[index].completedDates.insert(key)
            items[index].skippedDates.remove(key)
            completedItemIDs.append(items[index].id)
        }

        guard !completedItemIDs.isEmpty else { return }
        pendingMutations.append(contentsOf: completedItemIDs.map {
            .completion(itemID: $0, date: key, completed: true)
        })
        pendingMutations.append(contentsOf: items.filter { completedItemIDs.contains($0.id) }.map {
            .upsert(item: $0, changedFields: ["skippedDates"])
        })
        persistAndSchedule()
    }

    func save(_ item: ChecklistItem) {
        var item = item
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            if items[index].groupID != item.groupID {
                item.sortOrder = nextItemSortOrder(in: item.groupID)
            }
            let changedFields = Self.changedFields(from: items[index], to: item)
            items[index] = item
            if !changedFields.isEmpty {
                pendingMutations.append(.upsert(item: item, changedFields: changedFields))
            }
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
        pendingMutations.append(.upsert(item: items[index], changedFields: ["endedAt"]))
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
        let firstOrder = nextItemSortOrder(in: groupID)
        let createdItems = template.items.enumerated().map { offset, title in
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
        let groupItems = visibleItems.filter { $0.groupID == groupID && !$0.isComplete(on: selectedDate) }
        groupItems.forEach { setSkipped($0, skipped: true) }
    }

    func endGroupToday(_ groupID: UUID) {
        let end = Calendar.current.startOfDay(for: .now)
        var changed: [ChecklistItem] = []
        for index in items.indices where items[index].groupID == groupID && items[index].endedAt == nil {
            items[index].endedAt = end
            changed.append(items[index])
        }
        guard !changed.isEmpty else { return }
        pendingMutations.append(contentsOf: changed.map { .upsert(item: $0, changedFields: ["endedAt"]) })
        persistAndSchedule()
    }

    func startGroupTomorrow(_ groupID: UUID) {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) else { return }
        var changed: [ChecklistItem] = []
        for index in items.indices where items[index].groupID == groupID && items[index].endedAt == nil {
            items[index].startDate = tomorrow
            changed.append(items[index])
        }
        guard !changed.isEmpty else { return }
        pendingMutations.append(contentsOf: changed.map { .upsert(item: $0, changedFields: ["startDate"]) })
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
                reminderMinutes: item.reminderMinutes,
                createdAt: .now,
                startDate: item.startDate,
                groupID: group.id,
                sortOrder: Double(offset)
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
            let state: ChecklistHistoryState
            if item.isComplete(on: date) {
                state = .done
            } else if item.isSkipped(on: date) {
                state = .skipped
            } else if item.occurs(on: date) && date < Calendar.current.startOfDay(for: .now) {
                state = .missed
            } else if item.occurs(on: date) {
                state = .open
            } else {
                state = .off
            }
            return (date, state)
        }
    }

    func updateEveningReminder(_ minutes: Int?) {
        eveningReminderMinutes = minutes
        pendingMutations.append(.evening(minutes: minutes))
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
            persistAndSchedule()
            let didFinishSyncing = pendingMutations.isEmpty
            syncState = didFinishSyncing ? "Synced" : "Changes pending"
            return didFinishSyncing
        } catch {
            syncState = "Saved offline"
            return false
        }
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
            pendingMutations = envelope.pendingMutations
            return
        }
        if let legacy = try? decoder.decode(LegacyEnvelope.self, from: data) {
            items = legacy.items
            groups = []
            eveningReminderMinutes = legacy.eveningReminderMinutes
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
            pendingMutations: pendingMutations
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(envelope) {
            try? data.write(to: cacheURL, options: .atomic)
        }

        Task { await notifications.reschedule(items: items, eveningMinutes: eveningReminderMinutes) }
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
        loadCache()
        persistAndSchedule()
    }

    private func clearAnonymousCache() {
        let empty = LocalEnvelope(items: [], groups: [], eveningReminderMinutes: 20 * 60, pendingMutations: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(empty) else { return }
        let url = URL.documentsDirectory.appending(path: "daily-checklist-anonymous.json")
        try? data.write(to: url, options: .atomic)
    }

    static let allFields: Set<String> = [
        "title", "notes", "schedule", "customWeekdays", "reminderMinutes", "skippedDates", "createdAt", "startDate", "endedAt", "groupID", "sortOrder"
    ]
    static let allGroupFields: Set<String> = ["name", "sortOrder"]

    private static func changedFields(from old: ChecklistItem, to new: ChecklistItem) -> Set<String> {
        var changed: Set<String> = []
        if old.title != new.title { changed.insert("title") }
        if old.notes != new.notes { changed.insert("notes") }
        if old.schedule != new.schedule { changed.insert("schedule") }
        if old.customWeekdays != new.customWeekdays { changed.insert("customWeekdays") }
        if old.reminderMinutes != new.reminderMinutes { changed.insert("reminderMinutes") }
        if old.skippedDates != new.skippedDates { changed.insert("skippedDates") }
        if old.startDate != new.startDate { changed.insert("startDate") }
        if old.endedAt != new.endedAt { changed.insert("endedAt") }
        if old.groupID != new.groupID { changed.insert("groupID") }
        if old.sortOrder != new.sortOrder { changed.insert("sortOrder") }
        return changed
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
