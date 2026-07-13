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

    private func cleanCaches(for accountIDs: [String]) {
        for accountID in accountIDs {
            let url = URL.documentsDirectory.appending(path: "daily-checklist-\(accountID).json")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
