import XCTest

/// Real Apple Maps search and routing; network required. Runs only with
/// TEST_RUNNER_N250_LIVE=1 and the simulator location set (see docs/setup.md).
@MainActor
final class LiveAppleRouteUITests: XCTestCase {
    func testSearchRouteChoiceAndStart() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["N250_LIVE"] == "1", "live Apple test not requested")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-simulationMode", "NO", "-appleRouteGuidanceNoticeAccepted", "YES"]
        app.launch()

        let search = app.textFields["searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Orion Mall")
        let first = app.buttons["suggestion-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        snapshot("1-search", app)
        first.tap()

        let confirm = app.buttons["confirmDestinationButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        snapshot("2-confirm", app)
        confirm.tap()

        XCTAssertTrue(app.buttons["routeOption-0"].waitForExistence(timeout: 60))
        snapshot("3-routes", app)
        let alternatives = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'routeOption-'")).count
        print("route options:", alternatives)
        if alternatives > 1 {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'routeOption-'")).element(boundBy: 1).tap()
            snapshot("4-alternative-selected", app)
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'routeOption-'")).element(boundBy: 0).tap()
        }

        app.buttons["Map"].tap()
        sleep(3)
        snapshot("5-map-routes", app)
        app.buttons["Ride"].tap()

        app.buttons["startNavigationButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["currentTurn"].waitForExistence(timeout: 20))
        sleep(4)
        snapshot("6-navigating", app)
        sleep(20)
        snapshot("6b-navigating-later", app)
        XCUIDevice.shared.press(.home)
        sleep(4)
        let island = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        island.name = "8-dynamic-island"
        island.lifetime = .keepAlways
        add(island)
        app.activate()
        app.buttons["Map"].tap()
        sleep(3)
        snapshot("7-map-navigating", app)
        app.buttons["Ride"].tap()
        app.buttons["stopButton"].tap()
    }

    private func snapshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
