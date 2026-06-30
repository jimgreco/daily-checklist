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

struct ChecklistView: View {
    @EnvironmentObject private var store: ChecklistStore
    @EnvironmentObject private var authStore: AuthStore
    @State private var editingItem: ChecklistItem?
    @State private var showingNewItem = false
    @State private var showingSettings = false
    @State private var showingAccount = false
    @State private var isEditingChecklist = false
    @State private var draggingItemID: UUID?
    @State private var draggingGroupID: UUID?
    @State private var renamingGroupID: UUID?
    @State private var renameGroupName = ""
    @State private var deletingGroup: ChecklistGroup?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                canvas.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                        filter
                            .padding(.top, 22)
                        section(
                            title: "TO DO",
                            items: store.todoItems,
                            emptyText: "Nothing left for now",
                            showsCompleteAll: store.showingToday && !store.todoItems.isEmpty,
                            isCompletedSection: false
                        )
                            .padding(.top, 28)
                        section(
                            title: "COMPLETED",
                            items: store.completedItems,
                            emptyText: nil,
                            isCompletedSection: true
                        )
                            .padding(.top, 32)
                            .opacity(store.completedItems.isEmpty ? 0 : 1)
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
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingNewItem) {
                ItemEditor(
                    item: ChecklistItem(title: ""),
                    groups: store.orderedGroups,
                    onSave: { store.save($0) },
                    onCreateGroup: { store.createGroup(named: $0) }
                )
            }
            .sheet(item: $editingItem) { item in
                ItemEditor(
                    item: item,
                    groups: store.orderedGroups,
                    onSave: { store.save($0) },
                    onCreateGroup: { store.createGroup(named: $0) },
                    onDelete: { store.delete($0) }
                )
            }
            .sheet(isPresented: $showingSettings) {
                EveningReminderView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingAccount) {
                AccountView()
                    .environmentObject(store)
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
        }
        .tint(accent)
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
                    if !store.isSelectedDateToday {
                        Button("Back to today") {
                            withAnimation(.snappy) { store.selectToday() }
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                    Text("Daily")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(ink)
                    Text(summary)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    HStack(spacing: 10) {
                        Button { showingSettings = true } label: {
                            Image(systemName: "bell")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ink)
                                .frame(width: 44, height: 44)
                                .background(controlSurface, in: Circle())
                        }
                        Button { showingAccount = true } label: {
                            AccountToolbarImage(url: authStore.user?.profileImageURL)
                        }
                        .accessibilityLabel("Account")
                    }
                    Spacer(minLength: 10)
                    HStack(spacing: 8) {
                        sortControl
                        editModeButton
                    }
                }
            }
        }
        .padding(.top, 18)
    }

    private var summary: String {
        let count = store.todoItems.count
        if count == 0 { return "Everything is checked off." }
        let day = store.isSelectedDateToday ? "today" : "this day"
        return count == 1 ? "One thing left \(day)." : "\(count) things left \(day)."
    }

    private var filter: some View {
        HStack(spacing: 4) {
            filterButton(store.isSelectedDateToday ? "Today" : "Scheduled", selected: store.showingToday) {
                store.showingToday = true
            }
            filterButton("All items", selected: !store.showingToday) { store.showingToday = false }
        }
        .padding(4)
        .background(subtleFill, in: Capsule())
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
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.arrow.down")
                Text(store.sortMode.title)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(controlSurface, in: Capsule())
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
        isCompletedSection: Bool
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
                Text("\(items.count)")
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
                groupedItems(items, isCompletedSection: isCompletedSection)
            }
        }
    }

    @ViewBuilder
    private func groupedItems(_ items: [ChecklistItem], isCompletedSection: Bool) -> some View {
        let knownGroupIDs = Set(store.groups.map(\.id))
        let ungrouped = items.filter { $0.groupID == nil || $0.groupID.map(knownGroupIDs.contains) == false }

        if store.groups.isEmpty {
            itemStack(ungrouped, groupID: nil)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                if !ungrouped.isEmpty {
                    groupBlock(
                        title: "Ungrouped",
                        groupID: nil,
                        items: ungrouped,
                        isRealGroup: false,
                        showsCompleteAll: false
                    )
                }
                ForEach(store.orderedGroups) { group in
                    let groupItems = store.visibleItems.filter { $0.groupID == group.id }
                    let groupIsComplete = !groupItems.isEmpty
                        && groupItems.allSatisfy { $0.isComplete(on: store.selectedDate) }
                    if !groupItems.isEmpty && groupIsComplete == isCompletedSection {
                        groupBlock(
                            title: group.name,
                            groupID: group.id,
                            items: groupItems,
                            isRealGroup: true,
                            canDeleteGroup: store.canDeleteGroup(group.id),
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
        canDeleteGroup: Bool = false,
        showsCompleteAll: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            groupHeader(
                title: title,
                groupID: groupID,
                completedCount: items.filter { $0.isComplete(on: store.selectedDate) }.count,
                totalCount: items.count,
                isRealGroup: isRealGroup,
                canDeleteGroup: canDeleteGroup,
                showsCompleteAll: showsCompleteAll,
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
                }
            )
            if items.isEmpty {
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
                itemStack(items, groupID: groupID)
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
        canDeleteGroup: Bool,
        showsCompleteAll: Bool,
        rename: @escaping () -> Void,
        delete: @escaping () -> Void,
        completeAll: @escaping () -> Void
    ) -> some View {
        let header = HStack(spacing: 8) {
            Image(systemName: isRealGroup ? "folder.fill" : "tray.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent.opacity(0.75))
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ink.opacity(0.78))
            Text(completedCount == totalCount ? "\(totalCount)" : "\(completedCount)/\(totalCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            if isRealGroup, isEditingChecklist {
                Menu {
                    Button(action: rename) {
                        Label("Rename", systemImage: "pencil")
                    }
                    if canDeleteGroup {
                        Button(role: .destructive, action: delete) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
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

    private func itemStack(_ items: [ChecklistItem], groupID: UUID?) -> some View {
        VStack(spacing: 10) {
            ForEach(items) { item in
                if isEditingChecklist && store.sortMode == .manual {
                    ItemRow(
                        item: item,
                        date: store.selectedDate,
                        showsDragHandle: true,
                        showsEditButton: true,
                        onToggle: { store.toggle(item) },
                        onEdit: { editingItem = item }
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
                        onEdit: { editingItem = item }
                    )
                }
            }
        }
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

private struct ItemRow: View {
    let item: ChecklistItem
    let date: Date
    let showsDragHandle: Bool
    let showsEditButton: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void

    private var completed: Bool { item.isComplete(on: date) }
    private var missedDays: Int { item.consecutiveMissedDays(asOf: date) }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onToggle) {
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
            .accessibilityLabel(completed ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(completed ? .secondary : ink)
                        .strikethrough(completed, color: .secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if missedDays > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.exclamationmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("\(missedDays) \(missedDays == 1 ? "day" : "days")")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.72, green: 0.22, blue: 0.20))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Color(red: 0.72, green: 0.22, blue: 0.20).opacity(0.1),
                            in: Capsule()
                        )
                        .fixedSize()
                        .accessibilityLabel("\(missedDays) consecutive missed \(missedDays == 1 ? "day" : "days")")
                    }
                }
                HStack(spacing: 8) {
                    Label(item.scheduleSummary, systemImage: "repeat")
                    if let minutes = item.reminderMinutes {
                        Label(timeString(minutes), systemImage: "bell.fill")
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
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .frame(width: 24, height: 36)
                    .accessibilityHidden(true)
            }
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
        }
        .padding(16)
        .background(
            (completed ? softSurface : surface),
            in: RoundedRectangle(cornerRadius: 20)
        )
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
