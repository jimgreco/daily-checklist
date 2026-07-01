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

        app.buttons["All items"].tap()
        XCTAssertTrue(app.staticTexts["Plan weekly reset"].waitForExistence(timeout: 5))
        snapshot("02-All-Items")

        app.buttons["Edit checklist"].tap()
        XCTAssertTrue(app.buttons["Edit Review calendar"].waitForExistence(timeout: 5))
        snapshot("03-Edit-Mode")

        app.buttons["Add item"].tap()
        XCTAssertTrue(app.navigationBars["New item"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
        snapshot("04-New-Item")
    }
}
