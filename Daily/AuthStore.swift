import AuthenticationServices
import Foundation
import Security

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var user: AppUser?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let api = APIClient()
    private let cachedUserKey = "cachedAuthUser"
    private var refreshTask: Task<AuthResponse, Error>?

    var isAuthenticated: Bool { user != nil && (accessToken != nil || refreshToken != nil) }
    var accessToken: String? { KeychainStore.read("accessToken") }
    private var refreshToken: String? { KeychainStore.read("refreshToken") }

    func restore() async {
        if let cachedUser {
            user = cachedUser
        }
        guard accessToken != nil || refreshToken != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let accessToken {
                let restoredUser = try await api.currentUser(token: accessToken)
                user = restoredUser
                cache(restoredUser)
                return
            }
        } catch {}
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
        KeychainStore.delete("accessToken")
        KeychainStore.delete("refreshToken")
        UserDefaults.standard.removeObject(forKey: cachedUserKey)
        user = nil
    }

    func exportData() async -> String? {
        guard let token = await validAccessToken() else {
            errorMessage = "Sign in again to export your data."
            return nil
        }
        do {
            let data = try await api.exportData(token: token)
            errorMessage = nil
            return String(data: data, encoding: .utf8)
        } catch {
            errorMessage = "Unable to export your data. Try again later."
            return nil
        }
    }

    func deleteAccount() async -> Bool {
        guard let token = await validAccessToken() else {
            errorMessage = "Sign in again to delete your account."
            return false
        }
        do {
            try await api.deleteAccount(token: token)
            signOut()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Unable to delete your account. Try again later."
            return false
        }
    }

    private func authenticate(_ operation: () async throws -> AuthResponse) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await operation()
            complete(response)
            errorMessage = nil
        } catch {
            errorMessage = "Sign in failed. Check the server configuration and try again."
        }
    }

    private func refreshSession() async {
        guard let refreshToken else { return }
        if let refreshTask {
            do {
                complete(try await refreshTask.value)
            } catch {
                KeychainStore.delete("accessToken")
            }
            return
        }
        let task = Task { try await api.refresh(refreshToken: refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            complete(try await task.value)
        } catch {
            KeychainStore.delete("accessToken")
        }
    }

    private func complete(_ response: AuthResponse) {
        KeychainStore.write(response.token, key: "accessToken")
        KeychainStore.write(response.refreshToken, key: "refreshToken")
        cache(response.user)
        user = response.user
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
