import SwiftUI

struct ItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: ChecklistItem
    @State private var reminderEnabled: Bool
    @State private var reminderTime: Date
    @State private var startDateEnabled: Bool
    @State private var startDate: Date
    @State private var endDateEnabled: Bool
    @State private var endDate: Date
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var availableGroups: [ChecklistGroup]
    let onSave: (ChecklistItem) -> Void
    let onCreateGroup: (String) -> ChecklistGroup?
    var onDelete: ((ChecklistItem) -> Void)?

    init(
        item: ChecklistItem,
        groups: [ChecklistGroup],
        onSave: @escaping (ChecklistItem) -> Void,
        onCreateGroup: @escaping (String) -> ChecklistGroup?,
        onDelete: ((ChecklistItem) -> Void)? = nil
    ) {
        let calendar = Calendar.current
        _item = State(initialValue: item)
        _reminderEnabled = State(initialValue: item.reminderMinutes != nil)
        var components = DateComponents()
        components.hour = (item.reminderMinutes ?? 9 * 60) / 60
        components.minute = (item.reminderMinutes ?? 9 * 60) % 60
        _reminderTime = State(initialValue: calendar.date(from: components) ?? .now)
        _startDateEnabled = State(initialValue: item.startDate != nil)
        _startDate = State(initialValue: calendar.startOfDay(for: item.startDate ?? item.createdAt))
        _endDateEnabled = State(initialValue: item.endedAt != nil)
        _endDate = State(
            initialValue: item.endedAt.flatMap {
                calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: $0))
            } ?? calendar.startOfDay(for: .now)
        )
        _availableGroups = State(initialValue: groups)
        self.onSave = onSave
        self.onCreateGroup = onCreateGroup
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $item.title)
                        .font(.headline)
                    TextField("Notes (optional)", text: $item.notes, axis: .vertical)
                        .lineLimit(2...5)
                    Menu {
                        Button {
                            item.groupID = nil
                        } label: {
                            Label("No group", systemImage: item.groupID == nil ? "checkmark" : "tray")
                        }
                        ForEach(availableGroups) { group in
                            Button {
                                item.groupID = group.id
                            } label: {
                                Label(
                                    group.name,
                                    systemImage: item.groupID == group.id ? "checkmark" : "folder"
                                )
                            }
                        }
                        Divider()
                        Button {
                            newGroupName = ""
                            showingNewGroup = true
                        } label: {
                            Label("New group…", systemImage: "plus")
                        }
                    } label: {
                        LabeledContent("Group", value: selectedGroupName)
                    }
                }

                Section("Repeats") {
                    Picker("Schedule", selection: $item.schedule) {
                        ForEach(ScheduleKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    if item.schedule == .custom {
                        weekdayPicker
                    }
                }

                Section {
                    Toggle("Start date", isOn: $startDateEnabled)
                    if startDateEnabled {
                        DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                    }
                    Toggle("End date", isOn: $endDateEnabled)
                    if endDateEnabled {
                        DatePicker(
                            "Ends",
                            selection: $endDate,
                            in: minimumEndDate...Date.distantFuture,
                            displayedComponents: .date
                        )
                    }
                } header: {
                    Text("Active dates")
                } footer: {
                    Text("The task appears from its start date through its end date. Leave either date off when there is no limit.")
                }

                Section("Reminder") {
                    Toggle("Remind me", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    }
                }

                if let onDelete {
                    Section {
                        Button("End item today", role: .destructive) {
                            onDelete(item)
                            dismiss()
                        }
                    } footer: {
                        Text("Stops showing this task today while keeping its previous history.")
                    }
                }
            }
            .navigationTitle(onDelete == nil ? "New item" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if reminderEnabled {
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
                            item.reminderMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                        } else {
                            item.reminderMinutes = nil
                        }
                        if item.schedule == .custom, item.customWeekdays.isEmpty {
                            item.customWeekdays = [Calendar.current.component(.weekday, from: .now)]
                        }
                        let calendar = Calendar.current
                        item.startDate = startDateEnabled ? calendar.startOfDay(for: startDate) : nil
                        if endDateEnabled {
                            let lastDay = max(calendar.startOfDay(for: endDate), minimumEndDate)
                            item.endedAt = calendar.date(byAdding: .day, value: 1, to: lastDay)
                        } else {
                            item.endedAt = nil
                        }
                        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(item)
                        dismiss()
                    }
                    .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .onChange(of: startDate) { _, newValue in
                if endDateEnabled, endDate < newValue {
                    endDate = newValue
                }
            }
            .onChange(of: startDateEnabled) { _, enabled in
                if enabled, endDateEnabled, endDate < startDate {
                    endDate = startDate
                }
            }
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Group name", text: $newGroupName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    if let group = onCreateGroup(newGroupName) {
                        if !availableGroups.contains(where: { $0.id == group.id }) {
                            availableGroups.append(group)
                            availableGroups.sort { $0.sortOrder < $1.sortOrder }
                        }
                        item.groupID = group.id
                    }
                }
                .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Create a group and assign this task to it.")
            }
        }
    }

    private var selectedGroupName: String {
        guard let groupID = item.groupID else { return "No group" }
        return availableGroups.first(where: { $0.id == groupID })?.name ?? "No group"
    }

    private var minimumEndDate: Date {
        Calendar.current.startOfDay(for: startDateEnabled ? startDate : item.createdAt)
    }

    private var weekdayPicker: some View {
        HStack {
            ForEach(1...7, id: \.self) { day in
                let selected = item.customWeekdays.contains(day)
                Button {
                    if selected {
                        item.customWeekdays.remove(day)
                    } else {
                        item.customWeekdays.insert(day)
                    }
                } label: {
                    Text(WeekdayAbbreviation.twoLetter[day - 1])
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(selected ? .white : .secondary)
                        .frame(width: 34, height: 34)
                        .background(selected ? accent : Color.secondary.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct EveningReminderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ChecklistStore
    @State private var enabled = true
    @State private var time = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Evening check-in", isOn: $enabled)
                    if enabled {
                        DatePicker("Alert time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("Daily will tell you how many scheduled tasks are still unfinished.")
                }

                Section("Sync") {
                    LabeledContent("Status", value: store.syncState)
                    Text("Your checklist is cached on this iPhone and synced to the Daily server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if enabled {
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                            store.updateEveningReminder((parts.hour ?? 20) * 60 + (parts.minute ?? 0))
                        } else {
                            store.updateEveningReminder(nil)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                enabled = store.eveningReminderMinutes != nil
                let minutes = store.eveningReminderMinutes ?? 20 * 60
                time = Calendar.current.date(from: DateComponents(hour: minutes / 60, minute: minutes % 60)) ?? .now
            }
        }
    }
}
