import XCTest

final class OrigamiUITests: XCTestCase {
    @MainActor
    func testTabsNavigationAndLayouts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let address = app.textFields["omnibox"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertEqual(tabs.count, 1)
        for index in 1..<20 {
            app.typeKey("t", modifierFlags: .command)
            let count = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tabs.count == index + 1 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [count], timeout: 5), .completed)
        }
        XCTAssertEqual(tabs.count, 20)
        app.activate()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(tabs.count, 19)
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertEqual(tabs.count, 20)
        app.typeKey("l", modifierFlags: .command)
        app.typeText("https://example.com")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.staticTexts["Example Domain"].waitForExistence(timeout: 20))
        app.descendants(matching: .any)["tabLayoutMenu"].firstMatch.click()
        app.menuItems["Vertical Tabs"].click()
        XCTAssertTrue(app.descendants(matching: .any)["verticalTabs"].firstMatch.waitForExistence(timeout: 5))
        let vertical = XCTAttachment(screenshot: app.screenshot())
        vertical.name = "Vertical tabs with web content"
        vertical.lifetime = .keepAlways
        add(vertical)
        app.descendants(matching: .any)["tabLayoutMenu"].firstMatch.click()
        app.menuItems["Horizontal Tabs"].click()
        XCTAssertTrue(app.descendants(matching: .any)["horizontalTabs"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.tab, modifierFlags: [.control, .shift])
        XCTAssertTrue(app.textFields["newTabSearch"].waitForExistence(timeout: 5))
        app.typeKey(.tab, modifierFlags: [.control])
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Horizontal tabs with web content"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor
    func testSessionRelaunchAndSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["ORIGAMI_UI_SESSION_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.textFields["omnibox"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertEqual(tabs.count, 2)
        app.typeKey("l", modifierFlags: .command)
        app.typeText("https://example.com/")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        tabs.element(boundBy: 1).rightClick()
        app.menuItems["Pin Tab"].click()
        app.descendants(matching: .any)["tabLayoutMenu"].firstMatch.click()
        app.menuItems["Vertical Tabs"].click()
        app.menuBars.menuBarItems["Origami"].click()
        app.menuItems["Settings…"].click()
        let picker = app.descendants(matching: .any)["searchEnginePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        app.menuItems["DuckDuckGo"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(picker.exists)
        XCTAssertEqual(tabs.count, 2)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["omnibox"].waitForExistence(timeout: 10))
        XCTAssertEqual(tabs.count, 2)
        XCTAssertTrue(app.descendants(matching: .any)["verticalTabs"].firstMatch.exists)
        XCTAssertEqual(app.textFields["omnibox"].value as? String, "https://example.com/")
        tabs.element(boundBy: 0).rightClick()
        XCTAssertTrue(app.menuItems["Unpin Tab"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Search with DuckDuckGo"].waitForExistence(timeout: 5))
    }

}
