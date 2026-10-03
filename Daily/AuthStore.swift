import AuthenticationServices
import Foundation
import Security

@MainActor
final class AuthStore: ObservableObject, ChecklistSessionProvider {
    @Published private(set) var user: AppUser?
    @Published private(set) var isLoading = false
    @Published private(set) var requiresReauthentication = false
    @Published var errorMessage: String?

    private let api = APIClient()
    private let cachedUserKey = "cachedAuthUser"
    private var refreshTask: Task<AuthResponse, Error>?
    private(set) var sessionGeneration = UUID()

    var isAuthenticated: Bool { user != nil && (accessToken != nil || refreshToken != nil) }
    var accessToken: String? { KeychainStore.read("accessToken") }
    private var refreshToken: String? { KeychainStore.read("refreshToken") }

    func restore() async {
        let generation = sessionGeneration
        if let cachedUser {
            user = cachedUser
        }
        guard accessToken != nil || refreshToken != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let accessToken {
                let restoredUser = try await api.currentUser(token: accessToken)
                guard sessionGeneration == generation else { return }
                user = restoredUser
                cache(restoredUser)
                return
            }
        } catch {}
        guard sessionGeneration == generation else { return }
        await refreshSession()
    }

    func signInWithGoogle(idToken: String, profileImageURL: URL?) async {
        await authenticate { try await api.signInWithGoogle(idToken: idToken, profileImageURL: profileImageURL) }
    }

    func signInWithApple(_ credential: ASAuthorizationAppleIDCredential) async {
        guard let data = credential.identityToken,
              let token = String(data: data, encoding: .utf8) else {
            errorMessage = "Apple did not return an identity token."
            return
        }
        await authenticate {
            try await api.signInWithApple(identityToken: token, fullName: credential.fullName)
        }
    }

    #if DEBUG
    func devSignIn() async {
        await authenticate { try await api.devSignIn() }
    }
    #endif

    func validAccessToken() async -> String? {
        if let accessToken { return accessToken }
        await refreshSession()
        return accessToken
    }

    func refreshAccessToken() async -> String? {
        KeychainStore.delete("accessToken")
        await refreshSession()
        return accessToken
    }

    func signOut() {
        invalidatePendingAuthentication()
        KeychainStore.delete("accessToken")
        KeychainStore.delete("refreshToken")
        UserDefaults.standard.removeObject(forKey: cachedUserKey)
        user = nil
        requiresReauthentication = false
        errorMessage = nil
    }

    func dismissReauthenticationPrompt() {
        requiresReauthentication = false
    }

    func exportData() async -> String? {
        let generation = sessionGeneration
        guard let token = await validAccessToken() else {
            guard sessionGeneration == generation else { return nil }
            errorMessage = "Sign in again to export your data."
            return nil
        }
        guard sessionGeneration == generation else { return nil }
        do {
            let data = try await api.exportData(token: token)
            guard sessionGeneration == generation else { return nil }
            errorMessage = nil
            return String(data: data, encoding: .utf8)
        } catch {
            guard sessionGeneration == generation else { return nil }
            errorMessage = "Unable to export your data. Try again later."
            return nil
        }
    }

    func importData(_ data: Data) async -> SyncResponse? {
        let generation = sessionGeneration
        guard let token = await validAccessToken() else {
            guard sessionGeneration == generation else { return nil }
            errorMessage = "Sign in again to restore your data."
            return nil
        }
        guard sessionGeneration == generation else { return nil }
        do {
            let response = try await importData(data, token: token)
            guard sessionGeneration == generation else { return nil }
            errorMessage = nil
            return response
        } catch APIClient.APIError.badResponse(401) {
            guard sessionGeneration == generation else { return nil }
            guard let refreshed = await refreshAccessToken() else {
                guard sessionGeneration == generation else { return nil }
                errorMessage = "Sign in again to restore your data."
                return nil
            }
            guard sessionGeneration == generation else { return nil }
            do {
                let response = try await importData(data, token: refreshed)
                guard sessionGeneration == generation else { return nil }
                errorMessage = nil
                return response
            } catch {
                guard sessionGeneration == generation else { return nil }
                errorMessage = restoreErrorMessage(for: error)
                return nil
            }
        } catch {
            guard sessionGeneration == generation else { return nil }
            errorMessage = restoreErrorMessage(for: error)
            return nil
        }
    }

    func deleteAccount() async -> Bool {
        let generation = sessionGeneration
        guard let token = await validAccessToken() else {
            guard sessionGeneration == generation else { return false }
            errorMessage = "Sign in again to delete your account."
            return false
        }
        guard sessionGeneration == generation else { return false }
        do {
            try await api.deleteAccount(token: token)
            guard sessionGeneration == generation else { return false }
            signOut()
            errorMessage = nil
            return true
        } catch {
            guard sessionGeneration == generation else { return false }
            errorMessage = "Unable to delete your account. Try again later."
            return false
        }
    }

    private func importData(_ data: Data, token: String) async throws -> SyncResponse {
        try await api.importData(data, token: token)
    }

    private func restoreErrorMessage(for error: Error) -> String {
        switch error {
        case APIClient.APIError.badResponse(413):
            return "That export file is too large."
        case APIClient.APIError.badResponse(422):
            return "That file is not a valid Ritual Cue export."
        default:
            return "Unable to restore your data. Try again later."
        }
    }

    private func authenticate(_ operation: () async throws -> AuthResponse) async {
        invalidatePendingAuthentication()
        let generation = sessionGeneration
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await operation()
            guard sessionGeneration == generation else { return }
            complete(response)
            errorMessage = nil
        } catch {
            guard sessionGeneration == generation else { return }
            errorMessage = "Sign in failed. Check the server configuration and try again."
        }
    }

    private func refreshSession() async {
        guard let refreshToken else { return }
        let generation = sessionGeneration
        if let refreshTask {
            do {
                let response = try await refreshTask.value
                guard sessionGeneration == generation else { return }
                complete(response)
            } catch {
                guard sessionGeneration == generation else { return }
                handleRefreshFailure(error)
            }
            return
        }
        let task = Task { try await api.refresh(refreshToken: refreshToken) }
        refreshTask = task
        defer { if sessionGeneration == generation { refreshTask = nil } }
        do {
            let response = try await task.value
            guard sessionGeneration == generation else { return }
            complete(response)
        } catch {
            guard sessionGeneration == generation else { return }
            handleRefreshFailure(error)
        }
    }

    private func invalidatePendingAuthentication() {
        // Cancellation alone cannot prevent an already completed request from
        // restoring credentials after sign-out or a different sign-in.
        sessionGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func handleRefreshFailure(_ error: Error) {
        KeychainStore.delete("accessToken")
        guard case APIClient.APIError.badResponse(401) = error else { return }
        KeychainStore.delete("refreshToken")
        UserDefaults.standard.removeObject(forKey: cachedUserKey)
        user = nil
        requiresReauthentication = true
        errorMessage = "Your session expired. Your routines are still saved on this device. Sign in again to resume backup and syncing."
    }

    private func complete(_ response: AuthResponse) {
        KeychainStore.write(response.token, key: "accessToken")
        KeychainStore.write(response.refreshToken, key: "refreshToken")
        cache(response.user)
        user = response.user
        requiresReauthentication = false
    }

    private var cachedUser: AppUser? {
        guard let data = UserDefaults.standard.data(forKey: cachedUserKey) else { return nil }
        return try? JSONDecoder().decode(AppUser.self, from: data)
    }

    private func cache(_ user: AppUser) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        UserDefaults.standard.set(data, forKey: cachedUserKey)
    }
}

private enum KeychainStore {
    static func write(_ value: String, key: String) {
        delete(key)
        let data = Data(value.utf8)
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "Ritual Cue",
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "Ritual Cue",
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary
        var result: AnyObject?
        guard SecItemCopyMatching(query, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "Ritual Cue",
            kSecAttrAccount: key
        ] as CFDictionary)
    }
}
