import XCTest
@testable import Daily

final class ChecklistStateTests: XCTestCase {
    private var calendar: Calendar {
        Calendar.current
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "activeAccountID")
        super.tearDown()
    }

    func testExplicitOpenMakesOffDateTracked() {
        let today = calendar.startOfDay(for: Date())
        let key = DateKey.string(from: today)
        let item = ChecklistItem(
            title: "Optional task",
            schedule: .custom,
            customWeekdays: [],
            openDates: [key],
            createdAt: today
        )

        XCTAssertFalse(item.occurs(on: today, calendar: calendar))
        XCTAssertTrue(item.isTracked(on: today, calendar: calendar))
        XCTAssertEqual(item.historyState(on: today, calendar: calendar), .open)
    }

    func testBackfilledDoneDatesBeforeCreationCountTowardCompletionStreak() throws {
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let twoDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let item = ChecklistItem(
            title: "Backfilled task",
            schedule: .custom,
            customWeekdays: [],
            completedDates: [
                DateKey.string(from: yesterday),
                DateKey.string(from: twoDaysAgo)
            ],
            createdAt: today
        )

        XCTAssertEqual(item.firstTrackedDate(calendar: calendar), twoDaysAgo)
        XCTAssertEqual(item.consecutiveCompletedDays(asOf: today, calendar: calendar), 2)
    }

    func testExplicitOpenWithoutDoneBreaksCompletionStreak() throws {
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let twoDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let item = ChecklistItem(
            title: "Open task",
            schedule: .custom,
            customWeekdays: [],
            completedDates: [DateKey.string(from: twoDaysAgo)],
            openDates: [DateKey.string(from: yesterday)],
            createdAt: today
        )

        XCTAssertEqual(item.consecutiveCompletedDays(asOf: today, calendar: calendar), 0)
        XCTAssertEqual(item.historyState(on: yesterday, calendar: calendar), .open)
    }

    func testDelaySkipsSourceDateAndOpensNextDate() throws {
        let sourceDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24)))
        let nextDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: sourceDate))
        let sourceKey = DateKey.string(from: sourceDate)
        let nextKey = DateKey.string(from: nextDate)
        var item = ChecklistItem(
            title: "Water plants",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: sourceDate)],
            completedDates: [nextKey],
            createdAt: sourceDate
        )

        let change = try item.delay(from: sourceDate, calendar: calendar)

        XCTAssertEqual(change.sourceKey, sourceKey)
        XCTAssertEqual(change.targetKey, nextKey)
        XCTAssertTrue(item.skippedDates.contains(sourceKey))
        XCTAssertFalse(item.completedDates.contains(sourceKey))
        XCTAssertTrue(item.openDates.contains(nextKey))
        XCTAssertFalse(item.completedDates.contains(nextKey))
        XCTAssertFalse(item.skippedDates.contains(nextKey))
        XCTAssertEqual(item.historyState(on: sourceDate, calendar: calendar), .skipped)
        XCTAssertEqual(item.historyState(on: nextDate, calendar: calendar), .open)
        XCTAssertEqual(item.delayedDays(asOf: nextDate, calendar: calendar), 1)
        XCTAssertEqual(item.delayedDays(asOf: sourceDate, calendar: calendar), 0)
    }

    func testDailyItemsCannotBeDelayed() {
        var item = ChecklistItem(title: "Take vitamins", schedule: .everyDay)

        XCTAssertThrowsError(try item.delay(from: Date(), calendar: calendar)) { error in
            XCTAssertEqual(error as? ChecklistDelayError, .dailyItem)
        }
    }

    func testBringForwardSkipsFutureDateAndOpensToday() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24)))
        let futureDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: today))
        let todayKey = DateKey.string(from: today)
        let futureKey = DateKey.string(from: futureDate)
        var item = ChecklistItem(
            title: "Water plants",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: futureDate)],
            completedDates: [todayKey],
            createdAt: today
        )

        let change = try item.bringForward(from: futureDate, to: today, calendar: calendar)

        XCTAssertEqual(change.sourceKey, futureKey)
        XCTAssertEqual(change.targetKey, todayKey)
        XCTAssertTrue(item.skippedDates.contains(futureKey))
        XCTAssertFalse(item.completedDates.contains(futureKey))
        XCTAssertTrue(item.openDates.contains(todayKey))
        XCTAssertFalse(item.completedDates.contains(todayKey))
        XCTAssertFalse(item.skippedDates.contains(todayKey))
        XCTAssertEqual(item.historyState(on: futureDate, calendar: calendar), .skipped)
        XCTAssertEqual(item.historyState(on: today, calendar: calendar), .open)
    }

    func testDailyItemsCannotBeBroughtForward() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24)))
        let futureDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        var item = ChecklistItem(title: "Take vitamins", schedule: .everyDay)

        XCTAssertThrowsError(try item.bringForward(from: futureDate, to: today, calendar: calendar)) { error in
            XCTAssertEqual(error as? ChecklistBringForwardError, .dailyItem)
        }
    }

    func testRepeatedDelayCountsConsecutiveSkippedDays() throws {
        let sourceDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24)))
        let secondDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: sourceDate))
        let thirdDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: sourceDate))
        var item = ChecklistItem(
            title: "Water plants",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: sourceDate)],
            createdAt: sourceDate
        )

        _ = try item.delay(from: sourceDate, calendar: calendar)
        _ = try item.delay(from: secondDate, calendar: calendar)

        XCTAssertEqual(item.delayedDays(asOf: thirdDate, calendar: calendar), 2)
        XCTAssertEqual(item.historyState(on: sourceDate, calendar: calendar), .skipped)
        XCTAssertEqual(item.historyState(on: secondDate, calendar: calendar), .skipped)
        XCTAssertEqual(item.historyState(on: thirdDate, calendar: calendar), .open)
    }

    func testPausedDatesAreNotMissed() throws {
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let twoDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        var item = ChecklistItem(title: "Take vitamins", schedule: .everyDay, createdAt: twoDaysAgo)

        item.pause(from: yesterday, until: yesterday)

        XCTAssertFalse(item.occurs(on: yesterday, calendar: calendar))
        XCTAssertTrue(item.isTracked(on: yesterday, calendar: calendar))
        XCTAssertEqual(item.historyState(on: yesterday, calendar: calendar), .paused)
        XCTAssertEqual(item.consecutiveMissedDays(asOf: today, calendar: calendar), 1)
    }

    func testIntervalRecurrenceUsesCalendarDaysAcrossDST() throws {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let anchor = try XCTUnwrap(DateKey.date(from: "2026-03-07", calendar: eastern))
        let rule = RecurrenceRule(
            kind: .interval,
            interval: 2,
            anchorDate: "2026-03-07",
            unit: .day
        )
        let everyTwoWeeks = RecurrenceRule(
            kind: .interval,
            interval: 2,
            anchorDate: "2026-03-07",
            unit: .week
        )
        let item = ChecklistItem(
            title: "Water plants",
            schedule: .custom,
            recurrence: rule,
            createdAt: anchor,
            startDate: anchor
        )

        XCTAssertTrue(item.isScheduled(on: anchor, calendar: eastern))
        XCTAssertFalse(item.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2026-03-08", calendar: eastern)),
            calendar: eastern
        ))
        XCTAssertTrue(item.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2026-03-09", calendar: eastern)),
            calendar: eastern
        ))
        XCTAssertFalse(everyTwoWeeks.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2026-03-14", calendar: eastern)),
            calendar: eastern
        ))
        XCTAssertTrue(everyTwoWeeks.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2026-03-21", calendar: eastern)),
            calendar: eastern
        ))
        XCTAssertEqual(
            item.nextScheduledDates(startingAt: anchor, count: 4, calendar: eastern).map {
                let parts = eastern.dateComponents([.year, .month, .day], from: $0)
                return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            },
            ["2026-03-07", "2026-03-09", "2026-03-11", "2026-03-13"]
        )
    }

    func testMonthlyRecurrenceClampsMonthEndsAndHandlesLeapYears() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let monthly = RecurrenceRule(
            kind: .monthlyDay,
            interval: 1,
            anchorDate: "2024-01-31",
            dayOfMonth: 31
        )
        let quarterly = RecurrenceRule(
            kind: .monthlyDay,
            interval: 3,
            anchorDate: "2024-01-31",
            dayOfMonth: 31
        )

        XCTAssertEqual(monthly.summary, "Monthly on day 31 (last day in shorter months)")

        for key in ["2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30", "2025-02-28"] {
            XCTAssertTrue(monthly.isScheduled(
                on: try XCTUnwrap(DateKey.date(from: key, calendar: utc)),
                calendar: utc
            ), key)
        }
        XCTAssertFalse(monthly.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2024-02-28", calendar: utc)),
            calendar: utc
        ))
        XCTAssertFalse(quarterly.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2024-02-29", calendar: utc)),
            calendar: utc
        ))
        XCTAssertTrue(quarterly.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2024-04-30", calendar: utc)),
            calendar: utc
        ))
    }

    func testMonthlyOrdinalRecurrenceSupportsSecondAndLastWeekdays() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let secondTuesday = RecurrenceRule(
            kind: .monthlyOrdinal,
            interval: 1,
            anchorDate: "2026-01-01",
            ordinal: 2,
            weekday: 3
        )
        let lastSaturday = RecurrenceRule(
            kind: .monthlyOrdinal,
            interval: 1,
            anchorDate: "2026-01-01",
            ordinal: -1,
            weekday: 7
        )

        XCTAssertTrue(secondTuesday.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2026-01-13", calendar: utc)),
            calendar: utc
        ))
        XCTAssertFalse(secondTuesday.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2026-01-06", calendar: utc)),
            calendar: utc
        ))
        XCTAssertTrue(lastSaturday.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2026-01-31", calendar: utc)),
            calendar: utc
        ))
        XCTAssertTrue(lastSaturday.isScheduled(
            on: try XCTUnwrap(DateKey.date(from: "2026-02-28", calendar: utc)),
            calendar: utc
        ))
    }

    func testRecurrenceRespectsActiveAndPauseBoundaries() throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        let due = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 31)))
        let beforeStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 28)))
        let afterEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 30)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 1)))
        var item = ChecklistItem(
            title: "Month-end close",
            schedule: .custom,
            recurrence: RecurrenceRule(
                kind: .monthlyDay,
                interval: 1,
                anchorDate: "2026-01-31",
                dayOfMonth: 31
            ),
            createdAt: start,
            startDate: start,
            endedAt: end
        )
        item.pause(from: due, until: due)

        XCTAssertFalse(item.isScheduled(on: beforeStart, calendar: calendar))
        XCTAssertTrue(item.isScheduled(on: due, calendar: calendar))
        XCTAssertFalse(item.occurs(on: due, calendar: calendar))
        XCTAssertFalse(item.isScheduled(on: afterEnd, calendar: calendar))
        XCTAssertTrue(item.nextScheduledDates(
            startingAt: beforeStart,
            count: 1,
            calendar: calendar
        ).isEmpty)
    }

    @MainActor
    func testRoutineInsightsSummarizeCompletionTrendStreakMissesAndDelays() throws {
        let accountID = "routine-insights-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let completedOffsets = Set([1, 2, 3, 4, 5, 6, 8, 9, 10])
        let completedDates = Set(completedOffsets.compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map(DateKey.string(from:))
        })
        let startDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -14, to: today))
        let tracked = ChecklistItem(
            title: "Morning routine",
            schedule: .everyDay,
            completedDates: completedDates,
            createdAt: startDate,
            startDate: startDate
        )

        let firstSkipped = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let secondSkipped = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let delayedItem = ChecklistItem(
            title: "Water plants",
            schedule: .custom,
            customWeekdays: [],
            skippedDates: [DateKey.string(from: firstSkipped), DateKey.string(from: secondSkipped)],
            openDates: [DateKey.string(from: today)],
            createdAt: firstSkipped
        )

        let store = ChecklistStore()
        store.save(tracked)
        store.save(delayedItem)

        let summary = store.routineInsights(asOf: today, calendar: calendar)

        XCTAssertTrue(summary.hasEnoughData)
        XCTAssertEqual(summary.completedCheckIns, 9)
        XCTAssertEqual(summary.expectedCheckIns, 14)
        XCTAssertEqual(summary.completionPercentage, 64)
        XCTAssertEqual(summary.trendPercentagePoints, 43)
        XCTAssertEqual(summary.currentStreak, RoutineInsightHighlight(title: "Morning routine", count: 6))
        XCTAssertEqual(summary.longestDelay, RoutineInsightHighlight(title: "Water plants", count: 2))
        XCTAssertEqual(summary.missedWeekdayCount, 2)
        XCTAssertNotNil(summary.missedWeekday)
    }

    @MainActor
    func testRoutineInsightsUseCalmLowDataState() {
        let accountID = "routine-insights-empty-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let store = ChecklistStore()
        store.save(ChecklistItem(title: "New routine", createdAt: today, startDate: today))

        let summary = store.routineInsights(asOf: today, calendar: calendar)

        XCTAssertFalse(summary.hasEnoughData)
        XCTAssertEqual(summary.expectedCheckIns, 0)
        XCTAssertEqual(summary.completionPercentage, 0)
    }

    func testNotificationGroupFilterIncludesAndExcludesGroups() {
        let mustDoGroup = UUID()
        let nightGroup = UUID()
        let mustDoItem = ChecklistItem(title: "Medication", groupID: mustDoGroup)
        let nightItem = ChecklistItem(title: "Skincare", groupID: nightGroup)
        let ungroupedItem = ChecklistItem(title: "Loose task")

        let include = NotificationGroupFilter(mode: .include, groupIDs: [mustDoGroup])
        XCTAssertTrue(include.includes(item: mustDoItem))
        XCTAssertFalse(include.includes(item: nightItem))
        XCTAssertFalse(include.includes(item: ungroupedItem))

        let exclude = NotificationGroupFilter(mode: .exclude, groupIDs: [nightGroup])
        XCTAssertTrue(exclude.includes(item: mustDoItem))
        XCTAssertFalse(exclude.includes(item: nightItem))
        XCTAssertTrue(exclude.includes(item: ungroupedItem))

        let normalized = NotificationGroupFilter(mode: .include, groupIDs: [mustDoGroup, nightGroup])
            .normalized(availableGroupIDs: [mustDoGroup])
        XCTAssertEqual(normalized.groupIDs, [mustDoGroup])
    }

    @MainActor
    func testPausedGroupIsHiddenFromTodayButVisibleInAllItems() throws {
        let accountID = "pause-group-test-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: Date())
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }

        UserDefaults.standard.set(accountID, forKey: "activeAccountID")
        let store = ChecklistStore()
        store.selectedDate = today
        let group = try XCTUnwrap(store.createGroup(named: "Travel"))
        store.save(ChecklistItem(title: "Water plants", createdAt: today, groupID: group.id))

        store.pauseGroup(group.id)

        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertTrue(store.todoItems.isEmpty)
        store.scope = .all
        XCTAssertEqual(store.visibleItems.map(\.title), ["Water plants"])
        XCTAssertTrue(store.isPaused(store.visibleItems[0], on: today))
    }

    @MainActor
    func testQuantityRequiresMultipleCheckoffs() throws {
        let accountID = "quantity-test-\(UUID().uuidString)"
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 5)))
        let todayKey = DateKey.string(from: today)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }

        UserDefaults.standard.set(accountID, forKey: "activeAccountID")
        let store = ChecklistStore()
        store.selectedDate = today
        let item = ChecklistItem(title: "Vitamins", quantity: 3, createdAt: today)
        store.save(item)

        store.toggle(item)
        XCTAssertEqual(store.items.first?.completionCount(on: today), 1)
        XCTAssertFalse(store.items.first?.completedDates.contains(todayKey) == true)

        store.toggle(item)
        XCTAssertEqual(store.items.first?.completionCount(on: today), 2)
        XCTAssertFalse(store.items.first?.completedDates.contains(todayKey) == true)

        store.toggle(item)
        XCTAssertEqual(store.items.first?.completionCount(on: today), 3)
        XCTAssertTrue(store.items.first?.completedDates.contains(todayKey) == true)

        store.toggle(item)
        XCTAssertEqual(store.items.first?.completionCount(on: today), 0)
        XCTAssertFalse(store.items.first?.completedDates.contains(todayKey) == true)
    }

    @MainActor
    func testGroupCollapsedStateTogglesInStore() throws {
        let accountID = "group-collapse-test-\(UUID().uuidString)"
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }

        UserDefaults.standard.set(accountID, forKey: "activeAccountID")
        let store = ChecklistStore()
        let group = try XCTUnwrap(store.createGroup(named: "Home"))

        XCTAssertEqual(store.groups.first?.id, group.id)
        XCTAssertFalse(store.groups.first?.isCollapsed == true)

        store.toggleGroupCollapsed(group.id)
        XCTAssertTrue(store.groups.first?.isCollapsed == true)

        store.toggleGroupCollapsed(group.id)
        XCTAssertFalse(store.groups.first?.isCollapsed == true)
    }

    func testSupportDiagnosticsExcludeSensitiveUserFields() throws {
        let user = AppUser(
            id: "user-123",
            email: "private@example.com",
            name: "Private User",
            profileImageURL: URL(string: "https://example.com/private.jpg")
        )
        let diagnostics = SupportDiagnostics.text(
            user: user,
            syncState: "Changes pending",
            pendingMutationCount: 2,
            deviceID: "device-123",
            apiBaseURL: try XCTUnwrap(URL(string: "https://api.ritualcue.com/app")),
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(diagnostics.contains("Ritual Cue Diagnostics"))
        XCTAssertTrue(diagnostics.contains("User ID: user-123"))
        XCTAssertTrue(diagnostics.contains("Device ID: device-123"))
        XCTAssertTrue(diagnostics.contains("API Origin: https://api.ritualcue.com"))
        XCTAssertTrue(diagnostics.contains("Pending Mutations: 2"))
        XCTAssertFalse(diagnostics.contains("private@example.com"))
        XCTAssertFalse(diagnostics.contains("Private User"))
        XCTAssertFalse(diagnostics.localizedCaseInsensitiveContains("token"))
    }

    @MainActor
    func testWidgetSnapshotCountsTodayWithoutChecklistContent() throws {
        let accountID = "widget-snapshot-test-\(UUID().uuidString)"
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        let today = calendar.startOfDay(for: now)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }

        UserDefaults.standard.set(accountID, forKey: "activeAccountID")
        let store = ChecklistStore()
        store.selectedDate = today

        let remaining = ChecklistItem(title: "Medication", reminderMinutes: 10 * 60, createdAt: today)
        let completed = ChecklistItem(title: "Private completed task", createdAt: today)
        let skipped = ChecklistItem(title: "Private skipped task", createdAt: today)
        let paused = ChecklistItem(
            title: "Private paused task",
            createdAt: today,
            pauseWindows: [PauseWindow(startDate: DateKey.string(from: today), endDate: DateKey.string(from: today))]
        )

        store.save(remaining)
        store.save(completed)
        store.save(skipped)
        store.save(paused)
        store.complete(itemID: completed.id, on: today)
        store.setSkipped(skipped, skipped: true, on: today)

        let snapshot = store.widgetSnapshot(now: now)

        XCTAssertEqual(snapshot.remainingCount, 1)
        XCTAssertEqual(snapshot.scheduledCount, 3)
        XCTAssertEqual(snapshot.completedCount, 1)
        XCTAssertEqual(snapshot.skippedCount, 1)
        XCTAssertEqual(snapshot.reminderMinutes, [10 * 60, 20 * 60])
        XCTAssertEqual(snapshot.nextReminderMinutes, 10 * 60)
        XCTAssertTrue(snapshot.hasChecklist)

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        XCTAssertFalse(encoded.contains("Medication"))
        XCTAssertFalse(encoded.contains("Private completed task"))
        XCTAssertFalse(encoded.contains("Private skipped task"))
        XCTAssertFalse(encoded.contains("Private paused task"))
    }

    @MainActor
    func testWidgetSnapshotIncludesAdvancedRecurrenceDueToday() throws {
        let accountID = "widget-recurrence-test-\(UUID().uuidString)"
        let now = calendar.startOfDay(for: .now)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let store = ChecklistStore()
        store.save(ChecklistItem(
            title: "Advanced interval",
            schedule: .custom,
            recurrence: RecurrenceRule(
                kind: .interval,
                interval: 2,
                anchorDate: DateKey.string(from: now),
                unit: .day
            ),
            createdAt: now,
            startDate: now
        ))

        let snapshot = store.widgetSnapshot(now: now)
        XCTAssertEqual(snapshot.scheduledCount, 1)
        XCTAssertEqual(snapshot.remainingCount, 1)
    }

    @MainActor
    func testReturningAuthenticatedAccountKeepsExistingLocalProgressCache() throws {
        let accountID = "test-user-\(UUID().uuidString)"
        let itemID = UUID()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 5)))
        let todayKey = DateKey.string(from: today)
        cleanCaches(for: [accountID, "anonymous"])
        defer {
            cleanCaches(for: [accountID, "anonymous"])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }

        UserDefaults.standard.set(accountID, forKey: "activeAccountID")
        let store = ChecklistStore()
        store.selectedDate = today
        let item = ChecklistItem(id: itemID, title: "Morning progress", createdAt: today)
        store.save(item)
        store.toggle(item)

        store.activateAnonymousAccount()
        XCTAssertTrue(store.items.isEmpty)

        store.activateAuthenticatedAccount(accountID)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.id, itemID)
        XCTAssertTrue(store.items.first?.completedDates.contains(todayKey) == true)
    }

    @MainActor
    func testMissedIrregularTaskStaysOpenAndResolvesAgainstOriginalDate() throws {
        let accountID = "carryover-store-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let yesterdayKey = DateKey.string(from: yesterday)
        let todayKey = DateKey.string(from: today)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let item = ChecklistItem(
            title: "Water plants",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: yesterday)],
            quantity: 2,
            createdAt: yesterday,
            startDate: yesterday,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: yesterdayKey
        )
        let store = ChecklistStore()
        store.save(item)

        let initial = try XCTUnwrap(store.carryoverEntries.first)
        XCTAssertEqual(initial.scheduledDateKeys, [yesterdayKey])
        let snapshot = store.widgetSnapshot(now: .now)
        XCTAssertEqual(snapshot.remainingCount, 1)
        XCTAssertEqual(snapshot.scheduledCount, 1)
        XCTAssertEqual(snapshot.carryoverCount, 1)
        store.advanceCarryover(initial)

        let partial = try XCTUnwrap(store.carryoverEntries.first)
        XCTAssertEqual(partial.latestCompletionCount, 1)
        XCTAssertFalse(store.items[0].isComplete(on: yesterday))
        XCTAssertEqual(store.items[0].occurrence(scheduledDate: yesterdayKey)?.outcome, .open)

        store.advanceCarryover(partial)

        XCTAssertTrue(store.carryoverEntries.isEmpty)
        XCTAssertTrue(store.items[0].isComplete(on: yesterday))
        XCTAssertFalse(store.items[0].isComplete(on: today))
        XCTAssertEqual(store.items[0].occurrence(scheduledDate: yesterdayKey)?.outcome, .done)
        XCTAssertEqual(store.items[0].occurrence(scheduledDate: yesterdayKey)?.resolvedDate, todayKey)
        XCTAssertEqual(store.items[0].carryoverResolvedThroughDate, yesterdayKey)
        let insights = store.routineInsights(asOf: today, calendar: calendar)
        XCTAssertEqual(insights.completedCheckIns, 1)
        XCTAssertEqual(insights.lateCompletedCheckIns, 1)
    }

    @MainActor
    func testTomorrowHidesOverlappingCarryoverFromTodayAndWidget() throws {
        let accountID = "carryover-tomorrow-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let yesterdayKey = DateKey.string(from: yesterday)
        let tomorrowKey = DateKey.string(from: tomorrow)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let item = ChecklistItem(
            title: "Weekly review",
            schedule: .custom,
            customWeekdays: [
                calendar.component(.weekday, from: yesterday),
                calendar.component(.weekday, from: today)
            ],
            createdAt: yesterday,
            startDate: yesterday,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: yesterdayKey
        )
        let store = ChecklistStore()
        store.save(item)
        let entry = try XCTUnwrap(store.carryoverEntries.first)
        XCTAssertEqual(entry.outstandingOccurrenceCount, 2)

        store.deferCarryoverUntilTomorrow(entry)

        XCTAssertTrue(store.carryoverEntries.isEmpty)
        XCTAssertFalse(store.todoItems.contains(where: { $0.id == item.id }))
        XCTAssertEqual(store.widgetSnapshot(now: .now).remainingCount, 0)
        XCTAssertEqual(store.widgetSnapshot(now: .now).scheduledCount, 0)
        let hidden = try XCTUnwrap(store.unresolvedCarryoverEntry(for: item.id))
        XCTAssertEqual(hidden.occurrences.last?.state?.hiddenUntil, tomorrowKey)
        let tomorrowEntries = CarryoverResolver.entries(items: store.items, groups: [], asOf: tomorrow)
        XCTAssertEqual(tomorrowEntries.first?.scheduledDateKeys, [yesterdayKey, DateKey.string(from: today)])
        XCTAssertTrue(store.items[0].skippedDates.isEmpty)
    }

    func testCarryoverDerivationCrossesDSTAndMonthEndWithoutMutation() throws {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let dstDue = try XCTUnwrap(eastern.date(from: DateComponents(
            timeZone: eastern.timeZone,
            year: 2026,
            month: 3,
            day: 8
        )))
        let afterDST = try XCTUnwrap(eastern.date(byAdding: .day, value: 1, to: dstDue))
        let monthEndDue = try XCTUnwrap(eastern.date(from: DateComponents(
            timeZone: eastern.timeZone,
            year: 2026,
            month: 5,
            day: 31
        )))
        let nextMonth = try XCTUnwrap(eastern.date(byAdding: .day, value: 1, to: monthEndDue))

        for (dueDate, asOfDate) in [(dstDue, afterDST), (monthEndDue, nextMonth)] {
            let dueKey = DateKey.string(from: dueDate)
            let item = ChecklistItem(
                title: "Calendar boundary",
                schedule: .custom,
                customWeekdays: [eastern.component(.weekday, from: dueDate)],
                createdAt: dueDate,
                startDate: dueDate,
                missedBehavior: .keepUntilDone,
                carryoverStartDate: dueKey
            )

            let entries = CarryoverResolver.entries(
                items: [item],
                groups: [],
                asOf: asOfDate,
                calendar: eastern
            )

            XCTAssertEqual(entries.first?.scheduledDateKeys, [dueKey])
            XCTAssertTrue(item.occurrences.isEmpty)
        }
    }

    @MainActor
    func testScheduleEditPreservesAnExistingOpenOccurrence() throws {
        let accountID = "carryover-schedule-edit-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let yesterdayKey = DateKey.string(from: yesterday)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let item = ChecklistItem(
            title: "Weekly reset",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: yesterday)],
            createdAt: yesterday,
            startDate: yesterday,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: yesterdayKey
        )
        let store = ChecklistStore()
        store.save(item)
        XCTAssertEqual(store.carryoverEntries.first?.latestScheduledDateKey, yesterdayKey)

        var edited = try XCTUnwrap(store.items.first)
        edited.customWeekdays = [calendar.component(.weekday, from: today)]
        store.save(edited)

        XCTAssertEqual(
            store.items.first?.occurrence(scheduledDate: yesterdayKey, scheduleRevision: 0)?.outcome,
            .open
        )
        XCTAssertEqual(store.items.first?.scheduleRevision, 1)
        XCTAssertEqual(store.carryoverEntries.first?.scheduledDateKeys, [yesterdayKey, DateKey.string(from: today)])
        XCTAssertTrue(store.todoItems.isEmpty)
    }

    @MainActor
    func testRecurrenceEditAdvancesRevisionAndPreservesOccurrenceIdentity() throws {
        let accountID = "recurrence-schedule-edit-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let todayKey = DateKey.string(from: today)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let store = ChecklistStore()
        store.save(ChecklistItem(
            title: "Replace filter",
            schedule: .custom,
            recurrence: RecurrenceRule(
                kind: .interval,
                interval: 2,
                anchorDate: todayKey,
                unit: .day
            ),
            createdAt: today,
            startDate: today,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: todayKey
        ))

        var edited = try XCTUnwrap(store.items.first)
        edited.recurrence = RecurrenceRule(
            kind: .interval,
            interval: 3,
            anchorDate: todayKey,
            unit: .day
        )
        store.save(edited)

        let saved = try XCTUnwrap(store.items.first)
        XCTAssertEqual(saved.scheduleRevision, 1)
        XCTAssertEqual(
            saved.occurrence(scheduledDate: todayKey, scheduleRevision: 0)?.outcome,
            .open
        )
        XCTAssertEqual(
            saved.occurrenceID(scheduledDate: todayKey, scheduleRevision: 0),
            ChecklistOccurrenceIdentifier.string(
                itemID: saved.id,
                scheduleRevision: 0,
                scheduledDateKey: todayKey
            )
        )
    }

    @MainActor
    func testBackdatedResolutionAndPauseControlCarryoverVisibility() throws {
        let accountID = "carryover-history-pause-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let key = DateKey.string(from: yesterday)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let item = ChecklistItem(
            title: "Backdated carryover",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: yesterday)],
            createdAt: yesterday,
            startDate: yesterday,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: key
        )
        let store = ChecklistStore()
        store.selectedDate = today
        store.save(item)
        XCTAssertNotNil(store.carryoverEntries.first)

        store.pause(item, days: 2)
        XCTAssertTrue(store.carryoverEntries.isEmpty)
        XCTAssertNotNil(store.unresolvedCarryoverEntry(for: item.id))

        store.resume(try XCTUnwrap(store.items.first))
        XCTAssertNotNil(store.carryoverEntries.first)

        store.setHistoryState(.done, for: item.id, on: yesterday)
        XCTAssertTrue(store.carryoverEntries.isEmpty)

        store.setHistoryState(.open, for: item.id, on: yesterday)
        XCTAssertNotNil(store.carryoverEntries.first)

        store.setHistoryState(.skipped, for: item.id, on: yesterday)
        XCTAssertTrue(store.carryoverEntries.isEmpty)
    }

    @MainActor
    func testEnablingCarryoverDoesNotResurrectHistoricalMisses() throws {
        let accountID = "carryover-enable-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let lastWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: today))
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let item = ChecklistItem(
            title: "Old weekly task",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: lastWeek)],
            createdAt: lastWeek,
            startDate: lastWeek
        )
        let store = ChecklistStore()
        store.save(item)
        var edited = try XCTUnwrap(store.items.first)
        edited.missedBehavior = .keepUntilDone
        edited.carryoverStartDate = nil
        store.save(edited)

        XCTAssertEqual(store.items.first?.carryoverStartDate, DateKey.string(from: today))
        XCTAssertTrue(store.carryoverEntries.isEmpty)
    }

    @MainActor
    func testOverlappingRecurrenceUsesOneCarryoverRowAndResolvesNewestOnly() throws {
        let accountID = "carryover-overlap-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let todayKey = DateKey.string(from: today)
        let yesterdayKey = DateKey.string(from: yesterday)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let item = ChecklistItem(
            title: "Two-day overlap",
            schedule: .custom,
            customWeekdays: [
                calendar.component(.weekday, from: yesterday),
                calendar.component(.weekday, from: today)
            ],
            createdAt: yesterday,
            startDate: yesterday,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: yesterdayKey
        )
        let store = ChecklistStore()
        store.selectedDate = today
        store.save(item)

        let grouped = try XCTUnwrap(store.carryoverEntries.first)
        XCTAssertEqual(grouped.scheduledDateKeys, [yesterdayKey, todayKey])
        XCTAssertEqual(grouped.outstandingOccurrenceCount, 2)
        XCTAssertTrue(store.todoItems.isEmpty)
        let snapshot = store.widgetSnapshot(now: .now)
        XCTAssertEqual(snapshot.remainingCount, 1)
        XCTAssertEqual(snapshot.scheduledCount, 1)
        XCTAssertEqual(snapshot.carryoverCount, 1)

        store.completeAllForSelectedDate()
        XCTAssertFalse(store.items[0].isComplete(on: today))

        store.completeCarryover(itemID: item.id, occurrenceDate: today)

        XCTAssertTrue(store.carryoverEntries.isEmpty)
        XCTAssertTrue(store.items[0].isComplete(on: today))
        XCTAssertEqual(store.historyState(for: store.items[0], on: yesterday), .missed)
        XCTAssertEqual(store.items[0].occurrence(scheduledDate: todayKey)?.outcome, .done)
        XCTAssertEqual(store.items[0].occurrence(scheduledDate: yesterdayKey)?.outcome, .missed)
    }

    @MainActor
    func testDistinctScheduleRevisionsOnSameDateDoNotOverwrite() throws {
        let accountID = "carryover-revisions-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let key = DateKey.string(from: yesterday)
        let itemID = UUID()
        let revisionZeroID = ChecklistOccurrenceIdentifier.string(
            itemID: itemID,
            scheduleRevision: 0,
            scheduledDateKey: key
        )
        let revisionOneID = ChecklistOccurrenceIdentifier.string(
            itemID: itemID,
            scheduleRevision: 1,
            scheduledDateKey: key
        )
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let item = ChecklistItem(
            id: itemID,
            title: "Revised schedule",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: yesterday)],
            createdAt: yesterday,
            startDate: yesterday,
            scheduleRevision: 2,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: key,
            occurrences: [
                revisionZeroID: ChecklistOccurrence(
                    scheduleRevision: 0,
                    scheduledDate: key
                ),
                revisionOneID: ChecklistOccurrence(
                    scheduleRevision: 1,
                    scheduledDate: key
                )
            ]
        )
        let store = ChecklistStore()
        store.save(item)

        let grouped = try XCTUnwrap(store.carryoverEntries.first)
        XCTAssertEqual(grouped.outstandingOccurrenceCount, 3)
        XCTAssertEqual(Set(grouped.scheduledDateKeys), Set([key]))
        XCTAssertEqual(Set(grouped.occurrences.map(\.id)).count, 3)

        store.completeCarryover(itemID: itemID, occurrenceDate: yesterday)

        XCTAssertTrue(store.carryoverEntries.isEmpty)
        XCTAssertEqual(store.items[0].occurrence(scheduledDate: key, scheduleRevision: 2)?.outcome, .done)
        XCTAssertEqual(store.items[0].occurrence(scheduledDate: key, scheduleRevision: 1)?.outcome, .missed)
        XCTAssertEqual(store.items[0].occurrence(scheduledDate: key, scheduleRevision: 0)?.outcome, .missed)
    }

    @MainActor
    func testQuantityReductionClosesPreviouslyPartialOccurrence() throws {
        let accountID = "carryover-quantity-edit-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let key = DateKey.string(from: yesterday)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let item = ChecklistItem(
            title: "Partial routine",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: yesterday)],
            quantity: 3,
            createdAt: yesterday,
            startDate: yesterday,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: key,
            occurrences: [
                key: ChecklistOccurrence(completionCount: 2, scheduledDate: key)
            ]
        )
        let store = ChecklistStore()
        store.save(item)
        XCTAssertNotNil(store.carryoverEntries.first)

        var edited = try XCTUnwrap(store.items.first)
        edited.quantity = 2
        store.save(edited)

        XCTAssertTrue(store.carryoverEntries.isEmpty)
    }

    @MainActor
    func testOccurrenceIDActionTargetsExactScheduleRevision() throws {
        let accountID = "carryover-action-id-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let key = DateKey.string(from: yesterday)
        let itemID = UUID()
        let olderID = ChecklistOccurrenceIdentifier.string(
            itemID: itemID,
            scheduleRevision: 0,
            scheduledDateKey: key
        )
        let newerID = ChecklistOccurrenceIdentifier.string(
            itemID: itemID,
            scheduleRevision: 1,
            scheduledDateKey: key
        )
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let item = ChecklistItem(
            id: itemID,
            title: "Revision-aware action",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: yesterday)],
            createdAt: yesterday,
            startDate: yesterday,
            scheduleRevision: 1,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: key,
            occurrences: [
                olderID: ChecklistOccurrence(scheduleRevision: 0, scheduledDate: key),
                newerID: ChecklistOccurrence(scheduleRevision: 1, scheduledDate: key)
            ]
        )
        let store = ChecklistStore()
        store.save(item)

        store.completeCarryover(
            itemID: itemID,
            occurrenceID: olderID,
            occurrenceDate: yesterday
        )

        XCTAssertEqual(store.items[0].occurrence(scheduledDate: key, scheduleRevision: 0)?.outcome, .done)
        XCTAssertEqual(store.items[0].occurrence(scheduledDate: key, scheduleRevision: 1)?.outcome, .open)
        XCTAssertEqual(store.carryoverEntries.first?.latestOccurrenceID, newerID)

        store.skipCarryover(
            itemID: itemID,
            occurrenceID: olderID,
            occurrenceDate: yesterday
        )
        XCTAssertEqual(store.items[0].occurrence(scheduledDate: key, scheduleRevision: 1)?.outcome, .open)
        XCTAssertFalse(store.items[0].skippedDates.contains(key))

        store.completeCarryover(
            itemID: itemID,
            occurrenceID: newerID,
            occurrenceDate: yesterday
        )
        XCTAssertTrue(store.carryoverEntries.isEmpty)
    }

    @MainActor
    func testCurrentOccurrenceNotificationIDWorksWithoutCarryover() throws {
        let accountID = "occurrence-action-current-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let key = DateKey.string(from: today)
        let itemID = UUID()
        let occurrenceID = ChecklistOccurrenceIdentifier.string(
            itemID: itemID,
            scheduleRevision: 4,
            scheduledDateKey: key
        )
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let store = ChecklistStore()
        store.save(ChecklistItem(
            id: itemID,
            title: "Today notification",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: today)],
            createdAt: today,
            startDate: today,
            scheduleRevision: 4,
            missedBehavior: .markMissed
        ))

        store.completeCarryover(
            itemID: itemID,
            occurrenceID: occurrenceID,
            occurrenceDate: today
        )

        XCTAssertTrue(store.items[0].isComplete(on: today))
        XCTAssertEqual(
            store.items[0].occurrence(scheduledDate: key, scheduleRevision: 4)?.outcome,
            .done
        )
    }

    @MainActor
    func testResolvingReopenedOlderDateNeverMovesBoundaryBackward() throws {
        let accountID = "carryover-boundary-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let weekAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: today))
        let oldKey = DateKey.string(from: weekAgo)
        let todayKey = DateKey.string(from: today)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let item = ChecklistItem(
            title: "Reopened history",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: weekAgo)],
            openDates: [oldKey],
            createdAt: weekAgo,
            startDate: weekAgo,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: todayKey,
            carryoverResolvedThroughDate: todayKey,
            occurrences: [oldKey: ChecklistOccurrence(scheduledDate: oldKey)]
        )
        let store = ChecklistStore()
        store.save(item)
        let entry = try XCTUnwrap(store.carryoverEntries.first)

        store.skipCarryover(entry)

        XCTAssertEqual(store.items[0].carryoverResolvedThroughDate, todayKey)
        XCTAssertTrue(store.carryoverEntries.isEmpty)
    }

    @MainActor
    func testDisablingCarryoverClosesOutstandingOccurrenceAsMissed() throws {
        let accountID = "carryover-disable-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let key = DateKey.string(from: yesterday)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let store = ChecklistStore()
        store.save(ChecklistItem(
            title: "Disable carryover",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: yesterday)],
            createdAt: yesterday,
            startDate: yesterday,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: key
        ))
        var edited = try XCTUnwrap(store.items.first)
        edited.missedBehavior = .markMissed
        store.save(edited)

        XCTAssertTrue(store.carryoverEntries.isEmpty)
        XCTAssertEqual(store.items[0].latestOccurrence(scheduledDate: key)?.outcome, .missed)
        XCTAssertEqual(store.historyState(for: store.items[0], on: yesterday), .missed)

        edited = store.items[0]
        edited.missedBehavior = .keepUntilDone
        edited.carryoverStartDate = nil
        store.save(edited)
        XCTAssertTrue(store.carryoverEntries.isEmpty)
    }

    @MainActor
    func testDisablingCarryoverTerminalizesPersistedPartialAndHiddenOccurrence() throws {
        let accountID = "carryover-disable-partial-\(UUID().uuidString)"
        let today = calendar.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let key = DateKey.string(from: yesterday)
        cleanCaches(for: [accountID])
        defer {
            cleanCaches(for: [accountID])
            UserDefaults.standard.removeObject(forKey: "activeAccountID")
        }
        UserDefaults.standard.set(accountID, forKey: "activeAccountID")

        let store = ChecklistStore()
        store.save(ChecklistItem(
            title: "Partial hidden carryover",
            schedule: .custom,
            customWeekdays: [calendar.component(.weekday, from: yesterday)],
            quantity: 3,
            createdAt: yesterday,
            startDate: yesterday,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: key
        ))
        let entry = try XCTUnwrap(store.carryoverEntries.first)
        store.advanceCarryover(entry)
        store.deferCarryoverUntilTomorrow(try XCTUnwrap(store.carryoverEntries.first))

        var edited = try XCTUnwrap(store.items.first)
        edited.missedBehavior = .markMissed
        store.save(edited)

        let occurrence = try XCTUnwrap(store.items[0].occurrence(scheduledDate: key))
        XCTAssertEqual(occurrence.outcome, .missed)
        XCTAssertEqual(occurrence.completionCount, 1)
        XCTAssertNil(occurrence.hiddenUntil)
        XCTAssertFalse(store.items[0].openDates.contains(key))
        XCTAssertEqual(store.historyState(for: store.items[0], on: yesterday), .missed)
        XCTAssertNil(store.unresolvedCarryoverEntry(for: store.items[0].id))
    }

    func testLegacyChecklistItemDefaultsToMissedWithoutCarryoverState() throws {
        let id = UUID()
        let data = try XCTUnwrap(
            """
            {"id":"\(id.uuidString)","title":"Legacy task"}
            """.data(using: .utf8)
        )

        let item = try JSONDecoder().decode(ChecklistItem.self, from: data)

        XCTAssertEqual(item.scheduleRevision, 0)
        XCTAssertEqual(item.missedBehavior, .markMissed)
        XCTAssertNil(item.recurrence)
        XCTAssertNil(item.carryoverStartDate)
        XCTAssertNil(item.carryoverResolvedThroughDate)
        XCTAssertTrue(item.occurrences.isEmpty)
    }

    func testOccurrencePayloadRoundTripsAtomicallyAndNormalizesCount() throws {
        let itemID = UUID()
        let dateKey = "2026-07-12"
        let occurrence = ChecklistOccurrence(
            outcome: .done,
            completionCount: 120,
            resolvedDate: "2026-07-13",
            hiddenUntil: "2026-07-14"
        )
        let mutation = SyncMutation.occurrence(
            itemID: itemID,
            occurrenceDate: dateKey,
            occurrence: occurrence
        )

        let decoded = try JSONDecoder().decode(
            SyncMutation.self,
            from: JSONEncoder().encode(mutation)
        )

        XCTAssertEqual(decoded.kind, .occurrence)
        XCTAssertEqual(decoded.itemID, itemID)
        XCTAssertEqual(decoded.occurrenceDate, dateKey)
        XCTAssertEqual(
            decoded.occurrenceID,
            ChecklistOccurrenceIdentifier.string(
                itemID: itemID,
                scheduleRevision: 0,
                scheduledDateKey: dateKey
            )
        )
        XCTAssertEqual(decoded.occurrence?.outcome, .done)
        XCTAssertEqual(decoded.occurrence?.completionCount, 99)
        XCTAssertEqual(decoded.occurrence?.resolvedDate, "2026-07-13")
        XCTAssertEqual(decoded.occurrence?.hiddenUntil, "2026-07-14")
        XCTAssertEqual(decoded.occurrence?.scheduleRevision, 0)
        XCTAssertEqual(decoded.occurrence?.scheduledDate, dateKey)

        let negativeCountData = try XCTUnwrap(
            #"{"outcome":"open","completionCount":-5}"#.data(using: .utf8)
        )
        let normalized = try JSONDecoder().decode(ChecklistOccurrence.self, from: negativeCountData)
        XCTAssertEqual(normalized.completionCount, 0)

        let transitionalData = try XCTUnwrap(
            #"{"outcome":"open","scheduleRevision":2,"originalScheduledDate":"2026-07-10"}"#
                .data(using: .utf8)
        )
        let transitional = try JSONDecoder().decode(ChecklistOccurrence.self, from: transitionalData)
        XCTAssertEqual(transitional.scheduledDate, "2026-07-10")
        let canonicalJSON = try XCTUnwrap(
            String(data: JSONEncoder().encode(transitional), encoding: .utf8)
        )
        XCTAssertTrue(canonicalJSON.contains("\"scheduledDate\":\"2026-07-10\""))
        XCTAssertFalse(canonicalJSON.contains("originalScheduledDate"))
    }

    func testUpsertPayloadIncludesRecurrenceCarryoverConfigurationAndOccurrences() {
        let occurrence = ChecklistOccurrence(
            outcome: .open,
            completionCount: 2,
            scheduledDate: "2026-07-08"
        )
        let item = ChecklistItem(
            title: "Weekly review",
            schedule: .custom,
            customWeekdays: [2],
            recurrence: RecurrenceRule(
                kind: .monthlyOrdinal,
                interval: 2,
                anchorDate: "2026-07-01",
                ordinal: -1,
                weekday: 6
            ),
            quantity: 3,
            missedBehavior: .keepUntilDone,
            carryoverStartDate: "2026-07-01",
            carryoverResolvedThroughDate: "2026-07-07",
            occurrences: ["2026-07-08": occurrence]
        )

        let mutation = SyncMutation.upsert(
            item: item,
            changedFields: ["missedBehavior"]
        )

        XCTAssertEqual(mutation.item?.missedBehavior, .keepUntilDone)
        XCTAssertEqual(mutation.item?.recurrence, item.recurrence)
        XCTAssertEqual(mutation.item?.carryoverStartDate, "2026-07-01")
        XCTAssertEqual(mutation.item?.carryoverResolvedThroughDate, "2026-07-07")
        XCTAssertEqual(
            mutation.item?.occurrences[item.occurrenceID(scheduledDate: "2026-07-08")],
            occurrence
        )

        let decoded = try? JSONDecoder().decode(
            SyncMutation.self,
            from: JSONEncoder().encode(mutation)
        )
        XCTAssertEqual(decoded?.item?.recurrence, item.recurrence)
    }

    func testOccurrenceIdentifierParsesRevisionedAndLegacyForms() throws {
        let itemID = UUID()
        let dateKey = "2026-07-12"
        let revisioned = ChecklistOccurrenceIdentifier.string(
            itemID: itemID,
            scheduleRevision: 4,
            scheduledDateKey: dateKey
        )
        let legacy = ChecklistOccurrenceIdentifier.string(
            itemID: itemID,
            scheduledDateKey: dateKey
        )

        let parsedRevisioned = try XCTUnwrap(ChecklistOccurrenceIdentifier.parse(revisioned))
        XCTAssertEqual(parsedRevisioned.itemID, itemID)
        XCTAssertEqual(parsedRevisioned.scheduleRevision, 4)
        XCTAssertEqual(parsedRevisioned.scheduledDateKey, dateKey)
        XCTAssertFalse(parsedRevisioned.isLegacy)

        let parsedLegacy = try XCTUnwrap(ChecklistOccurrenceIdentifier.parse(legacy))
        XCTAssertEqual(parsedLegacy.itemID, itemID)
        XCTAssertNil(parsedLegacy.scheduleRevision)
        XCTAssertEqual(parsedLegacy.scheduledDateKey, dateKey)
        XCTAssertTrue(parsedLegacy.isLegacy)
        XCTAssertEqual(
            ChecklistOccurrenceIdentifier.scheduledDateKey(from: legacy, itemID: itemID),
            dateKey
        )
    }

    func testLegacyDateKeyedOccurrencesMigrateToStableIdentifiersOnDecode() throws {
        let itemID = UUID()
        let dateKey = "2026-07-06"
        let data = try XCTUnwrap(
            """
            {
              "id":"\(itemID.uuidString)",
              "title":"Legacy weekly task",
              "occurrences":{
                "\(dateKey)":{"outcome":"missed","completionCount":0}
              }
            }
            """.data(using: .utf8)
        )

        let item = try JSONDecoder().decode(ChecklistItem.self, from: data)
        let identifier = item.occurrenceID(
            scheduledDate: dateKey,
            scheduleRevision: 0
        )

        XCTAssertNil(item.occurrences[dateKey])
        XCTAssertEqual(item.occurrences.count, 1)
        XCTAssertEqual(item.occurrences[identifier]?.outcome, .missed)
        XCTAssertEqual(item.occurrences[identifier]?.scheduleRevision, 0)
        XCTAssertEqual(item.occurrences[identifier]?.scheduledDate, dateKey)
        XCTAssertEqual(
            item.occurrence(scheduledDate: dateKey, scheduleRevision: 0)?.outcome,
            .missed
        )

        let roundTripped = try JSONDecoder().decode(
            ChecklistItem.self,
            from: JSONEncoder().encode(item)
        )
        XCTAssertEqual(roundTripped.occurrences, item.occurrences)
    }

    func testOccurrenceHelpersKeepScheduleRevisionsDistinct() {
        let dateKey = "2026-07-12"
        var item = ChecklistItem(title: "Weekly review", scheduleRevision: 2)

        let revisionOneID = item.setOccurrence(
            ChecklistOccurrence(outcome: .missed),
            scheduledDate: dateKey,
            scheduleRevision: 1
        )
        let revisionTwoID = item.setOccurrence(
            ChecklistOccurrence(outcome: .open, completionCount: 1),
            scheduledDate: dateKey
        )

        XCTAssertNotEqual(revisionOneID, revisionTwoID)
        XCTAssertEqual(item.occurrences[revisionOneID]?.scheduleRevision, 1)
        XCTAssertEqual(item.occurrences[revisionTwoID]?.scheduleRevision, 2)
        XCTAssertEqual(item.occurrences[revisionTwoID]?.scheduledDate, dateKey)
        XCTAssertEqual(
            item.occurrence(scheduledDate: dateKey, scheduleRevision: 1)?.outcome,
            .missed
        )
        XCTAssertEqual(item.occurrence(scheduledDate: dateKey)?.outcome, .open)

        XCTAssertEqual(
            item.removeOccurrence(scheduledDate: dateKey, scheduleRevision: 1)?.outcome,
            .missed
        )
        XCTAssertNil(item.occurrence(scheduledDate: dateKey, scheduleRevision: 1))
        XCTAssertEqual(item.occurrence(scheduledDate: dateKey)?.outcome, .open)
    }

    func testOccurrenceMutationAcceptsExplicitStableIdentifier() {
        let itemID = UUID()
        let dateKey = "2026-07-12"
        let occurrenceID = ChecklistOccurrenceIdentifier.string(
            itemID: itemID,
            scheduleRevision: 3,
            scheduledDateKey: dateKey
        )

        let mutation = SyncMutation.occurrence(
            itemID: itemID,
            occurrenceID: occurrenceID,
            occurrence: ChecklistOccurrence(outcome: .done, completionCount: 1)
        )

        XCTAssertEqual(mutation.occurrenceID, occurrenceID)
        XCTAssertEqual(mutation.occurrenceDate, dateKey)
        XCTAssertEqual(mutation.occurrence?.scheduleRevision, 3)
        XCTAssertEqual(mutation.occurrence?.scheduledDate, dateKey)
    }

    private func cleanCaches(for accountIDs: [String]) {
        for accountID in accountIDs {
            let url = URL.documentsDirectory.appending(path: "daily-checklist-\(accountID).json")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
