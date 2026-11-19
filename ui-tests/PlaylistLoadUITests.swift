import XCTest

/// Uses only the existing debug UI fixture, never a real account or network.
/// Hung callback/deadline/risk cases live in NeteasePlaylistLoadChecks; adding
/// end-to-end fault injection requires the fixture owner's coordinated hook.
final class PlaylistLoadUITests: XCTestCase {
    @MainActor func testFixturePlaylistCompletesAndCanReopenWithoutSpinner() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowPolishFixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["资料库"].waitForExistence(timeout: 15))
        app.tabBars.buttons["资料库"].tap()
        let lists = app.staticTexts["网易云歌单"]
        for _ in 0..<4 {
            if lists.isHittable && lists.frame.midY < app.frame.maxY - 190 { break }
            app.swipeUp()
        }
        XCTAssertTrue(lists.exists)
        lists.tap()
        XCTAssertTrue(app.navigationBars["我的歌单"].waitForExistence(timeout: 8))
        for _ in 0..<2 {
            app.staticTexts.matching(identifier: "留给晚风的歌").firstMatch.tap()
            XCTAssertTrue(app.navigationBars["歌单"].waitForExistence(timeout: 6))
            let complete = app.staticTexts["playlist-load-complete"]
            XCTAssertTrue(complete.waitForExistence(timeout: 8))
            XCTAssertTrue(complete.label.contains("6"))
            XCTAssertFalse(app.descendants(matching: .any)["playlist-load-spinner"].exists)
            XCTAssertFalse(app.staticTexts["playlist-load-error"].exists)
            XCTAssertTrue(app.staticTexts.matching(identifier: "听流测试音乐").firstMatch.waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["我的歌单"].waitForExistence(timeout: 6))
        }
    }
}
