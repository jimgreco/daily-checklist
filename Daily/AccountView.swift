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
                        Button(action: googleSignIn) {
                            Label("Continue with Google", systemImage: "globe")
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                        }
                        .buttonStyle(.bordered)

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
                        .frame(height: 50)

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
