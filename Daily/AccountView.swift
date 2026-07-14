import AuthenticationServices
import GoogleSignIn
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct AccountView: View {
    let onShowTutorial: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var store: ChecklistStore
    @State private var showingDeleteConfirmation = false
    @State private var accountMessage: String?
    @State private var reminderEnabled = true
    @State private var reminderTime = Date.now
    @State private var showingImportPicker = false
    @State private var showingImportConfirmation = false
    @State private var pendingImportData: Data?
    @State private var showingRoutineInsights = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let user = authStore.user {
                        signedInHeader(user)
                        notificationCard
                        syncCard
                        insightsCard
                        accountActions
                    } else {
                        signedOutContent
                        insightsCard
                        tutorialCard
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

                    Text(BuildInformation.displayText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
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
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false,
                onCompletion: handleImportSelection
            )
            .sheet(isPresented: $showingRoutineInsights) {
                RoutineInsightsView()
                    .environmentObject(store)
            }
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
            .confirmationDialog(
                "Restore from Export?",
                isPresented: $showingImportConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Export", role: .destructive) {
                    restorePendingImport()
                }
                Button("Cancel", role: .cancel) {
                    pendingImportData = nil
                }
            } message: {
                Text("This replaces the synced checklist data on this account with the selected Ritual Cue export.")
            }
        }
    }

    private func signedInHeader(_ user: AppUser) -> some View {
        VStack(spacing: 12) {
            AccountProfileImage(url: user.profileImageURL)
            VStack(spacing: 4) {
                Text(user.name.isEmpty ? "Ritual Cue account" : user.name)
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
                notificationGroupFilterControls
            }
            Text("Ritual Cue will tell you how many scheduled tasks are still unfinished.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var notificationGroupFilterControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check-in groups")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Check-in groups", selection: notificationFilterModeBinding) {
                ForEach(NotificationGroupFilter.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if store.notificationGroupFilter.mode != .all {
                if store.orderedGroups.isEmpty {
                    Text("No groups yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.orderedGroups.enumerated()), id: \.element.id) { index, group in
                            Toggle(isOn: notificationGroupBinding(for: group)) {
                                Text(group.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(ink)
                            }
                            .padding(.vertical, 8)
                            if index < store.orderedGroups.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
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
            Divider().padding(.leading, 48)
            AccountActionRow(
                title: "Restore from export",
                subtitle: "Replace synced data with a JSON backup",
                systemImage: "square.and.arrow.up"
            ) {
                showingImportPicker = true
            }
        }
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var accountActions: some View {
        VStack(spacing: 0) {
            AccountActionRow(title: "Run tutorial again", subtitle: "Review the basics and starter routines", systemImage: "graduationcap") {
                onShowTutorial()
            }
            Divider().padding(.leading, 48)
            AccountActionRow(title: "Copy diagnostics", subtitle: "Copy build and sync details for support", systemImage: "doc.on.clipboard") {
                copyDiagnostics()
            }
            Divider().padding(.leading, 48)
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

    private var insightsCard: some View {
        VStack(spacing: 0) {
            AccountActionRow(
                title: "Routine insights",
                subtitle: "Private patterns from your last 21 days",
                systemImage: "chart.line.uptrend.xyaxis"
            ) {
                showingRoutineInsights = true
            }
        }
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var tutorialCard: some View {
        VStack(spacing: 0) {
            AccountActionRow(title: "Run tutorial again", subtitle: "Review the basics and starter routines", systemImage: "graduationcap") {
                onShowTutorial()
            }
            Divider().padding(.leading, 48)
            AccountActionRow(title: "Copy diagnostics", subtitle: "Copy build and device details for support", systemImage: "doc.on.clipboard") {
                copyDiagnostics()
            }
            Divider().padding(.leading, 48)
            AccountActionRow(title: "Support", subtitle: nil, systemImage: "questionmark.circle") {
                if let url = URL(string: "https://ritualcue.com/support.html") {
                    openURL(url)
                }
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
                Text("Keep routines backed up")
                    .font(.title2.bold())
                Text("Ritual Cue works offline first. Sign in when you want routine changes backed up and shared across devices.")
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

    private var notificationFilterModeBinding: Binding<NotificationGroupFilter.Mode> {
        Binding(
            get: { store.notificationGroupFilter.mode },
            set: { mode in
                let groupIDs = Set(store.orderedGroups.map(\.id))
                let existing = store.notificationGroupFilter.groupIDs.intersection(groupIDs)
                let selected: Set<UUID>
                switch mode {
                case .all:
                    selected = []
                case .include:
                    selected = existing.isEmpty ? groupIDs : existing
                case .exclude:
                    selected = existing
                }
                store.updateNotificationGroupFilter(NotificationGroupFilter(mode: mode, groupIDs: selected))
            }
        )
    }

    private func notificationGroupBinding(for group: ChecklistGroup) -> Binding<Bool> {
        Binding(
            get: { store.notificationGroupFilter.groupIDs.contains(group.id) },
            set: { isSelected in
                var selected = store.notificationGroupFilter.groupIDs
                if isSelected {
                    selected.insert(group.id)
                } else {
                    selected.remove(group.id)
                }
                store.updateNotificationGroupFilter(NotificationGroupFilter(
                    mode: store.notificationGroupFilter.mode,
                    groupIDs: selected
                ))
            }
        )
    }

    private func saveReminderTime() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        store.updateEveningReminder((parts.hour ?? 20) * 60 + (parts.minute ?? 0))
    }

    private func copyDiagnostics() {
        UIPasteboard.general.string = SupportDiagnostics.text(
            user: authStore.user,
            syncState: store.syncState,
            pendingMutationCount: store.pendingMutationCount,
            deviceID: store.diagnosticDeviceID
        )
        accountMessage = "Diagnostics copied."
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 2_000_000 else {
                    authStore.errorMessage = "That export file is too large."
                    return
                }
                pendingImportData = data
                showingImportConfirmation = true
            } catch {
                authStore.errorMessage = "Unable to read that export file."
            }
        case .failure:
            authStore.errorMessage = "Unable to read that export file."
        }
    }

    private func restorePendingImport() {
        guard let data = pendingImportData else { return }
        Task {
            if let response = await authStore.importData(data) {
                store.applyImportedState(response)
                pendingImportData = nil
                accountMessage = "Export restored."
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

private struct RoutineInsightsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ChecklistStore

    private var summary: RoutineInsightSummary {
        store.routineInsights()
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Calculated on this device from your last 21 days, excluding today. Nothing is sent to an analytics service.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if summary.hasEnoughData {
                        completionCard
                        LazyVGrid(columns: columns, spacing: 12) {
                            InsightCard(
                                title: "Current streak",
                                value: streakValue,
                                detail: streakDetail,
                                systemImage: "flame.fill",
                                color: success
                            )
                            InsightCard(
                                title: "7-day trend",
                                value: trendValue,
                                detail: trendDetail,
                                systemImage: "chart.line.uptrend.xyaxis",
                                color: accent
                            )
                            InsightCard(
                                title: "Missed pattern",
                                value: missedValue,
                                detail: missedDetail,
                                systemImage: "calendar.badge.exclamationmark",
                                color: Color(red: 0.72, green: 0.22, blue: 0.20)
                            )
                            InsightCard(
                                title: "Longest delay",
                                value: delayValue,
                                detail: delayDetail,
                                systemImage: "arrow.right.circle.fill",
                                color: delayed
                            )
                        }
                    } else {
                        lowDataCard
                    }
                }
                .padding(20)
            }
            .background(canvas.ignoresSafeArea())
            .navigationTitle("Routine insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var completionCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(accent.opacity(0.14), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: Double(summary.completionPercentage) / 100)
                    .stroke(accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(summary.completionPercentage)%")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
            }
            .frame(width: 92, height: 92)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(summary.completionPercentage) percent completion")

            VStack(alignment: .leading, spacing: 5) {
                Text("Completion")
                    .font(.headline)
                    .foregroundStyle(ink)
                Text("\(summary.completedCheckIns) of \(summary.expectedCheckIns) scheduled check-ins finished")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if summary.lateCompletedCheckIns > 0 {
                    Text("\(summary.lateCompletedCheckIns) completed after the original due date")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(delayed)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var lowDataCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(accent)
            Text("Your patterns will appear here")
                .font(.title3.bold())
                .foregroundStyle(ink)
            Text("Keep using your checklist normally. Insights begin after three scheduled check-ins have finished or passed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 42)
        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var streakValue: String {
        guard let streak = summary.currentStreak else { return "None yet" }
        return "\(streak.count) \(streak.count == 1 ? "day" : "days")"
    }

    private var streakDetail: String {
        summary.currentStreak?.title ?? "A completed run will show here."
    }

    private var trendValue: String {
        guard let trend = summary.trendPercentagePoints else { return "Building" }
        if trend == 0 { return "Steady" }
        return "\(trend > 0 ? "+" : "")\(trend) pts"
    }

    private var trendDetail: String {
        summary.trendPercentagePoints == nil
            ? "A little more history is needed."
            : "Last 7 days compared with the prior 7."
    }

    private var missedValue: String {
        summary.missedWeekday ?? "No repeat"
    }

    private var missedDetail: String {
        guard summary.missedWeekday != nil else { return "No weekday stands out yet." }
        return "\(summary.missedWeekdayCount) open or missed check-ins"
    }

    private var delayValue: String {
        summary.longestDelay?.title ?? "None"
    }

    private var delayDetail: String {
        guard let delay = summary.longestDelay else { return "No delayed routine in this window." }
        return "Moved forward \(delay.count) \(delay.count == 1 ? "day" : "days")"
    }
}

private struct InsightCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .padding(15)
        .background(surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
