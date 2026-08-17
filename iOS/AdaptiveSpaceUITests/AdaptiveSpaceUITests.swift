import XCTest

@MainActor
final class AdaptiveSpaceUITests: XCTestCase {
    func testDemoStreamKeepsUpdating() throws {
        let app = XCUIApplication()
        app.launch()

        tap("connectWearable", in: app)
        waitUntilEnabled("requestRecommendation", in: app, timeout: 8)

        let live = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "LIVE ·")
        ).firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        let firstLabel = live.label
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", firstLabel),
            object: live
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
    }

    func testVoiceMode() throws {
        let app = XCUIApplication()
        app.launch()

        tap("openAgentChat", in: app)
        tap("openVoiceMode", in: app)

        XCTAssertTrue(app.staticTexts["VOICE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["localVoiceMode"].exists)
        XCTAssertTrue(app.buttons["voiceMic"].exists)
        capture("agent-voice-mode")
    }

    func testAgentChat() throws {
        let app = XCUIApplication()
        app.launch()

        tap("connectWearable", in: app)
        waitUntilEnabled("requestRecommendation", in: app, timeout: 8)
        tap("requestRecommendation", in: app)
        waitUntilEnabled("approveProfile", in: app, timeout: 15)
        tap("openAgentChat", in: app)

        let input = app.textFields["agentChatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(input.isHittable)
        input.tap()
        // The vertical SwiftUI TextField may be re-instantiated when it gains focus.
        // Send text to the focused application element instead of retaining a stale snapshot.
        app.typeText("현재 추천을 설명해줘")
        tap("sendAgentChat", in: app)

        XCTAssertTrue(app.staticTexts["chatAgentReply"].waitForExistence(timeout: 30))
        capture("agent-chat")
    }

    func testConflictComparisonScreen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-demoScenario", "calm"]
        app.launch()

        tap("connectWearable", in: app)
        waitUntilEnabled("requestRecommendation", in: app, timeout: 8)
        tap("requestRecommendation", in: app)
        waitUntilEnabled("approveProfile", in: app, timeout: 15)

        XCTAssertTrue(app.staticTexts["상충 신호"].exists)
        XCTAssertTrue(app.staticTexts["RULES"].exists)
        XCTAssertTrue(app.staticTexts["AGENT"].exists)
        XCTAssertTrue(app.staticTexts["POLICY OUTPUT"].exists)
        capture("conflict-rules-vs-agent")
    }

    func testCompleteDemoFlow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-recoveryBrightnessDelta", "0"]
        app.launch()
        capture("01-wearable-consent")

        tap("connectWearable", in: app)
        waitUntilEnabled("requestRecommendation", in: app, timeout: 8)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "LIVE ·")
        ).firstMatch.exists)
        capture("02-wearable-synced")
        tap("requestRecommendation", in: app)
        waitUntilEnabled("approveProfile", in: app, timeout: 15)
        XCTAssertTrue(app.staticTexts["RULES"].exists)
        XCTAssertTrue(app.staticTexts["AGENT"].exists)
        XCTAssertTrue(app.staticTexts["POLICY OUTPUT"].exists)
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
        waitUntilEnabled("approveConsensus", in: app, timeout: 10)
        XCTAssertTrue(app.staticTexts["공통 범위"].exists)
        XCTAssertTrue(app.staticTexts["2 JOINED"].exists)
        capture("06-companion-consensus")
        tap("approveConsensus", in: app)
        waitUntilEnabled("applyHotel", in: app, timeout: 15)
        capture("07-hotel-compatibility")
        tap("applyHotel", in: app)
        waitUntilEnabled("checkout", in: app, timeout: 10)
        capture("08-hotel-applied")
        tap("checkout", in: app)

        XCTAssertTrue(app.buttons["resetDemo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["일회성 권한 만료"].exists)
        capture("09-checkout-complete")
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
