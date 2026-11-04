import AppIntents
import Foundation
import WidgetKit

/// Backs the checkboxes in the interactive widget. It runs in the widget
/// extension, records the tap in the shared inbox, and reloads the widget; the
/// app applies the tap to the checklist and syncs it when it next becomes active.
struct CompleteRitualTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Off Ritual Task"
    static let description = IntentDescription("Marks progress on a Ritual Cue task from the widget.")
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "Item ID") var itemID: String
    @Parameter(title: "Occurrence ID") var occurrenceID: String
    @Parameter(title: "Carryover") var isCarryover: Bool
    @Parameter(title: "Date") var dateKey: String
    @Parameter(title: "Target count") var targetCount: Int
    @Parameter(title: "Account") var accountID: String

    init() {}

    init(task: RitualWidgetTask, dateKey: String, accountID: String?) {
        self.itemID = task.itemID.uuidString
        self.occurrenceID = task.occurrenceID ?? ""
        self.isCarryover = task.isCarryover
        self.dateKey = dateKey
        self.targetCount = min(task.quantity, task.completionCount + 1)
        self.accountID = accountID ?? ""
    }

    func perform() async throws -> some IntentResult {
        guard let itemUUID = UUID(uuidString: itemID) else { return .result() }
        RitualWidgetActionInbox.append(RitualWidgetAction(
            id: UUID(),
            itemID: itemUUID,
            occurrenceID: occurrenceID.isEmpty ? nil : occurrenceID,
            isCarryover: isCarryover,
            dateKey: dateKey,
            targetCount: targetCount,
            accountID: accountID.isEmpty ? nil : accountID,
            createdAt: .now
        ))
        WidgetCenter.shared.reloadTimelines(ofKind: RitualWidgetSnapshotStore.kind)
        return .result()
    }
}
