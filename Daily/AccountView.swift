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
    @State private var quietHoursEnabled = false
    @State private var quietHoursStart = Date.now
    @State private var quietHoursEnd = Date.now
    @State private var showingImportPicker = false
    @State private var showingImportConfirmation = false
    @State private var pendingImportData: Data?
    @State private var showingRoutineInsights = false

    var body: some View {
        NavigationStack {
            ZStack {
                RitualBackdrop()
                    .ignoresSafeArea()

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
                            RitualInlineMessage(text: error, tone: .danger)
                        }
                        if let accountMessage {
                            RitualInlineMessage(text: accountMessage, tone: .success)
                        }

                        Text(BuildInformation.displayText)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }

                if authStore.isLoading {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Working…")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityElement(children: .combine)
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
        .tint(accent)
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
        .padding(.vertical, 22)
        .background(accentSoft.opacity(0.62), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        }
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            RitualSectionLabel(title: "Notifications", systemImage: "bell.fill")
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
            Divider()
            Toggle("Quiet hours", isOn: Binding(
                get: { quietHoursEnabled },
                set: { enabled in
                    quietHoursEnabled = enabled
                    saveQuietHours()
                }
            ))
            if quietHoursEnabled {
                DatePicker("Quiet from", selection: Binding(
                    get: { quietHoursStart },
                    set: { value in
                        quietHoursStart = value
                        saveQuietHours()
                    }
                ), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: Binding(
                    get: { quietHoursEnd },
                    set: { value in
                        quietHoursEnd = value
                        saveQuietHours()
                    }
                ), displayedComponents: .hourAndMinute)
                Text("Automatic follow-ups stop at the quiet-hours cutoff. Snoozes that land inside quiet hours move to the end time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            notificationSchedulingMessage
            Text("Ritual Cue will tell you how many scheduled tasks are still unfinished.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .ritualCard()
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
                    .padding(.horizontal, 12)
                    .background(softSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private var syncCard: some View {
        VStack(spacing: 0) {
            AccountActionRow(
                title: "Sync now",
                subtitle: store.syncState,
                systemImage: "arrow.triangle.2.circlepath",
                showsChevron: false
            ) {
                Task { await store.sync(using: authStore) }
            }
            Divider().padding(.leading, 48)
            AccountActionRow(
                title: "Copy data export",
                subtitle: "Copy a JSON backup to the clipboard",
                systemImage: "square.and.arrow.down",
                showsChevron: false
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
        .ritualCard()
    }

    private var accountActions: some View {
        VStack(spacing: 0) {
            AccountActionRow(title: "Run tutorial again", subtitle: "Review the basics and starter routines", systemImage: "graduationcap") {
                onShowTutorial()
            }
            Divider().padding(.leading, 48)
            AccountActionRow(title: "Copy diagnostics", subtitle: "Copy build and sync details for support", systemImage: "doc.on.clipboard", showsChevron: false) {
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
            AccountActionRow(title: "Sign out", subtitle: nil, systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, showsChevron: false) {
                authStore.signOut()
                store.activateAnonymousAccount()
            }
            Divider().padding(.leading, 48)
            AccountActionRow(title: "Delete account", subtitle: "Remove synced account data", systemImage: "trash", role: .destructive, showsChevron: false) {
                showingDeleteConfirmation = true
            }
        }
        .ritualCard()
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
        .ritualCard()
    }

    private var tutorialCard: some View {
        VStack(spacing: 0) {
            AccountActionRow(title: "Run tutorial again", subtitle: "Review the basics and starter routines", systemImage: "graduationcap") {
                onShowTutorial()
            }
            Divider().padding(.leading, 48)
            AccountActionRow(title: "Copy diagnostics", subtitle: "Copy build and device details for support", systemImage: "doc.on.clipboard", showsChevron: false) {
                copyDiagnostics()
            }
            Divider().padding(.leading, 48)
            AccountActionRow(title: "Support", subtitle: nil, systemImage: "questionmark.circle") {
                if let url = URL(string: "https://ritualcue.com/support.html") {
                    openURL(url)
                }
            }
        }
        .ritualCard()
    }

    private var signedOutContent: some View {
        VStack(spacing: 22) {
            Image(systemName: "icloud")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 92, height: 92)
                .background(accentSoft, in: Circle())
                .overlay {
                    Circle().stroke(accent.opacity(0.18), lineWidth: 1)
                }
            VStack(spacing: 8) {
                Text("Keep routines backed up")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(ink)
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
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        }
        .padding(24)
        .ritualCard(cornerRadius: 30, elevated: true)
    }

    private func loadReminderState() {
        reminderEnabled = store.eveningReminderMinutes != nil
        let minutes = store.eveningReminderMinutes ?? 20 * 60
        reminderTime = Calendar.current.date(from: DateComponents(hour: minutes / 60, minute: minutes % 60)) ?? .now
        let quietHours = store.notificationQuietHours ?? .standard
        quietHoursEnabled = store.notificationQuietHours != nil
        quietHoursStart = Calendar.current.date(from: DateComponents(
            hour: quietHours.startMinutes / 60,
            minute: quietHours.startMinutes % 60
        )) ?? .now
        quietHoursEnd = Calendar.current.date(from: DateComponents(
            hour: quietHours.endMinutes / 60,
            minute: quietHours.endMinutes % 60
        )) ?? .now
    }

    @ViewBuilder
    private var notificationSchedulingMessage: some View {
        switch store.notificationSchedulingStatus.permission {
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Notifications are disabled for Ritual Cue.", systemImage: "bell.slash.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(dangerColor)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(dangerColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(dangerColor.opacity(0.18), lineWidth: 1)
            }
        case .authorized, .provisional, .ephemeral:
            if store.notificationSchedulingStatus.isCapacityConstrained {
                RitualInlineMessage(
                    text: "The iOS pending-notification limit left \(store.notificationSchedulingStatus.droppedCount) later reminder(s) unscheduled. Nearer reminders were kept first.",
                    tone: .warning
                )
            }
        case .unknown, .notDetermined:
            EmptyView()
        }
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

    private func saveQuietHours() {
        guard quietHoursEnabled else {
            store.updateNotificationQuietHours(nil)
            return
        }
        let start = Calendar.current.dateComponents([.hour, .minute], from: quietHoursStart)
        let end = Calendar.current.dateComponents([.hour, .minute], from: quietHoursEnd)
        store.updateNotificationQuietHours(NotificationQuietHours(
            startMinutes: (start.hour ?? 22) * 60 + (start.minute ?? 0),
            endMinutes: (end.hour ?? 7) * 60 + (end.minute ?? 0)
        ))
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: ChecklistStore

    private var summary: RoutineInsightSummary {
        store.routineInsights()
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RitualInlineMessage(
                        text: "Calculated on this device from your last 21 days, excluding today. Nothing is sent to an analytics service."
                    )

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
                                color: dangerColor
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
            .background {
                RitualBackdrop()
                    .ignoresSafeArea()
            }
            .navigationTitle("Routine insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(accent)
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
        .ritualCard(elevated: true)
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
        .ritualCard(elevated: true)
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
                .frame(width: 38, height: 38)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .ritualCard(cornerRadius: 20)
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
            Circle()
                .strokeBorder(surface, lineWidth: 4)
                .overlay {
                    Circle().stroke(accent.opacity(0.26), lineWidth: 1)
                }
        }
        .shadow(color: accent.opacity(0.14), radius: 18, y: 8)
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
    var showsChevron = true
    let action: () -> Void

    var body: some View {
        let rowColor = role == .destructive ? dangerColor : accent

        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(rowColor)
                    .frame(width: 38, height: 38)
                    .background(rowColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(rowColor.opacity(0.14), lineWidth: 1)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(role == .destructive ? dangerColor : ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
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
            .frame(height: 52)
            .background(provider.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
