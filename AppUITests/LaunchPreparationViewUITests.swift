import XCTest

/// Drives the real `LaunchPreparationView` and the real
/// `LaunchPreparationModel` against `App/UITestScenario.swift`'s synthetic
/// seams. No server, no configuration, no real title, no real bytes: the app is
/// launched with `-ui-test-scenario <name>` and that route exists only in a
/// debug build.
///
/// tvOS has no touch: focus is moved with `XCUIRemote` and confirmed with
/// `.select`, which is why every control this file presses has an explicit
/// initial focus in the view under test.
final class LaunchPreparationViewUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-scenario", scenario]
        app.launch()
        return app
    }

    private func waitFor(_ element: XCUIElement, _ message: String,
                         timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message,
                      file: file, line: line)
    }

    // MARK: The chooser

    func testConflictShowsBothDatesBothChoicesAndTheArchivalExplanation() {
        let app = launch("conflict")

        waitFor(app.staticTexts["conflict.localDate"], "the local card's date is missing")
        waitFor(app.staticTexts["conflict.remoteDate"], "the server card's date is missing")
        waitFor(app.staticTexts["conflict.explanation"],
                "the chooser does not say the other card is kept")

        // Both dates are real dates, not the unknown placeholder: the fixture
        // supplies both, so a screen showing "Date unknown" would mean the value
        // never reached it.
        XCTAssertNotEqual(app.staticTexts["conflict.localDate"].label, "Date unknown")
        XCTAssertNotEqual(app.staticTexts["conflict.remoteDate"].label, "Date unknown")
        XCTAssertNotEqual(app.staticTexts["conflict.localDate"].label,
                          app.staticTexts["conflict.remoteDate"].label)

        XCTAssertTrue(app.buttons["conflict.local"].exists)
        XCTAssertTrue(app.buttons["conflict.remote"].exists)
        XCTAssertEqual(app.buttons["conflict.local"].label, "Use This Apple TV")
        XCTAssertEqual(app.buttons["conflict.remote"].label, "Use RomM")

        // The explanation has to state that the unselected card is archived
        // before anything is replaced — that is the promise the choice rests on.
        let explanation = app.staticTexts["conflict.explanation"].label
        XCTAssertTrue(explanation.contains("copied to your RomM server first"), explanation)
        XCTAssertTrue(explanation.contains("nothing"), explanation)
    }

    /// Each choice in its own process, so neither can be reached by way of the
    /// other. The fixture's prepared marker names the choice it was resolved
    /// with, which is what proves the button called `resolve(choice:)` rather
    /// than merely dismissing the chooser.
    func testChoosingThisAppleTVResolvesWithTheLocalCard() {
        let app = launch("conflict")
        waitFor(app.buttons["conflict.local"], "the chooser did not appear")
        XCTAssertTrue(app.buttons["conflict.local"].hasFocus,
                      "the chooser did not open on a choice")
        XCUIRemote.shared.press(.select)

        waitFor(app.staticTexts["fixture.ready"], "choosing the local card did not prepare")
        XCTAssertEqual(app.staticTexts["fixture.entry"].label, "fixture-local.m3u")
    }

    func testChoosingRomMResolvesWithTheServerCard() {
        let app = launch("conflict")
        waitFor(app.buttons["conflict.remote"], "the chooser did not appear")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.buttons["conflict.remote"].waitForFocus(timeout: 5),
                      "focus never reached the RomM choice")
        XCUIRemote.shared.press(.select)

        waitFor(app.staticTexts["fixture.ready"], "choosing the server card did not prepare")
        XCTAssertEqual(app.staticTexts["fixture.entry"].label, "fixture-remote.m3u")
    }

    // MARK: Cancel

    func testCancelReturnsToTheLibraryWithoutPreparingAnything() {
        let app = launch("cancel")
        waitFor(app.staticTexts["prep.stage"], "preparation never started")
        waitFor(app.buttons["prep.cancel"], "there is no way to back out")
        XCTAssertTrue(app.buttons["prep.cancel"].waitForFocus(timeout: 5),
                      "Cancel never took focus")
        XCUIRemote.shared.press(.select)

        waitFor(app.staticTexts["fixture.library"], "Cancel did not return to the library")
        XCTAssertFalse(app.staticTexts["fixture.ready"].exists,
                       "a cancelled preparation still launched")
    }

    // MARK: Retry

    func testRetryAfterARecoverableFailureReachesReady() {
        let app = launch("retry")
        waitFor(app.staticTexts["prep.failure"], "the failure was never shown")

        // The message names the exact file, which is the whole point of the
        // typed firmware errors.
        XCTAssertTrue(app.staticTexts["prep.failure"].label.contains("scph5501.bin"),
                      app.staticTexts["prep.failure"].label)

        waitFor(app.buttons["prep.retry"], "a recoverable failure offered no Retry")
        XCTAssertTrue(app.buttons["prep.retry"].waitForFocus(timeout: 5),
                      "Retry never took focus")
        XCUIRemote.shared.press(.select)

        waitFor(app.staticTexts["fixture.ready"], "Retry did not reach a prepared launch")
    }

    // MARK: The disc set

    /// A metadata group the classifier merged is shown before it is played, and
    /// the player can refuse the merge. There is no filename rule that separates
    /// a genuine two-disc game from two separately numbered products, so this
    /// screen is the only defence there is.
    func testAMergedDiscSetIsVisibleAndOverridable() {
        let app = launch("discs")
        waitFor(app.staticTexts["prep.discSummary"], "the resolved disc set is not shown")
        XCTAssertEqual(app.staticTexts["prep.discSummary"].label,
                       "This game was read as 2 discs:")
        XCTAssertTrue(app.staticTexts["Disc 1 — Fixture Game (USA) (Disc 1)"].exists,
                      "the first disc's file is not named")
        XCTAssertTrue(app.staticTexts["Disc 2 — Fixture Game (USA) (Disc 2)"].exists,
                      "the second disc's file is not named")

        waitFor(app.buttons["prep.singleDisc"], "a merged disc set cannot be overridden")
        XCTAssertTrue(app.buttons["prep.singleDisc"].waitForFocus(timeout: 5),
                      "the override never took focus")
        XCUIRemote.shared.press(.select)

        // Refusing the merge changes what is launched, so it has to change what
        // is listed too: one disc means no disc list and a launch that completes.
        waitFor(app.staticTexts["fixture.ready"], "the override did not prepare a launch")
        XCTAssertFalse(app.staticTexts["prep.discSummary"].exists,
                       "the disc list still describes the set the player refused")
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
