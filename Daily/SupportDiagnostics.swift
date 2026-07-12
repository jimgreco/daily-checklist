import Foundation

enum BuildInformation {
    static var version: String {
        bundleString("CFBundleShortVersionString", fallback: "1.0")
    }

    static var build: String {
        bundleString("CFBundleVersion", fallback: "0")
    }

    static var gitCommitHash: String {
        bundleString("GitCommitHash")
    }

    static var displayText: String {
        let versionAndBuild = "\(version) (\(build))"
        return gitCommitHash.isEmpty ? versionAndBuild : "\(versionAndBuild) \(gitCommitHash)"
    }

    private static func bundleString(_ key: String, fallback: String = "") -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return fallback
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else {
            return fallback
        }
        return trimmed
    }
}

enum SupportDiagnostics {
    static func text(
        user: AppUser?,
        syncState: String,
        pendingMutationCount: Int,
        deviceID: String,
        apiBaseURL: URL = APIClient.configuredBaseURL,
        generatedAt: Date = Date()
    ) -> String {
        [
            "Ritual Cue Diagnostics",
            "Generated: \(timestamp.string(from: generatedAt))",
            "Surface: iOS",
            "App Version: \(BuildInformation.version)",
            "Build: \(BuildInformation.build)",
            "Git Commit: \(BuildInformation.gitCommitHash.isEmpty ? "unknown" : BuildInformation.gitCommitHash)",
            "Auth State: \(user == nil ? "Signed out" : "Signed in")",
            "User ID: \(user?.id ?? "none")",
            "Device ID: \(deviceID)",
            "API Origin: \(origin(from: apiBaseURL))",
            "Sync State: \(syncState)",
            "Pending Mutations: \(pendingMutationCount)"
        ].joined(separator: "\n")
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func origin(from url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else {
            return url.absoluteString
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
