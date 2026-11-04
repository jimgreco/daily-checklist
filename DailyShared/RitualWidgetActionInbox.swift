import Foundation

/// A tap recorded by the widget. The app applies it through its normal store
/// mutations (and therefore its sync queue) the next time it becomes active.
struct RitualWidgetAction: Codable, Equatable, Identifiable {
    var id: UUID
    var itemID: UUID
    var occurrenceID: String?
    var isCarryover: Bool
    var dateKey: String
    /// The completion count the tap moves the task to. Applying it is idempotent:
    /// a task already at or past this count is left alone.
    var targetCount: Int
    var accountID: String?
    var createdAt: Date

    var taskID: String { occurrenceID ?? itemID.uuidString }
}

enum RitualWidgetActionInbox {
    private static let fileName = "ritual-widget-actions.v1.json"
    /// Taps older than this are dropped rather than applied to a stale day.
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static var defaultURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: RitualWidgetSnapshotStore.appGroupIdentifier)?
            .appending(path: fileName)
    }

    static func load(from url: URL? = defaultURL) -> [RitualWidgetAction] {
        guard let url else { return [] }
        var result: [RitualWidgetAction] = []
        coordinate(url: url, writing: false) { coordinatedURL in
            result = read(coordinatedURL)
        }
        return result
    }

    @discardableResult
    static func append(_ action: RitualWidgetAction, to url: URL? = defaultURL) -> Bool {
        guard let url else { return false }
        var succeeded = false
        coordinate(url: url, writing: true) { coordinatedURL in
            var actions = read(coordinatedURL)
            actions.append(action)
            succeeded = write(actions, to: coordinatedURL)
        }
        return succeeded
    }

    /// Removes the given actions while keeping any taps that arrived after they were loaded.
    static func remove(ids: Set<UUID>, from url: URL? = defaultURL) {
        guard let url, !ids.isEmpty else { return }
        coordinate(url: url, writing: true) { coordinatedURL in
            let remaining = read(coordinatedURL).filter { !ids.contains($0.id) }
            _ = write(remaining, to: coordinatedURL)
        }
    }

    private static func coordinate(url: URL, writing: Bool, _ body: (URL) -> Void) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &error, byAccessor: body)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error, byAccessor: body)
        }
    }

    private static func read(_ url: URL) -> [RitualWidgetAction] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RitualWidgetAction].self, from: data)) ?? []
    }

    private static func write(_ actions: [RitualWidgetAction], to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(actions) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
