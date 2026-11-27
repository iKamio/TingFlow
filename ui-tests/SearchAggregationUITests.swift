import XCTest

final class SearchAggregationUITests: XCTestCase {
    @MainActor func testAggregatedSearchAndConnectedServiceFilters() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowSearchFixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["海风来信"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["夜行者"].exists)
        XCTAssertTrue(app.staticTexts["蓝色时刻"].exists)
        XCTAssertFalse(app.buttons["search-filter-Emby"].exists, "unconfigured Emby is hidden")
        XCTAssertFalse(app.buttons["search-filter-音乐服"].exists, "unconfigured Subsonic server is hidden")
        app.buttons["search-filter-酷狗"].tap()
        XCTAssertTrue(app.staticTexts["夜行者"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["海风来信"].exists, "platform filter selects only its result bucket")
        app.buttons["search-filter-全部"].tap()
        XCTAssertTrue(app.staticTexts["海风来信"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["蓝色时刻"].exists)
        XCTAssertTrue(app.buttons["search-parser-selection"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "search-aggregated-synthetic"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
