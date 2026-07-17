import SwiftUI

private enum ScheduleEditorMode: String, CaseIterable, Identifiable {
    case everyDay
    case weekdays
    case weekends
    case selectedWeekdays
    case interval
    case monthlyDay
    case monthlyOrdinal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyDay: "Every day"
        case .weekdays: "Weekdays"
        case .weekends: "Weekends"
        case .selectedWeekdays: "Selected weekdays"
        case .interval: "Every N days or weeks"
        case .monthlyDay: "Day of month"
        case .monthlyOrdinal: "Ordinal weekday"
        }
    }

    init(item: ChecklistItem) {
        if let recurrence = item.recurrence {
            switch recurrence.kind {
            case .interval: self = .interval
            case .monthlyDay: self = .monthlyDay
            case .monthlyOrdinal: self = .monthlyOrdinal
            }
            return
        }
        switch item.schedule {
        case .everyDay: self = .everyDay
        case .weekdays: self = .weekdays
        case .weekends: self = .weekends
        case .custom: self = .selectedWeekdays
        }
    }
}

struct ItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: ChecklistItem
    @State private var reminderEnabled: Bool
    @State private var reminderTime: Date
    @State private var scheduleMode: ScheduleEditorMode
    @State private var startDateEnabled: Bool
    @State private var startDate: Date
    @State private var endDateEnabled: Bool
    @State private var endDate: Date
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var availableGroups: [ChecklistGroup]
    @State private var didManuallyChooseMissedBehavior = false
    private let isNewItem: Bool
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
        _scheduleMode = State(initialValue: ScheduleEditorMode(item: item))
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
        isNewItem = onDelete == nil
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
                    Stepper(value: $item.quantity, in: 1...99) {
                        LabeledContent("Quantity", value: "\(item.quantity)")
                    }
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
                    Picker("Schedule", selection: $scheduleMode) {
                        ForEach(ScheduleEditorMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if scheduleMode == .selectedWeekdays {
                        weekdayPicker
                    }
                    recurrenceControls
                }

                if scheduleMode != .everyDay {
                    Section {
                        Toggle("Keep visible until handled", isOn: Binding(
                            get: { item.missedBehavior == .keepUntilDone },
                            set: { enabled in
                                didManuallyChooseMissedBehavior = true
                                item.missedBehavior = enabled ? .keepUntilDone : .markMissed
                                if enabled {
                                    item.carryoverStartDate = DateKey.string(from: .now)
                                }
                            }
                        ))
                    } header: {
                        Text("If missed")
                    } footer: {
                        Text("Missed occurrences stay in Still Open until completed, skipped, or deferred. Turn this off to count them as missed normally.")
                    }
                }

                Section("Upcoming") {
                    Text(previewItem.scheduleSummary)
                        .font(.subheadline.weight(.semibold))
                    let dates = previewItem.nextScheduledDates(startingAt: .now, count: 5)
                    if dates.isEmpty {
                        Text("No upcoming occurrences within the active dates.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(dates.enumerated()), id: \.offset) { entry in
                            Text(entry.element.formatted(date: .abbreviated, time: .omitted))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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
                        if item.schedule == .custom,
                           item.recurrence == nil,
                           item.customWeekdays.isEmpty {
                            item.customWeekdays = [Calendar.current.component(.weekday, from: .now)]
                        }
                        if item.schedule == .everyDay {
                            item.missedBehavior = .markMissed
                        } else if item.missedBehavior == .keepUntilDone,
                                  item.carryoverStartDate == nil {
                            item.carryoverStartDate = DateKey.string(from: .now)
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
            .onChange(of: scheduleMode) { _, newValue in
                configureSchedule(for: newValue)
            }
            .onChange(of: item.customWeekdays) { _, weekdays in
                guard isNewItem,
                      scheduleMode == .selectedWeekdays,
                      !didManuallyChooseMissedBehavior else { return }
                item.missedBehavior = weekdays.count <= 1 ? .keepUntilDone : .markMissed
                if item.missedBehavior == .keepUntilDone {
                    item.carryoverStartDate = item.carryoverStartDate ?? DateKey.string(from: .now)
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

    private var previewItem: ChecklistItem {
        var preview = item
        let calendar = Calendar.current
        preview.startDate = startDateEnabled ? calendar.startOfDay(for: startDate) : nil
        if endDateEnabled {
            preview.endedAt = calendar.date(
                byAdding: .day,
                value: 1,
                to: max(calendar.startOfDay(for: endDate), minimumEndDate)
            )
        } else {
            preview.endedAt = nil
        }
        return preview
    }

    @ViewBuilder
    private var recurrenceControls: some View {
        switch scheduleMode {
        case .interval:
            Picker("Unit", selection: recurrenceUnit) {
                Text("Days").tag(RecurrenceRule.IntervalUnit.day)
                Text("Weeks").tag(RecurrenceRule.IntervalUnit.week)
            }
            .pickerStyle(.segmented)
            Stepper(value: recurrenceInterval, in: recurrenceUnit.wrappedValue == .week ? 1...52 : 1...365) {
                LabeledContent("Every", value: "\(recurrenceInterval.wrappedValue) \(recurrenceUnit.wrappedValue == .week ? "week" : "day")\(recurrenceInterval.wrappedValue == 1 ? "" : "s")")
            }
            DatePicker("Anchor date", selection: recurrenceAnchorDate, displayedComponents: .date)

        case .monthlyDay:
            Stepper(value: recurrenceInterval, in: 1...24) {
                LabeledContent("Every", value: recurrenceInterval.wrappedValue == 1 ? "Month" : "\(recurrenceInterval.wrappedValue) months")
            }
            Stepper(value: recurrenceDayOfMonth, in: 1...31) {
                LabeledContent("Day", value: "\(recurrenceDayOfMonth.wrappedValue)")
            }
            DatePicker("Cycle anchor", selection: recurrenceAnchorDate, displayedComponents: .date)

        case .monthlyOrdinal:
            Stepper(value: recurrenceInterval, in: 1...24) {
                LabeledContent("Every", value: recurrenceInterval.wrappedValue == 1 ? "Month" : "\(recurrenceInterval.wrappedValue) months")
            }
            Picker("Occurrence", selection: recurrenceOrdinal) {
                ForEach([-1, 1, 2, 3, 4], id: \.self) { ordinal in
                    Text(RecurrenceRule.ordinalNames[ordinal] ?? "First").tag(ordinal)
                }
            }
            Picker("Weekday", selection: recurrenceWeekday) {
                ForEach(1...7, id: \.self) { weekday in
                    Text(RecurrenceRule.weekdayNames[weekday - 1]).tag(weekday)
                }
            }
            DatePicker("Cycle anchor", selection: recurrenceAnchorDate, displayedComponents: .date)

        case .everyDay, .weekdays, .weekends, .selectedWeekdays:
            EmptyView()
        }
    }

    private var recurrenceInterval: Binding<Int> {
        Binding(
            get: { item.recurrence?.interval ?? 1 },
            set: { value in
                guard var recurrence = item.recurrence else { return }
                recurrence.interval = value
                item.recurrence = recurrence.normalized
            }
        )
    }

    private var recurrenceUnit: Binding<RecurrenceRule.IntervalUnit> {
        Binding(
            get: { item.recurrence?.unit ?? .day },
            set: { value in
                guard var recurrence = item.recurrence else { return }
                recurrence.unit = value
                item.recurrence = recurrence.normalized
            }
        )
    }

    private var recurrenceDayOfMonth: Binding<Int> {
        Binding(
            get: { item.recurrence?.dayOfMonth ?? 1 },
            set: { value in
                guard var recurrence = item.recurrence else { return }
                recurrence.dayOfMonth = value
                item.recurrence = recurrence.normalized
            }
        )
    }

    private var recurrenceOrdinal: Binding<Int> {
        Binding(
            get: { item.recurrence?.ordinal ?? 1 },
            set: { value in
                guard var recurrence = item.recurrence else { return }
                recurrence.ordinal = value
                item.recurrence = recurrence.normalized
            }
        )
    }

    private var recurrenceWeekday: Binding<Int> {
        Binding(
            get: { item.recurrence?.weekday ?? 1 },
            set: { value in
                guard var recurrence = item.recurrence else { return }
                recurrence.weekday = value
                item.recurrence = recurrence.normalized
            }
        )
    }

    private var recurrenceAnchorDate: Binding<Date> {
        Binding(
            get: { item.recurrence.flatMap { DateKey.date(from: $0.anchorDate) } ?? .now },
            set: { value in
                guard var recurrence = item.recurrence else { return }
                recurrence.anchorDate = DateKey.string(from: value)
                item.recurrence = recurrence.normalized
            }
        )
    }

    private func configureSchedule(for mode: ScheduleEditorMode) {
        let anchor = startDateEnabled ? startDate : Date.now
        switch mode {
        case .everyDay:
            item.schedule = .everyDay
            item.customWeekdays = []
            item.recurrence = nil
            item.missedBehavior = .markMissed
        case .weekdays:
            item.schedule = .weekdays
            item.customWeekdays = []
            item.recurrence = nil
        case .weekends:
            item.schedule = .weekends
            item.customWeekdays = []
            item.recurrence = nil
        case .selectedWeekdays:
            item.schedule = .custom
            item.recurrence = nil
            if item.customWeekdays.isEmpty {
                item.customWeekdays = [Calendar.current.component(.weekday, from: .now)]
            }
        case .interval:
            item.schedule = .custom
            item.customWeekdays = []
            if item.recurrence?.kind != .interval {
                item.recurrence = .every(2, unit: .day, anchoredOn: anchor)
            }
        case .monthlyDay:
            item.schedule = .custom
            item.customWeekdays = []
            if item.recurrence?.kind != .monthlyDay {
                item.recurrence = .monthly(
                    dayOfMonth: Calendar.current.component(.day, from: anchor),
                    anchoredOn: anchor
                )
            }
        case .monthlyOrdinal:
            item.schedule = .custom
            item.customWeekdays = []
            if item.recurrence?.kind != .monthlyOrdinal {
                item.recurrence = .monthly(
                    ordinal: 1,
                    weekday: Calendar.current.component(.weekday, from: anchor),
                    anchoredOn: anchor
                )
            }
        }

        if isNewItem, mode != .everyDay, !didManuallyChooseMissedBehavior {
            item.missedBehavior = [.selectedWeekdays, .interval, .monthlyDay, .monthlyOrdinal].contains(mode)
                ? .keepUntilDone
                : .markMissed
            if item.missedBehavior == .keepUntilDone {
                item.carryoverStartDate = item.carryoverStartDate ?? DateKey.string(from: .now)
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
                    Text("Ritual Cue will tell you how many scheduled tasks are still unfinished.")
                }

                Section("Sync") {
                    LabeledContent("Status", value: store.syncState)
                    Text("Your checklist is cached on this iPhone and synced to the Ritual Cue server.")
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
