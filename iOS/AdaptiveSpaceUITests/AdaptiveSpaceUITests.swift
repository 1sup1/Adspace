import XCTest

@MainActor
final class AdaptiveSpaceUITests: XCTestCase {
    func testCompleteDemoFlow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-recoveryBrightnessDelta", "0"]
        app.launch()
        capture("01-wearable-consent")

        tap("connectWearable", in: app)
        waitUntilEnabled("requestRecommendation", in: app, timeout: 8)
        XCTAssertTrue(app.staticTexts["LIVE · 4"].exists)
        capture("02-wearable-synced")
        tap("requestRecommendation", in: app)
        waitUntilEnabled("approveProfile", in: app, timeout: 15)
        XCTAssertTrue(app.staticTexts["AGENT"].exists)
        XCTAssertTrue(app.staticTexts["4 SIGNALS"].exists)
        capture("03-agent-briefing")
        tap("approveProfile", in: app)
        tap("applyHome", in: app)
        capture("04-home-applied")

        for _ in 0..<7 {
            tap("brightnessIncrease", in: app)
        }
        XCTAssertTrue(app.staticTexts["42%"].waitForExistence(timeout: 5))
        tap("saveAdjustment", in: app)
        waitUntilEnabled("checkInHotel", in: app, timeout: 15)
        capture("05-home-adjusted")

        tap("checkInHotel", in: app)
        waitUntilEnabled("applyHotel", in: app, timeout: 15)
        capture("06-hotel-compatibility")
        tap("applyHotel", in: app)
        waitUntilEnabled("checkout", in: app, timeout: 10)
        capture("07-hotel-applied")
        tap("checkout", in: app)

        XCTAssertTrue(app.buttons["resetDemo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["일회성 권한 만료"].exists)
        capture("08-checkout-complete")
    }

    private func tap(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 5) {
        let element = app.buttons[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(identifier)")
        reveal(element, in: app)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, "Element is not hittable")
    }

    private func waitUntilEnabled(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval) {
        let element = app.buttons[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(identifier)")
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
