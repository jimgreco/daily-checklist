import AuthenticationServices
import GoogleSignIn
import SwiftUI
import UIKit

struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var store: ChecklistStore
    @State private var showingDeleteConfirmation = false
    @State private var accountMessage: String?
    @State private var reminderEnabled = true
    @State private var reminderTime = Date.now

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let user = authStore.user {
                        signedInHeader(user)
                        notificationCard
                        syncCard
                        accountActions
                    } else {
                        signedOutContent
                    }

                    if let error = authStore.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    if let accountMessage {
                        Text(accountMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding(20)
            }
            .background(canvas.ignoresSafeArea())
            .padding()
            .overlay {
                if authStore.isLoading {
                    ProgressView()
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: loadReminderState)
            .confirmationDialog(
                "Delete Account?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    Task {
                        if await authStore.deleteAccount() {
                            store.activateAnonymousAccount()
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your synced checklist data from the server. Local offline copies on other devices may remain until those devices sign out or clear local data.")
            }
        }
    }

    private func signedInHeader(_ user: AppUser) -> some View {
        VStack(spacing: 12) {
            AccountProfileImage(url: user.profileImageURL)
            VStack(spacing: 4) {
                Text(user.name.isEmpty ? "Daily account" : user.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Text(user.email)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Notifications", systemImage: "bell.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(ink)
            Toggle("Evening check-in", isOn: Binding(
                get: { reminderEnabled },
                set: { enabled in
                    reminderEnabled = enabled
                    if enabled {
                        saveReminderTime()
                    } else {
                        store.updateEveningReminder(nil)
                    }
                }
            ))
            if reminderEnabled {
                DatePicker("Alert time", selection: Binding(
                    get: { reminderTime },
                    set: { newTime in
                        reminderTime = newTime
                        saveReminderTime()
                    }
                ), displayedComponents: .hourAndMinute)
            }
            Text("Daily will tell you how many scheduled tasks are still unfinished.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var syncCard: some View {
        VStack(spacing: 0) {
            AccountActionRow(
                title: "Sync now",
                subtitle: store.syncState,
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                Task { await store.sync(using: authStore) }
            }
            Divider().padding(.leading, 48)
            AccountActionRow(
                title: "Copy data export",
                subtitle: "Copy a JSON backup to the clipboard",
                systemImage: "square.and.arrow.down"
            ) {
                Task {
                    if let export = await authStore.exportData() {
                        UIPasteboard.general.string = export
                        accountMessage = "Data export copied."
                    }
                }
            }
        }
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var accountActions: some View {
        VStack(spacing: 0) {
            AccountActionRow(title: "Privacy", subtitle: nil, systemImage: "hand.raised") {
                if let url = URL(string: "https://ritualcue.com/privacy.html") {
                    openURL(url)
                }
            }
            Divider().padding(.leading, 48)
            AccountActionRow(title: "Support", subtitle: nil, systemImage: "questionmark.circle") {
                if let url = URL(string: "https://ritualcue.com/support.html") {
                    openURL(url)
                }
            }
            Divider().padding(.leading, 48)
            AccountActionRow(title: "Sign out", subtitle: nil, systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                authStore.signOut()
                store.activateAnonymousAccount()
            }
            Divider().padding(.leading, 48)
            AccountActionRow(title: "Delete account", subtitle: "Remove synced account data", systemImage: "trash", role: .destructive) {
                showingDeleteConfirmation = true
            }
        }
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var signedOutContent: some View {
        VStack(spacing: 22) {
            Image(systemName: "icloud")
                .font(.system(size: 58, weight: .medium))
                .foregroundStyle(accent)
            VStack(spacing: 8) {
                Text("Keep your checklist in sync")
                    .font(.title2.bold())
                Text("Daily works fully offline. Sign in when you want changes backed up and shared across devices.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            VStack(spacing: 12) {
                ProviderSignInButton(provider: .google, action: googleSignIn)
                    .accessibilityLabel("Continue with Google")

                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                            authStore.errorMessage = "Apple did not return a valid credential."
                            return
                        }
                        Task {
                            await finishSignIn {
                                await authStore.signInWithApple(credential)
                            }
                        }
                    case .failure(let error):
                        authStore.errorMessage = error.localizedDescription
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Continue with Apple")

                #if DEBUG
                Button("Local development sign in") {
                    Task {
                        await finishSignIn {
                            await authStore.devSignIn()
                        }
                    }
                }
                .font(.footnote.weight(.semibold))
                #endif
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 48)
    }

    private func loadReminderState() {
        reminderEnabled = store.eveningReminderMinutes != nil
        let minutes = store.eveningReminderMinutes ?? 20 * 60
        reminderTime = Calendar.current.date(from: DateComponents(hour: minutes / 60, minute: minutes % 60)) ?? .now
    }

    private func saveReminderTime() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        store.updateEveningReminder((parts.hour ?? 20) * 60 + (parts.minute ?? 0))
    }

    private func googleSignIn() {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.hasPrefix("YOUR_") else {
            authStore.errorMessage = "Add this app's Google iOS client ID to project.yml first."
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController else {
            authStore.errorMessage = "Unable to present Google sign in."
            return
        }

        GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
            if let error {
                Task { @MainActor in authStore.errorMessage = error.localizedDescription }
                return
            }
            guard let token = result?.user.idToken?.tokenString else {
                Task { @MainActor in authStore.errorMessage = "Google did not return an identity token." }
                return
            }
            let profileImageURL = result?.user.profile?.imageURL(withDimension: 120)
            Task { @MainActor in
                await finishSignIn {
                    await authStore.signInWithGoogle(idToken: token, profileImageURL: profileImageURL)
                }
            }
        }
    }

    private func finishSignIn(_ signIn: () async -> Void) async {
        await signIn()
        guard authStore.errorMessage == nil, let userID = authStore.user?.id else { return }
        store.activateAuthenticatedAccount(userID)
        let didSync = await store.sync(using: authStore)
        if didSync { dismiss() }
    }
}

private struct AccountProfileImage: View {
    let url: URL?

    var body: some View {
        ZStack {
            Circle().fill(controlSurface)
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(.white.opacity(0.8), lineWidth: 3)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }

    private var fallback: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 62, weight: .semibold))
            .foregroundStyle(accent)
    }
}

private struct AccountActionRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(role == .destructive ? Color.red : accent)
                    .frame(width: 36, height: 36)
                    .background((role == .destructive ? Color.red : accent).opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(role == .destructive ? Color.red : ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProviderSignInButton: View {
    enum Provider {
        case google
        case apple

        var title: String {
            switch self {
            case .google: return "Continue with Google"
            case .apple: return "Continue with Apple"
            }
        }

        var foreground: Color {
            switch self {
            case .google: return Color(red: 0.23, green: 0.23, blue: 0.23)
            case .apple: return .white
            }
        }

        var background: Color {
            switch self {
            case .google: return .white
            case .apple: return .black
            }
        }

        var border: Color {
            switch self {
            case .google: return Color.black.opacity(0.18)
            case .apple: return .black
            }
        }
    }

    let provider: Provider
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                brandMark
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                Text(provider.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(provider.foreground)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(provider.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(provider.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var brandMark: some View {
        switch provider {
        case .google:
            Text("G")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
        case .apple:
            Image(systemName: "apple.logo")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
