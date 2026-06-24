import SwiftUI

struct ItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: ChecklistItem
    @State private var reminderEnabled: Bool
    @State private var reminderTime: Date
    let onSave: (ChecklistItem) -> Void
    var onDelete: ((ChecklistItem) -> Void)?

    init(item: ChecklistItem, onSave: @escaping (ChecklistItem) -> Void, onDelete: ((ChecklistItem) -> Void)? = nil) {
        _item = State(initialValue: item)
        _reminderEnabled = State(initialValue: item.reminderMinutes != nil)
        var components = DateComponents()
        components.hour = (item.reminderMinutes ?? 9 * 60) / 60
        components.minute = (item.reminderMinutes ?? 9 * 60) % 60
        _reminderTime = State(initialValue: Calendar.current.date(from: components) ?? .now)
        self.onSave = onSave
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

                Section("Reminder") {
                    Toggle("Remind me", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    }
                }

                if let onDelete {
                    Section {
                        Button("Delete item", role: .destructive) {
                            onDelete(item)
                            dismiss()
                        }
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
                        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(item)
                        dismiss()
                    }
                    .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
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
                    Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
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

