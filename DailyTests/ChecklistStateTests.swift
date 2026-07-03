import XCTest
@testable import Daily

final class ChecklistStateTests: XCTestCase {
    private var calendar: Calendar {
        Calendar.current
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
        XCTAssertEqual(change.nextKey, nextKey)
        XCTAssertTrue(item.skippedDates.contains(sourceKey))
        XCTAssertFalse(item.completedDates.contains(sourceKey))
        XCTAssertTrue(item.openDates.contains(nextKey))
        XCTAssertFalse(item.completedDates.contains(nextKey))
        XCTAssertFalse(item.skippedDates.contains(nextKey))
        XCTAssertEqual(item.historyState(on: sourceDate, calendar: calendar), .skipped)
        XCTAssertEqual(item.historyState(on: nextDate, calendar: calendar), .open)
    }

    func testDailyItemsCannotBeDelayed() {
        var item = ChecklistItem(title: "Take vitamins", schedule: .everyDay)

        XCTAssertThrowsError(try item.delay(from: Date(), calendar: calendar)) { error in
            XCTAssertEqual(error as? ChecklistDelayError, .dailyItem)
        }
    }
}
