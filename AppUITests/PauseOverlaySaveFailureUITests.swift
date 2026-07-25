import XCTest

/// The save-failure path on the pause overlay, driven through the real
/// `PauseOverlayView` and the real `EmulatorSaveFlow`.
///
/// The fixture's card refuses its first two writes and accepts everything after,
/// so one process covers the whole sequence: the failure a player sees, the Quit
/// it refuses, the Retry Save that lands, and the Quit that then leaves. No
/// server, no configuration, no core: the app is launched with
/// `-ui-test-scenario saveFailure` and that route exists only in a debug build.
///
/// tvOS has no touch: focus is moved with `XCUIRemote` and confirmed with
/// `.select`, which is why the overlay under test opens on an explicit control.
final class PauseOverlaySaveFailureUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-scenario", "saveFailure"]
        app.launch()
        return app
    }

    private func waitFor(_ element: XCUIElement, _ message: String,
                         timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message,
                      file: file, line: line)
    }

    /// Walks focus onto `element`, at most `presses` steps. Which control the
    /// focus engine picked when another one disappeared is not this test's
    /// business to predict.
    private func focus(_ element: XCUIElement, by direction: XCUIRemote.Button,
                       in presses: Int) -> Bool {
        for _ in 0...presses {
            if element.waitForFocus(timeout: 2) { return true }
            XCUIRemote.shared.press(direction)
        }
        return element.waitForFocus(timeout: 2)
    }

    /// The whole rule in one run: a failed save is visible, it does not throw the
    /// game away, it refuses to let Quit leave, and the retry that lands is what
    /// clears it.
    func testAFailedSaveIsVisibleBlocksQuitAndClearsOnlyWhenARetryLands() {
        let app = launch()

        // 1. The failure is on screen, and it is on the *overlay* — the game view
        //    was not replaced by an error screen.
        waitFor(app.staticTexts["pause.saveFailure"], "a failed save said nothing")
        XCTAssertTrue(app.staticTexts["pause.saveRecovery"].exists,
                      "the failure does not say what to do about it")
        XCTAssertTrue(app.staticTexts["Paused"].exists,
                      "the pause overlay was replaced instead of added to")
        XCTAssertFalse(app.staticTexts["emulator.startFailure"].exists,
                       "a save failure was reported as a failure to start")

        // The message names no path, no file and no server.
        let message = app.staticTexts["pause.saveFailure"].label
        XCTAssertFalse(message.contains("/"), message)

        // 2. Quit is refused while the card cannot be written.
        waitFor(app.buttons["pause.quit"], "there is no way to quit")
        XCTAssertTrue(app.buttons["pause.retrySave"].waitForFocus(timeout: 5),
                      "a save failure did not open on its remedy")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.buttons["pause.quit"].waitForFocus(timeout: 5),
                      "focus never reached Quit")
        XCUIRemote.shared.press(.select)

        XCTAssertFalse(app.staticTexts["fixture.library"].waitForExistence(timeout: 3),
                       "Quit left the game with the save still unwritten")
        XCTAssertTrue(app.staticTexts["pause.saveFailure"].exists,
                      "the blocked Quit stopped saying why")

        // 3. Retry Save lands this time, and only that clears the message.
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(app.buttons["pause.retrySave"].waitForFocus(timeout: 5),
                      "focus never returned to Retry Save")
        XCUIRemote.shared.press(.select)

        let cleared = NSPredicate(format: "exists == false")
        expectation(for: cleared, evaluatedWith: app.staticTexts["pause.saveFailure"])
        waitForExpectations(timeout: 10) { error in
            XCTAssertNil(error, "Retry Save worked and the message stayed up")
        }
        XCTAssertFalse(app.buttons["pause.retrySave"].exists,
                       "the remedy is still offered for a failure that is over")

        // 4. And now Quit leaves. Where focus landed when Retry Save was removed
        //    is the focus engine's business, so walk down to Quit rather than
        //    assuming.
        waitFor(app.buttons["pause.quit"], "Quit disappeared")
        XCTAssertTrue(focus(app.buttons["pause.quit"], by: .down, in: 4),
                      "focus never reached Quit")
        XCUIRemote.shared.press(.select)

        waitFor(app.staticTexts["fixture.library"],
                "Quit did not leave once the card had been written")
    }
}

private extension XCUIElement {
    /// tvOS moves focus asynchronously; a press issued before it lands goes to
    /// the wrong control.
    func waitForFocus(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasFocus { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "focus")], timeout: 0.1)
        }
        return hasFocus
    }
}
