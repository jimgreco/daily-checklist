import SwiftUI
import GoogleSignIn

@main
struct DailyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ChecklistStore()
    @StateObject private var authStore = AuthStore()

    init() {
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
           !clientID.hasPrefix("YOUR_") {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
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
        }
    }
}
