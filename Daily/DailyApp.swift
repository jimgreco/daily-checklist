import SwiftUI
import GoogleSignIn
import UserNotifications

@main
struct DailyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ChecklistStore()
    @StateObject private var authStore = AuthStore()

    init() {
        UNUserNotificationCenter.current().delegate = DailyNotificationDelegate.shared
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
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await store.sync(using: authStore) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .dailyNotificationAction)) { notification in
                    guard let rawID = notification.userInfo?["itemID"] as? String,
                          let itemID = UUID(uuidString: rawID),
                          let action = notification.userInfo?["action"] as? String else { return }
                    let date = (notification.userInfo?["date"] as? String)
                        .flatMap(DateKey.date(from:)) ?? Date()
                    switch action {
                    case DailyNotificationAction.complete:
                        store.complete(itemID: itemID, on: date)
                    case DailyNotificationAction.skip:
                        store.skip(itemID: itemID, on: date)
                    case DailyNotificationAction.snooze:
                        store.snooze(itemID: itemID)
                    default:
                        break
                    }
                }
        }
    }
}
