import AuthenticationServices
import GoogleSignIn
import SwiftUI

struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var store: ChecklistStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: authStore.isAuthenticated ? "checkmark.icloud.fill" : "icloud")
                    .font(.system(size: 58, weight: .medium))
                    .foregroundStyle(accent)

                if let user = authStore.user {
                    VStack(spacing: 6) {
                        Text("Synced")
                            .font(.title.bold())
                        Text(user.email)
                            .foregroundStyle(.secondary)
                        Text(store.syncState)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Button("Sync now") {
                        Task { await store.sync(using: authStore) }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Sign out", role: .destructive) {
                        authStore.signOut()
                        store.activateAnonymousAccount()
                    }
                } else {
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

                        ProviderSignInButton(provider: .apple) {}
                            .accessibilityHidden(true)
                            .overlay {
                                SignInWithAppleButton(.continue) { request in
                                    request.requestedScopes = [.fullName, .email]
                                } onCompletion: { result in
                                    guard case .success(let authorization) = result,
                                          let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                                        return
                                    }
                                    Task {
                                        await authStore.signInWithApple(credential)
                                        if let userID = authStore.user?.id {
                                            store.activateAuthenticatedAccount(userID)
                                        }
                                        await store.sync(using: authStore)
                                    }
                                }
                                .signInWithAppleButtonStyle(.black)
                                .opacity(0.01)
                            }
                            .accessibilityLabel("Continue with Apple")

                        #if DEBUG
                        Button("Local development sign in") {
                            Task {
                                await authStore.devSignIn()
                                if let userID = authStore.user?.id {
                                    store.activateAuthenticatedAccount(userID)
                                }
                                await store.sync(using: authStore)
                            }
                        }
                        .font(.footnote.weight(.semibold))
                        #endif
                    }
                    .padding(.horizontal, 30)
                }

                if let error = authStore.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            }
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
        }
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
            Task { @MainActor in
                await authStore.signInWithGoogle(idToken: token)
                if let userID = authStore.user?.id {
                    store.activateAuthenticatedAccount(userID)
                }
                await store.sync(using: authStore)
            }
        }
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
