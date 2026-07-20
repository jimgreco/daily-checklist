import SwiftUI
import UIKit
import UniformTypeIdentifiers

private func adaptiveColor(
    light: (Double, Double, Double),
    dark: (Double, Double, Double)
) -> Color {
    Color(uiColor: UIColor { traits in
        let values = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: values.0, green: values.1, blue: values.2, alpha: 1)
    })
}

let ink = adaptiveColor(light: (0.10, 0.12, 0.16), dark: (0.94, 0.95, 0.98))
let accent = adaptiveColor(light: (0.38, 0.33, 0.92), dark: (0.56, 0.51, 1.00))
let canvas = adaptiveColor(light: (0.965, 0.958, 0.94), dark: (0.055, 0.060, 0.072))
let surface = adaptiveColor(light: (1.00, 1.00, 1.00), dark: (0.13, 0.14, 0.16))
let softSurface = adaptiveColor(light: (0.985, 0.982, 0.965), dark: (0.10, 0.11, 0.13))
let controlSurface = adaptiveColor(light: (1.00, 1.00, 1.00), dark: (0.18, 0.19, 0.22))
let subtleFill = adaptiveColor(light: (0.91, 0.90, 0.87), dark: (0.19, 0.20, 0.23))
let success = adaptiveColor(light: (0.12, 0.52, 0.29), dark: (0.34, 0.84, 0.50))
let delayed = adaptiveColor(light: (0.72, 0.43, 0.05), dark: (1.00, 0.72, 0.28))

struct ChecklistView: View {
    @EnvironmentObject private var store: ChecklistStore
    @EnvironmentObject private var authStore: AuthStore
    @State private var editingItem: ChecklistItem?
    @State private var showingNewItem = false
    @State private var showingAccount = false
    @State private var searchText = ""
    @State private var historyItem: ChecklistItem?
    @State private var isEditingChecklist = false
    @State private var draggingItemID: UUID?
    @State private var draggingGroupID: UUID?
    @State private var renamingGroupID: UUID?
    @State private var renameGroupName = ""
    @State private var deletingGroup: ChecklistGroup?
    @State private var permanentlyDeletingItem: ChecklistItem?
    @State private var endingItemWithCarryover: ChecklistItem?
    @State private var editedItemEndingWithCarryover: ChecklistItem?
    @State private var endingGroupWithCarryovers: UUID?
    @State private var actionErrorMessage: String?
    @State private var isSearchPresented = false
    @State private var showingTutorial = false
    @AppStorage("hasSeenChecklistTutorial") private var hasSeenChecklistTutorial = false
    @FocusState private var searchIsFocused: Bool
    @Namespace private var searchGlassNamespace

    var body: some View {
        NavigationStack {
            GlassEffectContainer(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    canvas.ignoresSafeArea()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            header
                            filter
                                .padding(.top, 22)
                            if store.scope == .archive {
                                section(
                                    title: "ARCHIVE",
                                    items: filtered(store.visibleItems),
                                    emptyText: "No ended tasks",
                                    showsCompleteAll: false,
                                    isCompletedSection: false,
                                    allowsPermanentDelete: true
                                )
                                    .padding(.top, 28)
                            } else {
                                if showsStillOpenSection {
                                    stillOpenSection
                                        .padding(.top, 28)
                                }
                                section(
                                    title: "TO DO",
                                    items: filtered(todoSectionItems),
                                    emptyText: "Nothing left for now",
                                    showsCompleteAll: store.scope == .today && !filtered(store.todoItems).isEmpty,
                                    isCompletedSection: false,
                                    displayCount: store.scope == .today
                                        ? filtered(store.todoItems).count
                                        : filtered(todoSectionItems).count
                                )
                                    .padding(.top, showsStillOpenSection ? 24 : 28)
                                if store.scope == .today {
                                    section(
                                        title: "SKIPPED",
                                        items: filtered(store.skippedItems),
                                        emptyText: nil,
                                        showsCompleteAll: false,
                                        isCompletedSection: false
                                    )
                                        .padding(.top, 32)
                                        .opacity(filtered(store.skippedItems).isEmpty ? 0 : 1)
                                }
                                section(
                                    title: "COMPLETED",
                                    items: filtered(completedSectionItems),
                                    emptyText: nil,
                                    isCompletedSection: true
                                )
                                    .padding(.top, 32)
                                    .opacity(filtered(completedSectionItems).isEmpty ? 0 : 1)
                            }
                            Spacer(minLength: 120)
                        }
                        .padding(.horizontal, 20)
                    }

                    Button {
                        showingNewItem = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(accent, in: Circle())
                            .shadow(color: accent.opacity(0.3), radius: 18, y: 8)
                    }
                    .accessibilityLabel("Add item")
                    .padding(24)
                }
                .overlay {
                    if isSearchPresented {
                        Color.clear
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .onTapGesture {
                                dismissSearch()
                            }
                            .zIndex(4)
                    }
                }
                .overlay(alignment: .top) {
                    if isSearchPresented {
                        expandedSearchOverlay
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(5)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingNewItem) {
                ItemEditor(
                    item: newItemTemplate,
                    groups: store.orderedGroups,
                    onSave: { store.save($0) },
                    onCreateGroup: { store.createGroup(named: $0) }
                )
            }
            .sheet(item: $editingItem) { item in
                ItemEditor(
                    item: item,
                    groups: store.orderedGroups,
                    onSave: { updatedItem in
                        let endDateChanged = updatedItem.endedAt != item.endedAt
                        if endDateChanged,
                           updatedItem.endedAt != nil,
                           store.unresolvedCarryoverEntry(for: item.id) != nil {
                            editedItemEndingWithCarryover = updatedItem
                        } else {
                            store.save(updatedItem)
                        }
                    },
                    onCreateGroup: { store.createGroup(named: $0) },
                    onDelete: requestEnd
                )
            }
            .sheet(item: $historyItem) { item in
                ItemHistoryView(item: item)
            }
            .sheet(isPresented: $showingAccount) {
                AccountView(onShowTutorial: showTutorialFromAccount)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingTutorial) {
                ChecklistTutorialView(
                    createSamples: {
                        store.applyBuiltInTemplates()
                        finishTutorial()
                    },
                    startEmpty: finishTutorial
                )
                .interactiveDismissDisabled()
            }
            .alert("Rename Group", isPresented: Binding(
                get: { renamingGroupID != nil },
                set: { if !$0 { renamingGroupID = nil } }
            )) {
                TextField("Group name", text: $renameGroupName)
                Button("Cancel", role: .cancel) {
                    renamingGroupID = nil
                }
                Button("Save") {
                    if let renamingGroupID {
                        _ = store.renameGroup(renamingGroupID, to: renameGroupName)
                    }
                    renamingGroupID = nil
                }
                .disabled(renameGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Update this group name on every signed-in device.")
            }
            .confirmationDialog(
                "Delete Group?",
                isPresented: Binding(
                    get: { deletingGroup != nil },
                    set: { if !$0 { deletingGroup = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Group", role: .destructive) {
                    if let deletingGroup {
                        _ = store.deleteGroup(deletingGroup.id)
                    }
                    deletingGroup = nil
                }
                Button("Cancel", role: .cancel) {
                    deletingGroup = nil
                }
            } message: {
                Text("Only the empty group is removed. Tasks are not deleted.")
            }
            .confirmationDialog(
                "Delete Archived Item?",
                isPresented: Binding(
                    get: { permanentlyDeletingItem != nil },
                    set: { if !$0 { permanentlyDeletingItem = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    if let permanentlyDeletingItem {
                        store.permanentlyDelete(permanentlyDeletingItem)
                    }
                    permanentlyDeletingItem = nil
                }
                Button("Cancel", role: .cancel) {
                    permanentlyDeletingItem = nil
                }
            } message: {
                Text("This removes the archived item from every synced device.")
            }
            .confirmationDialog(
                "Handle Still Open Task?",
                isPresented: Binding(
                    get: { endingItemWithCarryover != nil },
                    set: { if !$0 { endingItemWithCarryover = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Complete Latest and End") {
                    guard let item = endingItemWithCarryover,
                          let entry = store.unresolvedCarryoverEntry(for: item.id),
                          let date = DateKey.date(from: entry.latestScheduledDateKey) else {
                        endingItemWithCarryover = nil
                        return
                    }
                    store.completeCarryover(itemID: item.id, occurrenceDate: date)
                    store.delete(item)
                    endingItemWithCarryover = nil
                }
                Button("Skip Overdue and End", role: .destructive) {
                    guard let item = endingItemWithCarryover,
                          let entry = store.unresolvedCarryoverEntry(for: item.id) else {
                        endingItemWithCarryover = nil
                        return
                    }
                    store.skipCarryover(entry)
                    store.delete(item)
                    endingItemWithCarryover = nil
                }
                Button("Cancel", role: .cancel) {
                    endingItemWithCarryover = nil
                }
            } message: {
                Text("This task has unfinished occurrences. Choose how to resolve the latest one before ending it; older occurrences remain recorded as missed.")
            }
            .confirmationDialog(
                "Handle Still Open Before Saving?",
                isPresented: Binding(
                    get: { editedItemEndingWithCarryover != nil },
                    set: { if !$0 { editedItemEndingWithCarryover = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Complete Latest and Save") {
                    guard let updatedItem = editedItemEndingWithCarryover,
                          let entry = store.unresolvedCarryoverEntry(for: updatedItem.id),
                          let date = DateKey.date(from: entry.latestScheduledDateKey) else {
                        editedItemEndingWithCarryover = nil
                        return
                    }
                    store.completeCarryover(itemID: updatedItem.id, occurrenceDate: date)
                    store.save(mergingCurrentOccurrenceState(into: updatedItem))
                    editedItemEndingWithCarryover = nil
                }
                Button("Skip Overdue and Save", role: .destructive) {
                    guard let updatedItem = editedItemEndingWithCarryover,
                          let entry = store.unresolvedCarryoverEntry(for: updatedItem.id) else {
                        editedItemEndingWithCarryover = nil
                        return
                    }
                    store.skipCarryover(entry)
                    store.save(mergingCurrentOccurrenceState(into: updatedItem))
                    editedItemEndingWithCarryover = nil
                }
                Button("Cancel", role: .cancel) {
                    editedItemEndingWithCarryover = nil
                }
            } message: {
                Text("This task has unfinished occurrences. Resolve or skip the latest one before adding an end date; older occurrences remain recorded as missed.")
            }
            .confirmationDialog(
                "Handle Still Open Group?",
                isPresented: Binding(
                    get: { endingGroupWithCarryovers != nil },
                    set: { if !$0 { endingGroupWithCarryovers = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Complete Latest and End All") {
                    guard let groupID = endingGroupWithCarryovers else { return }
                    for entry in store.unresolvedCarryoverEntries(inGroup: groupID) {
                        guard let date = DateKey.date(from: entry.latestScheduledDateKey) else { continue }
                        store.completeCarryover(itemID: entry.item.id, occurrenceDate: date)
                    }
                    store.endGroupToday(groupID)
                    endingGroupWithCarryovers = nil
                }
                Button("Skip Overdue and End All", role: .destructive) {
                    guard let groupID = endingGroupWithCarryovers else { return }
                    for entry in store.unresolvedCarryoverEntries(inGroup: groupID) {
                        store.skipCarryover(entry)
                    }
                    store.endGroupToday(groupID)
                    endingGroupWithCarryovers = nil
                }
                Button("Cancel", role: .cancel) {
                    endingGroupWithCarryovers = nil
                }
            } message: {
                Text("Some tasks in this group are still open. Resolve each latest occurrence before ending the group.")
            }
            .alert("Action unavailable", isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { actionErrorMessage = nil }
            } message: {
                Text(actionErrorMessage ?? "")
            }
            .alert("Session expired", isPresented: Binding(
                get: { authStore.requiresReauthentication },
                set: { if !$0 { authStore.dismissReauthenticationPrompt() } }
            )) {
                Button("Sign in") {
                    authStore.dismissReauthenticationPrompt()
                    showingAccount = true
                }
                Button("Later", role: .cancel) {
                    authStore.dismissReauthenticationPrompt()
                }
            } message: {
                Text("Your routines are still saved on this device. Sign in again to resume backup and syncing.")
            }
        }
        .tint(accent)
        .onAppear(perform: maybeShowTutorial)
        .onChange(of: store.hasLoaded) { _, _ in
            maybeShowTutorial()
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    withAnimation(.snappy) { store.moveSelectedDate(by: -1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 42, height: 42)
                        .background(controlSurface, in: Circle())
                }
                .accessibilityLabel("Previous day")

                Spacer()

                Button {
                    withAnimation(.snappy) { store.moveSelectedDate(by: 1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 42, height: 42)
                        .background(controlSurface, in: Circle())
                }
                .accessibilityLabel("Next day")
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                    if !store.isSelectedDateToday {
                        Button("Back to today") {
                            withAnimation(.snappy) { store.selectToday() }
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                    Text("Ritual Cue")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .allowsTightening(true)
                        .layoutPriority(1)
                    Text(summary)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    HStack(spacing: 10) {
                        Button { showingAccount = true } label: {
                            AccountToolbarImage(url: authStore.user?.profileImageURL)
                        }
                        .accessibilityLabel("Account and notification settings")
                    }
                    Spacer(minLength: 10)
                    HStack(spacing: 8) {
                        if !isSearchPresented {
                            searchButton
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                        sortControl
                        editModeButton
                    }
                }
            }
        }
        .padding(.top, 18)
    }

    private var summary: String {
        if store.scope == .archive {
            let count = store.visibleItems.count
            if count == 0 { return "No archived items." }
            return count == 1 ? "One archived item." : "\(count) archived items."
        }
        let count = store.todoItems.count
        let stillOpenCount = store.scope == .today && store.isSelectedDateToday
            ? store.carryoverEntries.count
            : 0
        if stillOpenCount > 0 {
            let todayText = count == 1 ? "1 today" : "\(count) today"
            let openText = stillOpenCount == 1 ? "1 still open" : "\(stillOpenCount) still open"
            return "\(todayText) · \(openText)."
        }
        if count == 0 { return "Everything is checked off." }
        let day = store.isSelectedDateToday ? "today" : "this day"
        return count == 1 ? "One thing left \(day)." : "\(count) things left \(day)."
    }

    private func mergingCurrentOccurrenceState(into editedItem: ChecklistItem) -> ChecklistItem {
        guard let current = store.items.first(where: { $0.id == editedItem.id }) else {
            return editedItem
        }
        var merged = editedItem
        merged.completedDates = current.completedDates
        merged.completionCounts = current.completionCounts
        merged.skippedDates = current.skippedDates
        merged.openDates = current.openDates
        merged.occurrences = current.occurrences
        merged.carryoverResolvedThroughDate = current.carryoverResolvedThroughDate
        return merged
    }

    private var knownGroupIDs: Set<UUID> {
        Set(store.groups.map(\.id))
    }

    private var activeVisibleItems: [ChecklistItem] {
        let groupedCarryoverIDs = store.scope == .today && store.isSelectedDateToday
            ? store.carryoverItemIDsIncludingHidden
            : []
        return store.visibleItems.filter {
            !groupedCarryoverIDs.contains($0.id)
                && (store.scope == .all
                    || (!$0.isSkipped(on: store.selectedDate)
                        && !store.isPaused($0, on: store.selectedDate)))
        }
    }

    private var todoSectionItems: [ChecklistItem] {
        activeVisibleItems.filter { item in
            guard let groupID = item.groupID, knownGroupIDs.contains(groupID) else {
                return !item.isComplete(on: store.selectedDate)
            }
            return !groupIsComplete(groupID)
        }
    }

    private var completedSectionItems: [ChecklistItem] {
        activeVisibleItems.filter { item in
            guard let groupID = item.groupID, knownGroupIDs.contains(groupID) else {
                return item.isComplete(on: store.selectedDate)
            }
            return groupIsComplete(groupID)
        }
    }

    private func groupIsComplete(_ groupID: UUID) -> Bool {
        let items = activeVisibleItems.filter { $0.groupID == groupID }
        return !items.isEmpty && items.allSatisfy { $0.isComplete(on: store.selectedDate) }
    }

    private var filter: some View {
        HStack(spacing: 4) {
            ForEach(ChecklistScope.allCases) { scope in
                let title = scope == .today && !store.isSelectedDateToday ? "Scheduled" : scope.title
                filterButton(title, selected: store.scope == scope) {
                    withAnimation(.snappy) {
                        store.scope = scope
                    }
                }
            }
        }
        .padding(4)
        .background(subtleFill, in: Capsule())
    }

    private var searchButton: some View {
        Button {
            withAnimation(.snappy) {
                isSearchPresented = true
            }
            DispatchQueue.main.async {
                searchIsFocused = true
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(searchText.isEmpty ? ink : accent)
                .frame(width: 35, height: 35)
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID("checklist-search", in: searchGlassNamespace)
                .glassEffectTransition(.matchedGeometry)
        }
        .accessibilityLabel("Search checklist")
        .accessibilityValue(searchText.isEmpty ? "No search" : searchText)
        .accessibilityHint("Shows the search field")
    }

    private var expandedSearchOverlay: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search tasks", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .focused($searchIsFocused)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear search")
                    }
                }
                .font(.system(size: 17, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 46)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular.interactive(), in: Capsule())
                .glassEffectID("checklist-search", in: searchGlassNamespace)
                .glassEffectTransition(.matchedGeometry)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private func dismissSearch() {
        withAnimation(.snappy) {
            searchText = ""
            searchIsFocused = false
            isSearchPresented = false
        }
    }

    private func maybeShowTutorial() {
        guard store.hasLoaded,
              !hasSeenChecklistTutorial,
              !showingTutorial,
              store.items.isEmpty,
              store.groups.isEmpty,
              UserDefaults.standard.data(forKey: "cachedAuthUser") == nil else { return }
        showingTutorial = true
    }

    private func finishTutorial() {
        hasSeenChecklistTutorial = true
        showingTutorial = false
    }

    private func showTutorialFromAccount() {
        showingAccount = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showingTutorial = true
        }
    }

    private func requestEnd(_ item: ChecklistItem) {
        if store.unresolvedCarryoverEntry(for: item.id) != nil {
            endingItemWithCarryover = item
        } else {
            store.delete(item)
        }
    }

    private var newItemTemplate: ChecklistItem {
        var item = ChecklistItem(title: "")
        #if DEBUG
        if ScreenshotSeedData.isEnabled {
            item.title = "Prep tomorrow"
            item.notes = "A quick evening reminder."
            item.reminderMinutes = 20 * 60
            item.groupID = store.orderedGroups.first { $0.name == "Planning" }?.id
        }
        #endif
        return item
    }

    private func filtered(_ items: [ChecklistItem]) -> [ChecklistItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.notes.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredCarryoverEntries: [CarryoverEntry] {
        let matchingIDs = Set(filtered(store.carryoverEntries.map(\.item)).map(\.id))
        return store.carryoverEntries.filter { matchingIDs.contains($0.item.id) }
    }

    private var showsStillOpenSection: Bool {
        store.scope == .today && store.isSelectedDateToday && !filteredCarryoverEntries.isEmpty
    }

    private var sortControl: some View {
        Menu {
            ForEach(ChecklistSort.allCases) { option in
                Button {
                    withAnimation(.snappy) {
                        store.sortMode = option
                        draggingItemID = nil
                        draggingGroupID = nil
                    }
                } label: {
                    Label(option.title, systemImage: option.icon)
                }
            }
        } label: {
            Image(systemName: store.sortMode.icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 35, height: 35)
                .background(controlSurface, in: Circle())
        }
        .accessibilityLabel("Sort checklist")
        .accessibilityValue(store.sortMode.title)
    }

    private var editModeButton: some View {
        Button {
            withAnimation(.snappy) {
                isEditingChecklist.toggle()
                draggingItemID = nil
                draggingGroupID = nil
            }
        } label: {
            Image(systemName: isEditingChecklist ? "checkmark" : "pencil")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isEditingChecklist ? .white : ink)
                .frame(width: 35, height: 35)
                .background(isEditingChecklist ? accent : controlSurface, in: Circle())
        }
        .accessibilityLabel(isEditingChecklist ? "Done editing checklist" : "Edit checklist")
        .accessibilityHint("Shows or hides reorder handles and item edit buttons")
    }

    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? ink : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? controlSurface : Color.clear, in: Capsule())
                .shadow(color: selected ? .black.opacity(0.06) : .clear, radius: 8, y: 3)
        }
    }

    private func section(
        title: String,
        items: [ChecklistItem],
        emptyText: String?,
        showsCompleteAll: Bool = false,
        isCompletedSection: Bool,
        allowsPermanentDelete: Bool = false,
        displayCount: Int? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer()
                if showsCompleteAll {
                    Button {
                        withAnimation(.snappy) {
                            store.completeAllForSelectedDate()
                        }
                    } label: {
                        Label("All", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .accessibilityHint("Marks every task scheduled for today as complete")
                }
                Text("\(displayCount ?? items.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty, let emptyText {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(accent)
                    Text(emptyText)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background(softSurface, in: RoundedRectangle(cornerRadius: 22))
            } else {
                groupedItems(
                    items,
                    isCompletedSection: isCompletedSection,
                    allowsGroupActions: showsCompleteAll,
                    allowsPermanentDelete: allowsPermanentDelete
                )
            }
        }
    }

    private var stillOpenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("STILL OPEN")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(delayed)
                Spacer()
                Text("\(filteredCarryoverEntries.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(filteredCarryoverEntries) { entry in
                    CarryoverRow(
                        entry: entry,
                        showsEditButton: isEditingChecklist,
                        onAdvance: {
                            withAnimation(.snappy) { store.advanceCarryover(entry) }
                        },
                        onTomorrow: {
                            withAnimation(.snappy) { store.deferCarryoverUntilTomorrow(entry) }
                        },
                        onSkip: {
                            withAnimation(.snappy) { store.skipCarryover(entry) }
                        },
                        onPause: {
                            withAnimation(.snappy) { store.pause(entry.item) }
                        },
                        onSnooze: { preset in
                            store.snooze(
                                itemID: entry.item.id,
                                occurrenceDate: DateKey.date(from: entry.latestScheduledDateKey) ?? .now,
                                occurrenceID: entry.latestOccurrenceID,
                                isCarryover: true,
                                preset: preset
                            )
                        },
                        onEdit: { editingItem = entry.item },
                        onHistory: { historyItem = entry.item }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func groupedItems(
        _ items: [ChecklistItem],
        isCompletedSection: Bool,
        allowsGroupActions: Bool,
        allowsPermanentDelete: Bool
    ) -> some View {
        let knownGroupIDs = Set(store.groups.map(\.id))
        let ungrouped = items.filter { $0.groupID == nil || $0.groupID.map(knownGroupIDs.contains) == false }

        if store.groups.isEmpty {
            itemStack(ungrouped, groupID: nil, allowsPermanentDelete: allowsPermanentDelete)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                if !ungrouped.isEmpty {
                    groupBlock(
                        title: "Ungrouped",
                        groupID: nil,
                        items: ungrouped,
                        isRealGroup: false,
                        allowsPermanentDelete: allowsPermanentDelete,
                        showsCompleteAll: false
                    )
                }
                ForEach(store.orderedGroups) { group in
                    let groupItems = items.filter { $0.groupID == group.id }
                    let isCompleteGroup = groupIsComplete(group.id)
                    let groupPaused = store.isGroupPaused(group.id, on: store.selectedDate)
                    if !groupItems.isEmpty && isCompleteGroup == isCompletedSection {
                        groupBlock(
                            title: group.name,
                            groupID: group.id,
                            items: groupItems,
                            isRealGroup: true,
                            isCollapsed: group.isCollapsed,
                            isPaused: groupPaused,
                            canDeleteGroup: store.canDeleteGroup(group.id),
                            allowsGroupActions: allowsGroupActions,
                            allowsPermanentDelete: allowsPermanentDelete,
                            showsCompleteAll: !isCompletedSection
                                && groupItems.contains { !$0.isComplete(on: store.selectedDate) }
                        )
                    }
                }
            }
        }
    }

    private func groupBlock(
        title: String,
        groupID: UUID?,
        items: [ChecklistItem],
        isRealGroup: Bool,
        isCollapsed: Bool = false,
        isPaused: Bool = false,
        canDeleteGroup: Bool = false,
        allowsGroupActions: Bool = false,
        allowsPermanentDelete: Bool = false,
        showsCompleteAll: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            groupHeader(
                title: title,
                groupID: groupID,
                completedCount: items.filter { $0.isComplete(on: store.selectedDate) }.count,
                totalCount: items.count,
                isRealGroup: isRealGroup,
                isCollapsed: isCollapsed,
                isPaused: isPaused,
                canDeleteGroup: canDeleteGroup,
                showsCompleteAll: showsCompleteAll,
                allowsGroupActions: allowsGroupActions,
                toggleCollapsed: {
                    guard let groupID else { return }
                    withAnimation(.snappy) {
                        store.toggleGroupCollapsed(groupID)
                    }
                },
                rename: {
                    guard let groupID else { return }
                    renameGroupName = title
                    renamingGroupID = groupID
                },
                delete: {
                    guard let groupID,
                          let group = store.groups.first(where: { $0.id == groupID }) else { return }
                    deletingGroup = group
                },
                completeAll: {
                    withAnimation(.snappy) {
                        store.completeAll(itemIDs: Set(items.map(\.id)))
                    }
                },
                skipGroup: {
                    withAnimation(.snappy) {
                        store.skipGroup(groupID)
                    }
                },
                pauseGroup: {
                    guard let groupID else { return }
                    withAnimation(.snappy) {
                        store.pauseGroup(groupID)
                    }
                },
                resumeGroup: {
                    guard let groupID else { return }
                    withAnimation(.snappy) {
                        store.resumeGroup(groupID)
                    }
                },
                startTomorrow: {
                    guard let groupID else { return }
                    withAnimation(.snappy) {
                        store.startGroupTomorrow(groupID)
                    }
                },
                duplicate: {
                    guard let groupID else { return }
                    withAnimation(.snappy) {
                        store.duplicateGroup(groupID)
                    }
                },
                endAll: {
                    guard let groupID else { return }
                    withAnimation(.snappy) {
                        if store.unresolvedCarryoverEntries(inGroup: groupID).isEmpty {
                            store.endGroupToday(groupID)
                        } else {
                            endingGroupWithCarryovers = groupID
                        }
                    }
                }
            )
            if isCollapsed {
                EmptyView()
            } else if items.isEmpty {
                if isEditingChecklist && store.sortMode == .manual {
                    Text("Drop tasks here")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            softSurface,
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .onDrop(
                            of: [UTType.text],
                            delegate: groupDropDelegate(groupID: groupID, isRealGroup: isRealGroup)
                        )
                }
            } else {
                itemStack(items, groupID: groupID, allowsPermanentDelete: allowsPermanentDelete)
            }
        }
    }

    @ViewBuilder
    private func groupHeader(
        title: String,
        groupID: UUID?,
        completedCount: Int,
        totalCount: Int,
        isRealGroup: Bool,
        isCollapsed: Bool,
        isPaused: Bool,
        canDeleteGroup: Bool,
        showsCompleteAll: Bool,
        allowsGroupActions: Bool,
        toggleCollapsed: @escaping () -> Void,
        rename: @escaping () -> Void,
        delete: @escaping () -> Void,
        completeAll: @escaping () -> Void,
        skipGroup: @escaping () -> Void,
        pauseGroup: @escaping () -> Void,
        resumeGroup: @escaping () -> Void,
        startTomorrow: @escaping () -> Void,
        duplicate: @escaping () -> Void,
        endAll: @escaping () -> Void
    ) -> some View {
        let header = HStack(spacing: 8) {
            if isRealGroup {
                Button(action: toggleCollapsed) {
                    HStack(spacing: 8) {
                        Image(systemName: isCollapsed ? "folder.fill" : "folder")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent.opacity(0.78))
                            .frame(width: 24, height: 24)
                        Text(title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(ink.opacity(0.78))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Open \(title)" : "Close \(title)")
            } else {
                Image(systemName: "tray.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.75))
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ink.opacity(0.78))
            }
            Text(completedCount == totalCount ? "\(totalCount)" : "\(completedCount)/\(totalCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            if isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(delayed)
            }
            if isRealGroup, isEditingChecklist {
                Menu {
                    Button(action: rename) {
                        Label("Rename", systemImage: "pencil")
                    }
                    if allowsGroupActions {
                        if isPaused {
                            Button(action: resumeGroup) {
                                Label("Resume", systemImage: "play.circle")
                            }
                        } else {
                            Button(action: pauseGroup) {
                                Label("Pause 1 week", systemImage: "pause.circle")
                            }
                        }
                        Button(action: skipGroup) {
                            Label("Skip today", systemImage: "forward.end")
                        }
                        Button(action: startTomorrow) {
                            Label("Start tomorrow", systemImage: "calendar.badge.clock")
                        }
                        Button(action: duplicate) {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        Button(role: .destructive, action: endAll) {
                            Label("End all items", systemImage: "archivebox")
                        }
                    }
                    if canDeleteGroup {
                        Button(role: .destructive, action: delete) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Group actions for \(title)")
            }
            Spacer()
            if showsCompleteAll {
                Button(action: completeAll) {
                    Label("All", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .accessibilityHint("Marks every task in \(title) as complete")
            }
            if isRealGroup, isEditingChecklist, store.sortMode == .manual {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)

        if isRealGroup, isEditingChecklist, store.sortMode == .manual, let groupID {
            header
                .opacity(draggingGroupID == groupID ? 0.55 : 1)
                .onDrag {
                    draggingGroupID = groupID
                    draggingItemID = nil
                    return NSItemProvider(object: "group:\(groupID.uuidString)" as NSString)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: groupDropDelegate(groupID: groupID, isRealGroup: true)
                )
        } else if isEditingChecklist && store.sortMode == .manual {
            header
                .onDrop(
                    of: [UTType.text],
                    delegate: groupDropDelegate(groupID: groupID, isRealGroup: isRealGroup)
                )
        } else {
            header
        }
    }

    private func groupDropDelegate(groupID: UUID?, isRealGroup: Bool) -> ChecklistGroupDropDelegate {
        ChecklistGroupDropDelegate(
            targetGroupID: groupID,
            targetRealGroupID: isRealGroup ? groupID : nil,
            draggingItemID: $draggingItemID,
            draggingGroupID: $draggingGroupID,
            moveItem: store.move(_:toGroup:),
            moveGroup: store.moveGroup
        )
    }

    private func itemStack(_ items: [ChecklistItem], groupID: UUID?, allowsPermanentDelete: Bool) -> some View {
        VStack(spacing: 10) {
            ForEach(items) { item in
                if isEditingChecklist && store.sortMode == .manual {
                    ItemRow(
                        item: item,
                        date: store.selectedDate,
                        showsDragHandle: true,
                        showsEditButton: true,
                        onToggle: { store.toggle(item) },
                        onEdit: { editingItem = item },
                        onSkip: { store.setSkipped(item, skipped: true) },
                        onUnskip: { store.setSkipped(item, skipped: false) },
                        onPause: { store.pause(item) },
                        onResume: { store.resume(item) },
                        onDelay: { delay(item) },
                        onBringForward: { bringForward(item) },
                        onSnooze: { preset in
                            store.snooze(
                                itemID: item.id,
                                occurrenceDate: store.selectedDate,
                                occurrenceID: item.occurrenceID(
                                    scheduledDate: DateKey.string(from: store.selectedDate)
                                ),
                                preset: preset
                            )
                        },
                        onHistory: { historyItem = item },
                        paused: store.isPaused(item, on: store.selectedDate),
                        allowsPermanentDelete: allowsPermanentDelete,
                        onPermanentDelete: { permanentlyDeletingItem = item }
                    )
                    .opacity(draggingItemID == item.id ? 0.55 : 1)
                    .onDrag {
                        draggingItemID = item.id
                        draggingGroupID = nil
                        return NSItemProvider(object: "item:\(item.id.uuidString)" as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: ChecklistItemDropDelegate(
                            targetID: item.id,
                            targetGroupID: groupID,
                            draggingItemID: $draggingItemID,
                            move: store.move(_:before:toGroup:)
                        )
                    )
                } else {
                    ItemRow(
                        item: item,
                        date: store.selectedDate,
                        showsDragHandle: false,
                        showsEditButton: isEditingChecklist,
                        onToggle: { store.toggle(item) },
                        onEdit: { editingItem = item },
                        onSkip: { store.setSkipped(item, skipped: true) },
                        onUnskip: { store.setSkipped(item, skipped: false) },
                        onPause: { store.pause(item) },
                        onResume: { store.resume(item) },
                        onDelay: { delay(item) },
                        onBringForward: { bringForward(item) },
                        onSnooze: { preset in
                            store.snooze(
                                itemID: item.id,
                                occurrenceDate: store.selectedDate,
                                occurrenceID: item.occurrenceID(
                                    scheduledDate: DateKey.string(from: store.selectedDate)
                                ),
                                preset: preset
                            )
                        },
                        onHistory: { historyItem = item },
                        paused: store.isPaused(item, on: store.selectedDate),
                        allowsPermanentDelete: allowsPermanentDelete,
                        onPermanentDelete: { permanentlyDeletingItem = item }
                    )
                }
            }
        }
    }

    private func delay(_ item: ChecklistItem) {
        do {
            try store.delay(item)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func bringForward(_ item: ChecklistItem) {
        do {
            try store.bringForward(item)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }
}

private struct ChecklistTutorialView: View {
    let createSamples: () -> Void
    let startEmpty: () -> Void
    @State private var selection = 0

    private let pages = [
        TutorialPage(
            title: "Group Repeat Routines",
            body: "Turn morning, evening, pet care, health, and household rhythms into focused groups so today only shows what is due.",
            systemImage: "checklist"
        ),
        TutorialPage(
            title: "Check, Skip, Or Review",
            body: "Finish a task, skip a one-off day, or open history to correct Done, Open, Missed, and Skipped states later.",
            systemImage: "clock.arrow.circlepath"
        ),
        TutorialPage(
            title: "Stay Offline, Sync When Ready",
            body: "Ritual Cue keeps edits on this device first, then backs up and shares your routines when you sign in.",
            systemImage: "icloud"
        ),
        TutorialPage(
            title: "Start With Sample Routines",
            body: "Load starter groups for Morning, Evening, Pet Care, and Household, then tune them to your real schedule.",
            systemImage: "sparkles"
        )
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                TabView(selection: $selection) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        VStack(spacing: 22) {
                            Image(systemName: page.systemImage)
                                .font(.system(size: 46, weight: .semibold))
                                .foregroundStyle(accent)
                                .frame(width: 96, height: 96)
                                .background(accent.opacity(0.12), in: Circle())
                            VStack(spacing: 10) {
                                Text(page.title)
                                    .font(.system(size: 26, weight: .bold, design: .rounded))
                                    .foregroundStyle(ink)
                                    .multilineTextAlignment(.center)
                                Text(page.body)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3)
                            }
                        }
                        .padding(.horizontal, 28)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(minHeight: 360)

                VStack(spacing: 10) {
                    if selection < pages.count - 1 {
                        Button {
                            withAnimation(.snappy) {
                                selection += 1
                            }
                        } label: {
                            Text("Next")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TutorialPrimaryButtonStyle())

                        Button("Start empty", action: startEmpty)
                            .buttonStyle(TutorialSecondaryButtonStyle())
                    } else {
                        Button(action: createSamples) {
                            Text("Create sample routines")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TutorialPrimaryButtonStyle())

                        Button("Start empty", action: startEmpty)
                            .buttonStyle(TutorialSecondaryButtonStyle())
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 22)
            .background(canvas.ignoresSafeArea())
            .navigationTitle("Welcome to Ritual Cue")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}

private struct TutorialPage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let systemImage: String
}

private struct TutorialPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .padding(.vertical, 15)
            .background(accent.opacity(configuration.isPressed ? 0.78 : 1), in: Capsule())
    }
}

private struct TutorialSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ink.opacity(configuration.isPressed ? 0.55 : 0.72))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

private struct AccountToolbarImage: View {
    let url: URL?

    var body: some View {
        ZStack {
            controlSurface
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
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }

    private var fallback: some View {
        Image(systemName: "person.crop.circle")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(ink)
    }
}

private struct CarryoverRow: View {
    let entry: CarryoverEntry
    let showsEditButton: Bool
    let onAdvance: () -> Void
    let onTomorrow: () -> Void
    let onSkip: () -> Void
    let onPause: () -> Void
    let onSnooze: (ReminderSnoozePreset) -> Void
    let onEdit: () -> Void
    let onHistory: () -> Void

    private var oldestDate: Date {
        DateKey.date(from: entry.oldestScheduledDateKey) ?? .now
    }

    private var lateDays: Int {
        max(1, Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: oldestDate),
            to: Calendar.current.startOfDay(for: .now)
        ).day ?? 1)
    }

    private var dueText: String {
        if entry.outstandingOccurrenceCount > 1 {
            let age = lateDays == 1 ? "1 day late" : "\(lateDays) days late"
            return "\(entry.outstandingOccurrenceCount) open occurrences · oldest \(oldestDate.formatted(.dateTime.month(.abbreviated).day())) · \(age)"
        }
        if lateDays == 1 { return "Due yesterday" }
        return "Due \(oldestDate.formatted(.dateTime.month(.abbreviated).day())) · \(lateDays) days late"
    }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                onAdvance()
            } label: {
                ZStack {
                    Circle()
                        .stroke(delayed, lineWidth: 2)
                        .frame(width: 28, height: 28)
                    if entry.latestCompletionCount > 0 {
                        Text("\(entry.latestCompletionCount)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(delayed)
                    }
                }
            }
            .accessibilityLabel(entry.item.quantity > 1 ? "Advance overdue quantity" : "Complete overdue occurrence")
            .accessibilityValue(entry.item.quantity > 1 ? "\(entry.latestCompletionCount) of \(entry.item.quantity)" : "")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    if entry.item.quantity > 1 {
                        Text("\(entry.latestCompletionCount)/\(entry.item.quantity)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(delayed)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(delayed.opacity(0.12), in: Capsule())
                    }
                }
                Label(dueText, systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(delayed)
                if !entry.item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.item.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if showsEditButton {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(subtleFill, in: Circle())
                }
                .accessibilityLabel("Edit \(entry.item.title)")
            }

            Menu {
                Button(action: onTomorrow) {
                    Label("Tomorrow", systemImage: "sunrise")
                }
                Button(action: onSkip) {
                    Label("Skip overdue occurrence", systemImage: "forward.end")
                }
                Button(action: onPause) {
                    Label("Pause 1 week", systemImage: "pause.circle")
                }
                if entry.item.reminderMinutes != nil {
                    Menu {
                        snoozeButtons
                    } label: {
                        Label("Snooze reminder", systemImage: "bell.badge")
                    }
                }
                Divider()
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(action: onHistory) {
                    Label("History", systemImage: "calendar")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 36)
            }
            .accessibilityLabel("More actions for \(entry.item.title)")
        }
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(delayed.opacity(0.24), lineWidth: 1)
        }
        .contextMenu {
            Button(action: onTomorrow) { Label("Tomorrow", systemImage: "sunrise") }
            Button(action: onSkip) { Label("Skip overdue occurrence", systemImage: "forward.end") }
            Button(action: onPause) { Label("Pause 1 week", systemImage: "pause.circle") }
            if entry.item.reminderMinutes != nil {
                snoozeButtons
            }
            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
            Button(action: onHistory) { Label("History", systemImage: "calendar") }
        }
    }

    @ViewBuilder
    private var snoozeButtons: some View {
        Button { onSnooze(.fifteenMinutes) } label: {
            Label("Snooze 15 minutes", systemImage: "clock.badge")
        }
        Button { onSnooze(.oneHour) } label: {
            Label("Snooze 1 hour", systemImage: "clock.badge")
        }
        Button { onSnooze(.tomorrowMorning) } label: {
            Label("Snooze until tomorrow", systemImage: "sunrise")
        }
    }
}

private struct ItemRow: View {
    let item: ChecklistItem
    let date: Date
    let showsDragHandle: Bool
    let showsEditButton: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onSkip: () -> Void
    let onUnskip: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelay: () -> Void
    let onBringForward: () -> Void
    let onSnooze: (ReminderSnoozePreset) -> Void
    let onHistory: () -> Void
    let paused: Bool
    let allowsPermanentDelete: Bool
    let onPermanentDelete: () -> Void

    private var completed: Bool { item.isComplete(on: date) }
    private var skipped: Bool { item.isSkipped(on: date) }
    private var completionCount: Int { item.completionCount(on: date) }
    private var missedDays: Int { paused ? 0 : item.consecutiveMissedDays(asOf: date) }
    private var completionStreak: Int { paused ? 0 : item.consecutiveCompletedDays(asOf: date) }
    private var delayedDays: Int { item.delayedDays(asOf: date) }
    private var canBringForward: Bool {
        Calendar.current.startOfDay(for: date) > Calendar.current.startOfDay(for: .now)
    }
    private var canSnooze: Bool {
        item.reminderMinutes != nil && Calendar.current.isDateInToday(date)
    }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(.snappy) {
                    onToggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(completed ? accent : Color.primary.opacity(0.22), lineWidth: 2)
                        .frame(width: 28, height: 28)
                    if completed {
                        Circle().fill(accent).frame(width: 28, height: 28)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .accessibilityLabel(completed ? "Mark incomplete" : "Check off")
            .accessibilityValue(item.quantity > 1 ? "\(completionCount) of \(item.quantity)" : "")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(completed ? .secondary : ink)
                        .strikethrough(completed, color: .secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if item.quantity > 1 {
                        quantityChip
                    }
                    if completionStreak > 0 {
                        statusBadge(
                            "\(completionStreak) \(completionStreak == 1 ? "day" : "days")",
                            systemImage: "checkmark.seal.fill",
                            color: success,
                            accessibilityLabel: "\(completionStreak) day completion streak"
                        )
                        .transition(.scale(scale: 0.86).combined(with: .opacity))
                    } else if missedDays > 0 {
                        statusBadge(
                            "\(missedDays) \(missedDays == 1 ? "day" : "days")",
                            systemImage: "calendar.badge.exclamationmark",
                            color: Color(red: 0.72, green: 0.22, blue: 0.20),
                            accessibilityLabel: "\(missedDays) consecutive missed \(missedDays == 1 ? "day" : "days")"
                        )
                    }
                    if delayedDays > 0 {
                        statusBadge(
                            "\(delayedDays) \(delayedDays == 1 ? "day" : "days")",
                            systemImage: "arrow.right.circle.fill",
                            color: delayed,
                            accessibilityLabel: "Delayed \(delayedDays) \(delayedDays == 1 ? "day" : "days")"
                        )
                    }
                    if paused {
                        statusBadge(
                            "Paused",
                            systemImage: "pause.circle.fill",
                            color: delayed,
                            accessibilityLabel: "Paused"
                        )
                    }
                }
                HStack(spacing: 8) {
                    Label(item.scheduleSummary, systemImage: "repeat")
                    if let minutes = item.reminderMinutes {
                        Label(timeString(minutes), systemImage: "bell.fill")
                        if let followUp = item.followUpPolicy {
                            Text("+\(followUp.maximumCount)")
                                .accessibilityLabel("\(followUp.maximumCount) follow-up reminders")
                        }
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                if !item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .strikethrough(completed, color: .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if showsEditButton {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(subtleFill, in: Circle())
                }
                .accessibilityLabel("Edit \(item.title)")
            }
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .frame(width: 24, height: 36)
                    .accessibilityHidden(true)
            }
            if skipped {
                Text("Skipped")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(subtleFill, in: Capsule())
            }
        }
        .padding(16)
        .background(
            (completed ? softSurface : surface),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(action: onHistory) {
                Label("History", systemImage: "calendar")
            }
            if skipped {
                Button(action: onUnskip) {
                    Label("Undo skip", systemImage: "arrow.uturn.backward")
                }
            } else if paused {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.circle")
                }
            } else if !completed {
                Button(action: onPause) {
                    Label("Pause 1 week", systemImage: "pause.circle")
                }
                if canBringForward {
                    Button(action: onBringForward) {
                        Label("Bring to today", systemImage: "arrow.left.circle")
                    }
                }
                Button(action: onDelay) {
                    Label("Delay to next day", systemImage: "arrow.right.circle")
                }
                Button(action: onSkip) {
                    Label("Skip today", systemImage: "forward.end")
                }
                if canSnooze {
                    Menu {
                        Button { onSnooze(.fifteenMinutes) } label: {
                            Label("15 minutes", systemImage: "clock.badge")
                        }
                        Button { onSnooze(.oneHour) } label: {
                            Label("1 hour", systemImage: "clock.badge")
                        }
                        Button { onSnooze(.tomorrowMorning) } label: {
                            Label("Tomorrow morning", systemImage: "sunrise")
                        }
                    } label: {
                        Label("Snooze reminder", systemImage: "bell.badge")
                    }
                }
            }
            if allowsPermanentDelete {
                Button(role: .destructive, action: onPermanentDelete) {
                    Label("Delete permanently", systemImage: "trash")
                }
            }
        }
        .accessibilityHint("Long press for edit, history, pause, bring forward, delay, and skip actions")
    }

    private func statusBadge(
        _ text: String,
        systemImage: String,
        color: Color,
        accessibilityLabel: String
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(text)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
    }

    private var quantityChip: some View {
        Text("\(completionCount)/\(item.quantity)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(completed ? success : accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((completed ? success : accent).opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityLabel("Quantity progress \(completionCount) of \(item.quantity)")
    }
}

private struct HistoryCalendarCell: Identifiable {
    let id: String
    let date: Date?
    let state: ChecklistHistoryState?

    static func empty(id: String) -> HistoryCalendarCell {
        HistoryCalendarCell(id: id, date: nil, state: nil)
    }

    static func day(date: Date, state: ChecklistHistoryState) -> HistoryCalendarCell {
        HistoryCalendarCell(id: DateKey.string(from: date), date: date, state: state)
    }
}

private struct ItemHistoryView: View {
    @EnvironmentObject private var store: ChecklistStore
    let item: ChecklistItem
    @State private var actionErrorMessage: String?

    private let calendarColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    private var weekdaySymbols: [String] {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let firstIndex = Calendar.current.firstWeekday - 1
        return Array(symbols[firstIndex..<symbols.count]) + Array(symbols[0..<firstIndex])
    }

    private var currentItem: ChecklistItem {
        store.items.first(where: { $0.id == item.id }) ?? item
    }

    private var history: [(date: Date, state: ChecklistHistoryState)] {
        store.completionHistory(for: currentItem)
    }

    private var calendarDays: [(date: Date, state: ChecklistHistoryState)] {
        Array(history.reversed())
    }

    private var calendarCells: [HistoryCalendarCell] {
        guard let firstDate = calendarDays.first?.date else { return [] }
        let leadingEmptyDays = weekdayOffset(for: firstDate)
        let occupiedCells = leadingEmptyDays + calendarDays.count
        let trailingEmptyDays = (7 - occupiedCells % 7) % 7

        return (0..<leadingEmptyDays).map { HistoryCalendarCell.empty(id: "leading-\($0)") }
            + calendarDays.map { HistoryCalendarCell.day(date: $0.date, state: $0.state) }
            + (0..<trailingEmptyDays).map { HistoryCalendarCell.empty(id: "trailing-\($0)") }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                historyCalendar
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                List(history, id: \.date) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            if let resolution = resolutionText(for: entry.date) {
                                Text(resolution)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if canDelay(entry.state) {
                            Button {
                                delay(entry.date)
                            } label: {
                                Label("Delay", systemImage: "arrow.right.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delay to next day")
                        }
                        if canBringForward(entry.date, state: entry.state) {
                            Button {
                                bringForward(entry.date)
                            } label: {
                                Label("Bring to today", systemImage: "arrow.left.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Bring to today")
                        }
                        Menu {
                            ForEach(availableStates(for: entry.date)) { state in
                                Button {
                                    withAnimation(.snappy) {
                                        store.setHistoryState(state, for: currentItem.id, on: entry.date)
                                    }
                                } label: {
                                    Label(state.rawValue, systemImage: state == entry.state ? "checkmark" : icon(for: state))
                                }
                            }
                        } label: {
                            statePill(entry.state)
                        }
                        .accessibilityLabel("Change \(entry.date.formatted(.dateTime.month(.wide).day())) state")
                        .accessibilityValue(entry.state.rawValue)
                    }
                }
            }
            .navigationTitle(currentItem.title)
            .navigationBarTitleDisplayMode(.inline)
            .alert("Action unavailable", isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { actionErrorMessage = nil }
            } message: {
                Text(actionErrorMessage ?? "")
            }
        }
    }

    private var historyCalendar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(calendarTitle)
                .font(.headline)
                .foregroundStyle(ink)

            LazyVGrid(columns: calendarColumns, spacing: 7) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }

                ForEach(calendarCells) { cell in
                    calendarCell(cell)
                }
            }
        }
        .padding(14)
        .background(surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var calendarTitle: String {
        guard let start = calendarDays.first?.date,
              let end = calendarDays.last?.date else {
            return "History"
        }
        let startMonth = start.formatted(.dateTime.month(.abbreviated))
        let endMonth = end.formatted(.dateTime.month(.abbreviated).year())
        if Calendar.current.isDate(start, equalTo: end, toGranularity: .month) {
            return end.formatted(.dateTime.month(.wide).year())
        }
        return "\(startMonth) - \(endMonth)"
    }

    private func weekdayOffset(for date: Date) -> Int {
        let weekday = Calendar.current.component(.weekday, from: date)
        return (weekday - Calendar.current.firstWeekday + 7) % 7
    }

    @ViewBuilder
    private func calendarCell(_ cell: HistoryCalendarCell) -> some View {
        if let date = cell.date, let state = cell.state {
            calendarDay(date: date, state: state)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 45)
                .accessibilityHidden(true)
        }
    }

    private func calendarDay(date: Date, state: ChecklistHistoryState) -> some View {
        let color = color(for: state)
        let isOff = state == .off

        return VStack(spacing: 4) {
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 13, weight: .semibold))
            Image(systemName: icon(for: state))
                .font(.system(size: 11, weight: .bold))
                .opacity(isOff ? 0 : 1)
        }
        .foregroundStyle(isOff ? .secondary : color)
        .frame(maxWidth: .infinity, minHeight: 45)
        .background(color.opacity(isOff ? 0.06 : 0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(isOff ? 0.10 : 0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(date.formatted(.dateTime.weekday(.wide).month(.wide).day())), \(state.rawValue)")
    }

    private func canDelay(_ state: ChecklistHistoryState) -> Bool {
        state == .open || state == .missed
    }

    private func canBringForward(_ date: Date, state: ChecklistHistoryState) -> Bool {
        state == .open && Calendar.current.startOfDay(for: date) > Calendar.current.startOfDay(for: .now)
    }

    private func resolutionText(for date: Date) -> String? {
        let key = DateKey.string(from: date)
        guard let occurrence = currentItem.occurrences.values
            .filter({ $0.scheduledDate == key })
            .max(by: { $0.scheduleRevision < $1.scheduleRevision }),
              let resolvedKey = occurrence.resolvedDate,
              resolvedKey != key,
              let resolvedDate = DateKey.date(from: resolvedKey) else { return nil }
        let verb = occurrence.outcome == .done ? "Completed" : "Handled"
        let daysLate = max(1, Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: date),
            to: Calendar.current.startOfDay(for: resolvedDate)
        ).day ?? 1)
        return "\(verb) \(daysLate) \(daysLate == 1 ? "day" : "days") late"
    }

    private func delay(_ date: Date) {
        do {
            try store.delay(currentItem, from: date)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func bringForward(_ date: Date) {
        do {
            try store.bringForward(currentItem, from: date)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func statePill(_ state: ChecklistHistoryState) -> some View {
        Text(state.rawValue)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(color(for: state))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color(for: state).opacity(0.12), in: Capsule())
    }

    private func availableStates(for date: Date) -> [ChecklistHistoryState] {
        var states: [ChecklistHistoryState] = [.done, .open]

        if currentItem.isScheduled(on: date),
           Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: .now) {
            states.append(.missed)
        } else if !currentItem.isScheduled(on: date) {
            states.append(.off)
        }

        states.append(.paused)
        states.append(.skipped)
        return states
    }

    private func color(for state: ChecklistHistoryState) -> Color {
        switch state {
        case .done: success
        case .skipped, .off: .secondary
        case .missed: Color(red: 0.72, green: 0.22, blue: 0.20)
        case .open: Color(red: 0.13, green: 0.48, blue: 0.34)
        case .paused: delayed
        }
    }

    private func icon(for state: ChecklistHistoryState) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .skipped: "forward.end.fill"
        case .missed: "xmark.circle.fill"
        case .open: "circle"
        case .paused: "pause.circle.fill"
        case .off: "minus.circle"
        }
    }
}

private struct ChecklistItemDropDelegate: DropDelegate {
    let targetID: UUID
    let targetGroupID: UUID?
    @Binding var draggingItemID: UUID?
    let move: (UUID, UUID, UUID?) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingItemID, draggingItemID != targetID else { return }
        move(draggingItemID, targetID, targetGroupID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct ChecklistGroupDropDelegate: DropDelegate {
    let targetGroupID: UUID?
    let targetRealGroupID: UUID?
    @Binding var draggingItemID: UUID?
    @Binding var draggingGroupID: UUID?
    let moveItem: (UUID, UUID?) -> Void
    let moveGroup: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        if let draggingGroupID, let targetRealGroupID, draggingGroupID != targetRealGroupID {
            moveGroup(draggingGroupID, targetRealGroupID)
        } else if let draggingItemID {
            moveItem(draggingItemID, targetGroupID)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        draggingGroupID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private func timeString(_ minutes: Int) -> String {
    var components = DateComponents()
    components.hour = minutes / 60
    components.minute = minutes % 60
    let date = Calendar.current.date(from: components) ?? .now
    return date.formatted(date: .omitted, time: .shortened)
}
