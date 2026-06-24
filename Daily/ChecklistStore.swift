import Foundation

@MainActor
final class ChecklistStore: ObservableObject {
    @Published private(set) var items: [ChecklistItem] = []
    @Published var showingToday = true
    @Published var eveningReminderMinutes: Int? = 20 * 60
    @Published private(set) var syncState = "Saved locally"

    private let api = APIClient()
    private let notifications = NotificationManager()
    private var hasStarted = false
    private var syncTask: Task<Void, Never>?
    private weak var authStore: AuthStore?
    private var activeAccountID: String = UserDefaults.standard.string(forKey: "activeAccountID") ?? "anonymous"
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
            .filter { !showingToday || $0.occurs(on: .now) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var todoItems: [ChecklistItem] {
        visibleItems.filter { !$0.isComplete(on: .now) }
    }

    var completedItems: [ChecklistItem] {
        visibleItems.filter { $0.isComplete(on: .now) }
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
        let key = DateKey.string(from: .now)
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

    func save(_ item: ChecklistItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let changedFields = Self.changedFields(from: items[index], to: item)
            items[index] = item
            if !changedFields.isEmpty {
                pendingMutations.append(.upsert(item: item, changedFields: changedFields))
            }
        } else {
            items.append(item)
            pendingMutations.append(.upsert(item: item, changedFields: Self.allFields))
        }
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
        "title", "notes", "schedule", "customWeekdays", "reminderMinutes", "createdAt"
    ]

    private static func changedFields(from old: ChecklistItem, to new: ChecklistItem) -> Set<String> {
        var changed: Set<String> = []
        if old.title != new.title { changed.insert("title") }
        if old.notes != new.notes { changed.insert("notes") }
        if old.schedule != new.schedule { changed.insert("schedule") }
        if old.customWeekdays != new.customWeekdays { changed.insert("customWeekdays") }
        if old.reminderMinutes != new.reminderMinutes { changed.insert("reminderMinutes") }
        return changed
    }
}
