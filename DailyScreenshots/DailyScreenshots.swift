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
        snapshot("01-Today")

        let allFilter = app.buttons["All"].firstMatch
        XCTAssertTrue(allFilter.waitForExistence(timeout: 5))
        allFilter.tap()
        XCTAssertTrue(app.staticTexts["Plan weekly reset"].waitForExistence(timeout: 5))
        snapshot("02-Groups")

        app.buttons["Add item"].tap()
        XCTAssertTrue(app.navigationBars["New item"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Remind me"].waitForExistence(timeout: 5))
        snapshot("03-Reminders")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Ritual Cue"].waitForExistence(timeout: 5))
        app.buttons["Account and notification settings"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Keep routines backed up"].waitForExistence(timeout: 5))
        snapshot("04-Sync")
    }
}
