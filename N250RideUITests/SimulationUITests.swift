import XCTest

/// Runs in simulation mode: synthetic routes, no Apple or Google route requests.
final class SimulationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-simulationMode", "YES", "-disableLiveActivity", "YES"]
        app.launch()
    }

    /// SwiftUI lists drop rows that are off-screen, so scroll until the element exists.
    @discardableResult
    private func reveal(_ element: XCUIElement, up: Bool = true, attempts: Int = 5) -> Bool {
        for _ in 0..<attempts where !element.exists {
            up ? app.swipeUp() : app.swipeDown()
        }
        return element.waitForExistence(timeout: 3)
    }

    private func paste(_ text: String) {
        let field = app.textFields["pasteField"]
        if !field.waitForExistence(timeout: 3) {
            let disclosure = app.staticTexts["Coordinates or plus code"]
            XCTAssertTrue(reveal(disclosure))
            disclosure.tap()
        }
        XCTAssertTrue(reveal(field))
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        field.typeText(text)
        app.buttons["usePastedButton"].tap()
    }

    func testNoKeyLaunchShowsSimulationBadge() {
        XCTAssertTrue(app.staticTexts["simulationBadge"].waitForExistence(timeout: 5)
                      || app.descendants(matching: .any)["simulationBadge"].exists)
    }

    func testRejectsShortPlusCode() {
        paste("7JCJ+8J")
        XCTAssertTrue(app.staticTexts["pasteError"].waitForExistence(timeout: 2))
    }

    func testCancelReturnsToPicker() {
        paste("12.9716, 77.5946")
        XCTAssertTrue(app.buttons["cancelDestinationButton"].waitForExistence(timeout: 3))
        app.buttons["cancelDestinationButton"].tap()
        XCTAssertTrue(reveal(app.textFields["searchField"], up: false))
    }

    func testConfirmStartAndStopSimulatedRide() {
        paste("12.9716, 77.5946")
        XCTAssertTrue(app.buttons["confirmDestinationButton"].waitForExistence(timeout: 3))
        app.buttons["confirmDestinationButton"].tap()
        let start = app.buttons["startNavigationButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        start.tap()
        XCTAssertTrue(app.buttons["stopButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(start.exists, "start is single-shot; repeated taps cannot restart the route")
        XCTAssertTrue(app.descendants(matching: .any)["currentTurn"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "navigating"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["stopButton"].tap()
        XCTAssertTrue(reveal(app.textFields["searchField"], up: false))
    }

    func testSaveUseAndDeleteFavourite() {
        paste("12.9716, 77.5946")
        let toggle = app.switches["saveFavouriteToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(NSPredicate(format: "value == '1'").evaluate(with: toggle)
                      || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"),
                                                                       object: toggle)], timeout: 5) == .completed)
        let label = app.textFields["labelField"]
        label.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { label.tap() }
        let name = "Office\(Int.random(in: 1000...9999))"
        label.typeText(name)
        XCTAssertEqual(label.value as? String, name)
        app.buttons["confirmDestinationButton"].tap()
        let cancelPreview = app.buttons["cancelPreviewButton"]
        XCTAssertTrue(cancelPreview.waitForExistence(timeout: 5))
        cancelPreview.tap()

        let favourite = app.buttons["favourite-\(name)"]
        XCTAssertTrue(reveal(favourite))
        favourite.tap()
        XCTAssertTrue(app.buttons["cancelDestinationButton"].waitForExistence(timeout: 3))
        app.buttons["cancelDestinationButton"].tap()

        favourite.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(favourite.waitForExistence(timeout: 2))
    }

    /// Regression: one test frame used to start a hidden session that locked the panel.
    func testDiagnosticTestFramesDoNotLockThePanel() {
        app.buttons["Diagnostics"].tap()
        let left = app.buttons["test-Left 250 m"]
        let right = app.buttons["test-Right 250 m"]
        XCTAssertTrue(reveal(left))
        left.tap()
        XCTAssertTrue(right.isEnabled)
        right.tap()
        let clear = app.buttons["clearDashboardButton"]
        XCTAssertTrue(reveal(clear))
        XCTAssertTrue(clear.isEnabled)
        clear.tap()
        sleep(6)
        for _ in 0..<3 where !left.exists { app.swipeDown() }
        XCTAssertTrue(left.isEnabled, "panel stays usable after the frame expires")
        left.tap()
        let rows = app.descendants(matching: .any).matching(identifier: "recentFrame")
        for _ in 0..<4 where rows.count < 3 { app.swipeUp() }
        XCTAssertEqual(rows.count, 3)
    }

    func testMapTabOffersLongPressAndRecentre() {
        app.buttons["Map"].tap()
        XCTAssertTrue(app.staticTexts["Long-press to set a destination"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Re-centre map"].exists)
    }

    func testCustomStatusControlsEnableWithToggle() {
        app.buttons["Diagnostics"].tap()
        let toggle = app.switches["customStatusToggle"]
        for _ in 0..<4 where !toggle.exists { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let raw = app.textFields["customRawBytes"]
        for _ in 0..<3 where !raw.exists { app.swipeUp() }
        XCTAssertTrue(raw.waitForExistence(timeout: 5))
        XCTAssertFalse(raw.isEnabled)
        toggle.switches.firstMatch.tap()
        for _ in 0..<3 where !raw.exists { app.swipeUp() }
        XCTAssertTrue(raw.waitForExistence(timeout: 5))
        XCTAssertTrue(raw.isEnabled)
    }

    func testRideSettingsAndShortcutsAreReachable() {
        XCTAssertTrue(app.buttons["shortcut-Home"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["shortcut-Home"].isEnabled, "Home is not set on a fresh install")
        app.buttons["rideSettingsButton"].tap()
        let voice = app.switches["voiceToggle"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["avoidTollsToggle"].exists)
        app.buttons["Done"].tap()
    }

    func testConsoleFillsPresetWithoutSending() {
        app.buttons["Diagnostics"].tap()
        let link = app.buttons["bluetoothConsoleLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let preset = app.buttons["Missed call from TEST"]
        for _ in 0..<4 where !preset.exists { app.swipeUp() }
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        preset.tap()
        for _ in 0..<4 where !app.textViews["consoleHex"].exists && !app.textFields["consoleHex"].exists { app.swipeDown() }
        let hex = app.textViews["consoleHex"].exists ? app.textViews["consoleHex"] : app.textFields["consoleHex"]
        XCTAssertTrue((hex.value as? String ?? "").hasPrefix("01 04 54 45 53 54"))
        XCTAssertFalse(app.buttons["consoleSend"].isEnabled, "no bike in the simulator, so sending is disabled")
    }

    /// The test runner is a separate process from the same developer team, like the
    /// Share extension, so this exercises the real cross-app hand-off.
    func testSharedLinkFromAnotherProcessOpensConfirmation() {
        app.terminate()
        UIPasteboard(name: UIPasteboard.Name("com.n250ride.share-inbox"), create: true)?
            .setValue("Lalbagh https://maps.apple.com/?ll=12.9498,77.5866&q=Lalbagh", forPasteboardType: "public.utf8-plain-text")
        app.launch()
        XCTAssertTrue(app.buttons["cancelDestinationButton"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["labelField"].value as? String, "Lalbagh")
        app.buttons["cancelDestinationButton"].tap()
    }
}
