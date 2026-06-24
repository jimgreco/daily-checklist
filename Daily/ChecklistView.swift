import SwiftUI
import UniformTypeIdentifiers

let ink = Color(red: 0.10, green: 0.12, blue: 0.16)
let accent = Color(red: 0.38, green: 0.33, blue: 0.92)
let canvas = Color(red: 0.965, green: 0.958, blue: 0.94)

struct ChecklistView: View {
    @EnvironmentObject private var store: ChecklistStore
    @State private var editingItem: ChecklistItem?
    @State private var showingNewItem = false
    @State private var showingSettings = false
    @State private var showingAccount = false
    @State private var draggingItemID: UUID?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                canvas.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                        filter
                            .padding(.top, 22)
                        sortControl
                            .padding(.top, 14)
                        section(
                            title: "TO DO",
                            items: store.todoItems,
                            emptyText: "Nothing left for now",
                            showsCompleteAll: store.showingToday && !store.todoItems.isEmpty
                        )
                            .padding(.top, 20)
                        section(title: "COMPLETED", items: store.completedItems, emptyText: nil)
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
                ItemEditor(item: ChecklistItem(title: "")) { store.save($0) }
            }
            .sheet(item: $editingItem) { item in
                ItemEditor(item: item, onSave: { store.save($0) }, onDelete: { store.delete($0) })
            }
            .sheet(isPresented: $showingSettings) {
                EveningReminderView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingAccount) {
                AccountView()
                    .environmentObject(store)
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
                        .background(.white.opacity(0.8), in: Circle())
                }
                .accessibilityLabel("Previous day")

                Spacer()

                Button {
                    withAnimation(.snappy) { store.moveSelectedDate(by: 1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.8), in: Circle())
                }
                .accessibilityLabel("Next day")
            }

            HStack(alignment: .top) {
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
            HStack(spacing: 10) {
                Button { showingAccount = true } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.8), in: Circle())
                }
                Button { showingSettings = true } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.8), in: Circle())
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
        .background(Color.black.opacity(0.055), in: Capsule())
    }

    private var sortControl: some View {
        HStack {
            Spacer()
            Menu {
                ForEach(ChecklistSort.allCases) { option in
                    Button {
                        withAnimation(.snappy) {
                            store.sortMode = option
                            draggingItemID = nil
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
                .background(.white.opacity(0.78), in: Capsule())
            }
            .accessibilityLabel("Sort checklist")
            .accessibilityValue(store.sortMode.title)
        }
    }

    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? ink : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? Color.white : Color.clear, in: Capsule())
                .shadow(color: selected ? .black.opacity(0.06) : .clear, radius: 8, y: 3)
        }
    }

    private func section(
        title: String,
        items: [ChecklistItem],
        emptyText: String?,
        showsCompleteAll: Bool = false
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
                        Label("Complete all", systemImage: "checkmark.circle.fill")
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
                .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 22))
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        if store.sortMode == .manual {
                            ItemRow(
                                item: item,
                                date: store.selectedDate,
                                showsDragHandle: true,
                                onToggle: { store.toggle(item) },
                                onEdit: { editingItem = item }
                            )
                            .opacity(draggingItemID == item.id ? 0.55 : 1)
                            .onDrag {
                                draggingItemID = item.id
                                return NSItemProvider(object: item.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: ChecklistItemDropDelegate(
                                    targetID: item.id,
                                    sectionIDs: items.map(\.id),
                                    draggingItemID: $draggingItemID,
                                    move: store.move
                                )
                            )
                        } else {
                            ItemRow(
                                item: item,
                                date: store.selectedDate,
                                showsDragHandle: false,
                                onToggle: { store.toggle(item) },
                                onEdit: { editingItem = item }
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct ItemRow: View {
    let item: ChecklistItem
    let date: Date
    let showsDragHandle: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void

    private var completed: Bool { item.isComplete(on: date) }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .stroke(completed ? accent : Color.black.opacity(0.18), lineWidth: 2)
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
                Text(item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(completed ? .secondary : ink)
                    .strikethrough(completed, color: .secondary)
                HStack(spacing: 8) {
                    Label(item.scheduleSummary, systemImage: "repeat")
                    if let minutes = item.reminderMinutes {
                        Label(timeString(minutes), systemImage: "bell.fill")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .frame(width: 24, height: 36)
                    .accessibilityHidden(true)
            }
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.045), in: Circle())
            }
            .accessibilityLabel("Edit \(item.title)")
        }
        .padding(16)
        .background(.white.opacity(completed ? 0.5 : 0.88), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct ChecklistItemDropDelegate: DropDelegate {
    let targetID: UUID
    let sectionIDs: [UUID]
    @Binding var draggingItemID: UUID?
    let move: (UUID, UUID, [UUID]) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingItemID, draggingItemID != targetID else { return }
        move(draggingItemID, targetID, sectionIDs)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
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
