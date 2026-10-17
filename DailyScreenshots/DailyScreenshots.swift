import XCTest

@MainActor
final class RitualCueScreenshots: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += [
            "--app-store-screenshots",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launchEnvironment["APP_STORE_SCREENSHOTS"] = "1"
        app.launch()

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["Ritual Cue"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Review calendar"].waitForExistence(timeout: 15))
    }

    func testAppStoreScreenshots() throws {
        let editChecklistButton = app.buttons["Edit checklist"].firstMatch
        XCTAssertTrue(editChecklistButton.waitForExistence(timeout: 5))
        editChecklistButton.tap()
        XCTAssertTrue(app.buttons["Edit Review calendar"].waitForExistence(timeout: 5))
        app.buttons["Done editing checklist"].tap()

        snapshot("01-Today")

        let allFilter = app.buttons["All"].firstMatch
        XCTAssertTrue(allFilter.waitForExistence(timeout: 5))
        allFilter.tap()
        let planningItem = app.staticTexts["Plan weekly reset"]
        XCTAssertTrue(scrollToExistence(planningItem))
        snapshot("02-Groups")

        app.buttons["Add item"].tap()
        XCTAssertTrue(app.navigationBars["New item"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToExistence(app.switches["Remind me"]))
        snapshot("03-Reminders")

        app.buttons["Cancel"].tap()
        for _ in 0..<4 {
            app.swipeDown()
        }
        XCTAssertTrue(app.staticTexts["Ritual Cue"].waitForExistence(timeout: 5))
        app.buttons["Account and notification settings"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToExistence(app.staticTexts["Keep routines backed up"]))
        snapshot("04-Sync")
    }

    func testCompletedSectionCanCollapseWithoutHidingSearchMatches() throws {
        // The seeded Morning group stays together until both tasks are done.
        app.buttons["Check off"].firstMatch.tap()
        let toggle = app.buttons["toggle-completed"]
        XCTAssertTrue(scrollToExistence(toggle))
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(scrollToExistence(app.staticTexts["Take vitamins"]))
        toggle.tap()
        XCTAssertFalse(app.staticTexts["Take vitamins"].exists)
        XCTAssertEqual(toggle.label, "Show completed tasks")
        snapshot("07-Completed-Collapsed")
        toggle.tap()
        XCTAssertTrue(scrollToExistence(app.staticTexts["Take vitamins"]))
        toggle.tap()
        for _ in 0..<5 where !app.buttons["Search checklist"].isHittable { app.swipeDown() }
        app.buttons["Search checklist"].tap()
        app.textFields["Search tasks"].typeText("vitamins")
        XCTAssertTrue(app.staticTexts["Take vitamins"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 matching task"].exists)
        XCTAssertFalse(toggle.exists)
        app.keyboards.buttons["Search"].tap()
        let match = app.staticTexts["Take vitamins"]
        for _ in 0..<5 where !match.isHittable { app.swipeUp() }
        XCTAssertTrue(match.isHittable)
        snapshot("08-Completed-Search")
        app.buttons["clear-search-query"].tap()
        XCTAssertFalse(app.staticTexts["Take vitamins"].exists)
    }

    func testSearchCountsClearAndNoMatchFeedback() throws {
        app.buttons["Search checklist"].tap()
        let search = app.textFields["Search tasks"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("calendar")
        XCTAssertTrue(app.staticTexts["1 matching task"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Review calendar"].exists)
        snapshot("05-Search-Count")
        app.buttons["clear-search-query"].tap()
        XCTAssertFalse(app.staticTexts["search-result-count"].exists)
        XCTAssertTrue(search.exists)
        search.typeText("no-such-ritual")
        XCTAssertTrue(app.staticTexts["0 matching tasks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No matching rituals"].exists)
        snapshot("06-Search-Empty")
        app.buttons["clear-search-query"].tap()
        XCTAssertTrue(app.staticTexts["Review calendar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No matching rituals"].exists)
    }

    func testDateChooserPreservesBrowsingUntilConfirmedAndReturnsToday() throws {
        app.buttons["Next day"].tap()
        XCTAssertTrue(app.buttons["Back to today"].waitForExistence(timeout: 5))
        let chooser = app.buttons["choose-checklist-date"]
        let selectedDay = chooser.value as? String
        XCTAssertNotNil(selectedDay)
        chooser.tap()
        XCTAssertTrue(app.navigationBars["Choose date"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.datePickers.firstMatch.exists)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let excludedDays: Set<Int> = [
            calendar.component(.day, from: today),
            calendar.component(.day, from: tomorrow)
        ]
        // Every displayed month has days 1–28, including when tomorrow starts a new month.
        let chosenDay = try XCTUnwrap((1...28).first { !excludedDays.contains($0) })
        let dayButton = app.datePickers.buttons.matching(NSPredicate(
            format: "label MATCHES %@", "(^|.*[^0-9])\(chosenDay)([^0-9].*|$)"
        )).firstMatch
        XCTAssertTrue(dayButton.exists)
        dayButton.tap()
        snapshot("09-Date-Chooser")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Ritual date chooser"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(chooser.value as? String, selectedDay)

        chooser.tap()
        dayButton.tap()
        app.buttons["View day"].tap()
        XCTAssertNotEqual(chooser.value as? String, selectedDay)
        app.buttons["Back to today"].tap()
        XCTAssertFalse(app.buttons["Back to today"].exists)
        XCTAssertNotEqual(chooser.value as? String, selectedDay)
        app.buttons["Archive"].tap()
        XCTAssertFalse(chooser.exists)
    }

    private func scrollToExistence(_ element: XCUIElement, maxSwipes: Int = 5) -> Bool {
        if element.waitForExistence(timeout: 1) { return true }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) { return true }
        }
        return element.exists
    }
}
