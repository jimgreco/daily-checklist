import SwiftUI
import GoogleSignIn
import UserNotifications

@main
struct RitualCueApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ChecklistStore()
    @StateObject private var authStore = AuthStore()

    init() {
        UNUserNotificationCenter.current().delegate = RitualNotificationDelegate.shared
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
           !clientID.hasPrefix("YOUR_") {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        #if DEBUG
        ScreenshotSeedData.installIfNeeded()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ChecklistView()
                .environmentObject(store)
                .environmentObject(authStore)
                .task {
                    store.connect(to: authStore)
                    await store.start()
                    await authStore.restore()
                    if let userID = authStore.user?.id {
                        store.activateAuthenticatedAccount(userID)
                    }
                    await store.sync(using: authStore)
                }
                .onOpenURL { url in
                    guard url.scheme != "ritualcue" else {
                        store.selectToday()
                        return
                    }
                    GIDSignIn.sharedInstance.handle(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await store.sync(using: authStore)
                        await store.refreshNotificationSchedule()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .ritualNotificationAction)) { notification in
                    guard let rawID = notification.userInfo?["itemID"] as? String,
                          let itemID = UUID(uuidString: rawID),
                          let action = notification.userInfo?["action"] as? String else { return }
                    let occurrenceID = notification.userInfo?["occurrenceID"] as? String
                    let occurrenceKey = occurrenceID
                        .flatMap { ChecklistOccurrenceIdentifier.scheduledDateKey(from: $0, itemID: itemID) }
                        ?? (notification.userInfo?["occurrenceDate"] as? String)
                    let date = occurrenceKey.flatMap(DateKey.date(from:)) ?? Date()
                    let isCarryover = notification.userInfo?["isCarryover"] as? Bool ?? false
                    switch action {
                    case RitualNotificationAction.complete:
                        if let occurrenceID {
                            store.completeCarryover(
                                itemID: itemID,
                                occurrenceID: occurrenceID,
                                occurrenceDate: date
                            )
                        } else if isCarryover {
                            store.completeCarryover(itemID: itemID, occurrenceDate: date)
                        } else {
                            store.complete(itemID: itemID, on: date)
                        }
                    case RitualNotificationAction.skip:
                        if let occurrenceID {
                            store.skipCarryover(
                                itemID: itemID,
                                occurrenceID: occurrenceID,
                                occurrenceDate: date
                            )
                        } else if isCarryover {
                            store.skipCarryover(itemID: itemID, occurrenceDate: date)
                        } else {
                            store.skip(itemID: itemID, on: date)
                        }
                    case RitualNotificationAction.snooze,
                         RitualNotificationAction.snooze60:
                        store.snooze(
                            itemID: itemID,
                            occurrenceDate: date,
                            occurrenceID: occurrenceID,
                            isCarryover: isCarryover,
                            preset: .oneHour
                        )
                    case RitualNotificationAction.snooze15:
                        store.snooze(
                            itemID: itemID,
                            occurrenceDate: date,
                            occurrenceID: occurrenceID,
                            isCarryover: isCarryover,
                            preset: .fifteenMinutes
                        )
                    default:
                        break
                    }
                }
        }
    }
}
