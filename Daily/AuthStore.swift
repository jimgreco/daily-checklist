import AuthenticationServices
import Foundation
import Security

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var user: AppUser?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let api = APIClient()

    var isAuthenticated: Bool { user != nil && accessToken != nil }
    var accessToken: String? { KeychainStore.read("accessToken") }
    private var refreshToken: String? { KeychainStore.read("refreshToken") }

    func restore() async {
        guard accessToken != nil || refreshToken != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let accessToken {
                user = try await api.currentUser(token: accessToken)
                return
            }
        } catch {}
        await refreshSession()
    }

    func signInWithGoogle(idToken: String) async {
        await authenticate { try await api.signInWithGoogle(idToken: idToken) }
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
        user = nil
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
        do {
            complete(try await api.refresh(refreshToken: refreshToken))
        } catch {
            signOut()
        }
    }

    private func complete(_ response: AuthResponse) {
        KeychainStore.write(response.token, key: "accessToken")
        KeychainStore.write(response.refreshToken, key: "refreshToken")
        user = response.user
    }
}

private enum KeychainStore {
    static func write(_ value: String, key: String) {
        delete(key)
        let data = Data(value.utf8)
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "Daily",
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "Daily",
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
            kSecAttrService: Bundle.main.bundleIdentifier ?? "Daily",
            kSecAttrAccount: key
        ] as CFDictionary)
    }
}
