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
        case .reminderTime: "Reminder time"
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

@MainActor
final class ChecklistStore: ObservableObject {
    @Published private(set) var items: [ChecklistItem] = []
    @Published var showingToday = true
    @Published var selectedDate = Calendar.current.startOfDay(for: .now)
    @Published var eveningReminderMinutes: Int? = 20 * 60
    @Published private(set) var syncState = "Saved locally"
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
        items
            .filter { !showingToday || $0.occurs(on: selectedDate) }
            .sorted(by: sortPredicate)
    }

    var todoItems: [ChecklistItem] {
        visibleItems.filter { !$0.isComplete(on: selectedDate) }
    }

    var completedItems: [ChecklistItem] {
        visibleItems.filter { $0.isComplete(on: selectedDate) }
    }

    var isSelectedDateToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    func moveSelectedDate(by days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) else { return }
        selectedDate = Calendar.current.startOfDay(for: date)
    }

    func selectToday() {
        selectedDate = Calendar.current.startOfDay(for: .now)
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        loadCache()
        await notifications.requestAuthorization()
        if items.isEmpty {
            let vitamins = ChecklistItem(title: "Take vitamins", notes: "With breakfast", reminderMinutes: 8 * 60)
            let dog = ChecklistItem(title: "Walk the dog", schedule: .everyDay, reminderMinutes: 18 * 60)
            items = [vitamins, dog]
            pendingMutations = [
                .upsert(item: vitamins, changedFields: Self.allFields),
                .upsert(item: dog, changedFields: Self.allFields)
            ]
            persistAndSchedule()
        }
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
        }
        pendingMutations.append(.completion(
            itemID: item.id,
            date: key,
            completed: items[index].completedDates.contains(key)
        ))
        persistAndSchedule()
    }

    func completeAllForSelectedDate() {
        let key = DateKey.string(from: selectedDate)
        var completedItemIDs: [UUID] = []

        for index in items.indices {
            guard items[index].occurs(on: selectedDate),
                  !items[index].completedDates.contains(key) else { continue }
            items[index].completedDates.insert(key)
            completedItemIDs.append(items[index].id)
        }

        guard !completedItemIDs.isEmpty else { return }
        pendingMutations.append(contentsOf: completedItemIDs.map {
            .completion(itemID: $0, date: key, completed: true)
        })
        persistAndSchedule()
    }

    func save(_ item: ChecklistItem) {
        var item = item
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let changedFields = Self.changedFields(from: items[index], to: item)
            items[index] = item
            if !changedFields.isEmpty {
                pendingMutations.append(.upsert(item: item, changedFields: changedFields))
            }
        } else {
            item.sortOrder = (items.compactMap(\.sortOrder).max() ?? Double(items.count - 1)) + 1
            items.append(item)
            pendingMutations.append(.upsert(item: item, changedFields: Self.allFields))
        }
        persistAndSchedule()
    }

    func move(_ itemID: UUID, before targetID: UUID, within sectionIDs: [UUID]) {
        guard itemID != targetID,
              let sourceIndex = sectionIDs.firstIndex(of: itemID),
              let targetIndex = sectionIDs.firstIndex(of: targetID) else { return }

        var reorderedSection = sectionIDs
        let movedID = reorderedSection.remove(at: sourceIndex)
        reorderedSection.insert(movedID, at: min(targetIndex, reorderedSection.count))

        var orderedAll = items.sorted(by: Self.isOrderedBefore)
        let sectionSet = Set(sectionIDs)
        let sectionSlots = orderedAll.indices.filter { sectionSet.contains(orderedAll[$0].id) }
        guard sectionSlots.count == reorderedSection.count else { return }

        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for (slot, reorderedID) in zip(sectionSlots, reorderedSection) {
            guard let replacement = lookup[reorderedID] else { return }
            orderedAll[slot] = replacement
        }

        var changedItems: [ChecklistItem] = []
        for index in orderedAll.indices {
            let order = Double(index)
            guard orderedAll[index].sortOrder != order else { continue }
            orderedAll[index].sortOrder = order
            changedItems.append(orderedAll[index])
        }
        guard !changedItems.isEmpty else { return }

        items = orderedAll
        let changedIDs = Set(changedItems.map(\.id))
        pendingMutations.removeAll {
            $0.kind == .upsert
                && $0.changedFields == ["sortOrder"]
                && $0.itemID.map(changedIDs.contains) == true
        }
        pendingMutations.append(contentsOf: changedItems.map {
            .upsert(item: $0, changedFields: ["sortOrder"])
        })
        persistAndSchedule()
    }

    func delete(_ item: ChecklistItem) {
        items.removeAll { $0.id == item.id }
        pendingMutations.append(.delete(itemID: item.id))
        persistAndSchedule()
    }

    func updateEveningReminder(_ minutes: Int?) {
        eveningReminderMinutes = minutes
        pendingMutations.append(.evening(minutes: minutes))
        persistAndSchedule()
    }

    func sync(using authStore: AuthStore) async {
        guard let token = await authStore.validAccessToken() else {
            syncState = pendingMutations.isEmpty ? "Saved locally" : "Waiting to sync"
            return
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
            eveningReminderMinutes = response.eveningReminderMinutes
            persistAndSchedule()
            syncState = pendingMutations.isEmpty ? "Synced" : "Changes pending"
        } catch {
            syncState = "Saved offline"
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
            eveningReminderMinutes = envelope.eveningReminderMinutes
            pendingMutations = envelope.pendingMutations
            return
        }
        if let legacy = try? decoder.decode(LegacyEnvelope.self, from: data) {
            items = legacy.items
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
        pendingMutations = []
        eveningReminderMinutes = 20 * 60
        loadCache()
        persistAndSchedule()
    }

    private func clearAnonymousCache() {
        let empty = LocalEnvelope(items: [], eveningReminderMinutes: 20 * 60, pendingMutations: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(empty) else { return }
        let url = URL.documentsDirectory.appending(path: "daily-checklist-anonymous.json")
        try? data.write(to: url, options: .atomic)
    }

    static let allFields: Set<String> = [
        "title", "notes", "schedule", "customWeekdays", "reminderMinutes", "createdAt", "sortOrder"
    ]

    private static func changedFields(from old: ChecklistItem, to new: ChecklistItem) -> Set<String> {
        var changed: Set<String> = []
        if old.title != new.title { changed.insert("title") }
        if old.notes != new.notes { changed.insert("notes") }
        if old.schedule != new.schedule { changed.insert("schedule") }
        if old.customWeekdays != new.customWeekdays { changed.insert("customWeekdays") }
        if old.reminderMinutes != new.reminderMinutes { changed.insert("reminderMinutes") }
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
}
