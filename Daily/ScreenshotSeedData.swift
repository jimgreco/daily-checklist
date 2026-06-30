#if DEBUG
import Foundation

enum ScreenshotSeedData {
    static let launchArgument = "--app-store-screenshots"

    static var isEnabled: Bool {
        CommandLine.arguments.contains(launchArgument)
            || ProcessInfo.processInfo.environment["APP_STORE_SCREENSHOTS"] == "1"
    }

    static func installIfNeeded() {
        guard isEnabled else { return }

        let defaults = UserDefaults.standard
        defaults.set("anonymous", forKey: "activeAccountID")
        defaults.set(ChecklistSort.manual.rawValue, forKey: "checklistSortMode")

        clearDailyCaches()

        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: .now)
        let createdAt = today
        let todayKey = DateKey.string(from: today)

        let morning = ChecklistGroup(
            id: UUID(uuidString: "B321DAE0-4E8F-4A9B-8E2B-3CB8122FB34C")!,
            name: "Morning",
            sortOrder: 0
        )
        let home = ChecklistGroup(
            id: UUID(uuidString: "39F92F04-70C3-4A45-A79C-D6A9B7F201DA")!,
            name: "Home",
            sortOrder: 1
        )
        let planning = ChecklistGroup(
            id: UUID(uuidString: "A25D8C20-3AC6-475C-A148-7F4F87C11E46")!,
            name: "Planning",
            sortOrder: 2
        )

        let items = [
            ChecklistItem(
                id: UUID(uuidString: "76071C63-2F53-405D-B305-556530F457C7")!,
                title: "Review calendar",
                notes: "Check meetings, errands, and the evening plan.",
                schedule: .everyDay,
                reminderMinutes: 8 * 60,
                createdAt: createdAt,
                groupID: morning.id,
                sortOrder: 0
            ),
            ChecklistItem(
                id: UUID(uuidString: "D8632167-B129-481B-BC5E-07563898F77B")!,
                title: "Take vitamins",
                notes: "With breakfast.",
                schedule: .everyDay,
                reminderMinutes: 8 * 60 + 30,
                completedDates: [todayKey],
                createdAt: createdAt,
                groupID: morning.id,
                sortOrder: 1
            ),
            ChecklistItem(
                id: UUID(uuidString: "61EAF8A9-8AA2-460A-B2E3-948B2B73E7EE")!,
                title: "Water kitchen herbs",
                notes: "Basil and mint dry out first.",
                schedule: .everyDay,
                reminderMinutes: 18 * 60,
                createdAt: createdAt,
                groupID: home.id,
                sortOrder: 0
            ),
            ChecklistItem(
                id: UUID(uuidString: "3C7F5209-270E-4C9C-BA01-7B96717D1768")!,
                title: "Tidy entryway",
                schedule: .weekdays,
                createdAt: createdAt,
                groupID: home.id,
                sortOrder: 1
            ),
            ChecklistItem(
                id: UUID(uuidString: "B32FF774-4D27-4114-9F0D-B4DE7B4F20AB")!,
                title: "Plan weekly reset",
                notes: "Pick one errand and one house task.",
                schedule: .custom,
                customWeekdays: [7],
                reminderMinutes: 10 * 60,
                createdAt: createdAt,
                groupID: planning.id,
                sortOrder: 0
            )
        ]

        let envelope = LocalEnvelope(
            items: items,
            groups: [morning, home, planning],
            eveningReminderMinutes: 20 * 60,
            pendingMutations: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else { return }
        try? data.write(to: URL.documentsDirectory.appending(path: "daily-checklist-anonymous.json"), options: .atomic)
    }

    private static func clearDailyCaches() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: .documentsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("daily-checklist") {
            try? fileManager.removeItem(at: file)
        }
    }
}
#endif
