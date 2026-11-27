import XCTest

/// DEBUG synthetic fixture only. No real account, request, screenshots or remote text artifacts.
/// Main integration provides NowPlaying's `song-comments-open` button; tests do not skip if absent.
final class SongCommentsUITests: XCTestCase {
    @MainActor private func open(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowPolishFixture", "-TingFlowSongCommentsFixture", scenario]
        app.launch()
        let player = app.buttons["展开播放器"]
        XCTAssertTrue(player.waitForExistence(timeout: 15)); player.tap()
        let comments = app.buttons["song-comments-open"]
        XCTAssertTrue(comments.waitForExistence(timeout: 8)); comments.tap()
        XCTAssertTrue(app.navigationBars["歌曲评论"].waitForExistence(timeout: 8))
        return app
    }
    @MainActor func testHotLatestAndManualPagingRemainIsolated() {
        let app = open("paging")
        let hot = "合成热门评论第1页 <b>纯文本</b> https://example.invalid/"
        let latest = "合成最新评论第1页 <b>纯文本</b> https://example.invalid/"
        XCTAssertTrue(app.staticTexts[hot].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["song-comments-total"].label.contains("2"))
        XCTAssertFalse(app.staticTexts["合成热门评论第2页 <b>纯文本</b> https://example.invalid/"].exists, "must not auto-crawl page two")
        let more = app.buttons["song-comments-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3)); more.tap()
        XCTAssertTrue(app.staticTexts["song-comments-end"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["song-comments-more"].exists)
        app.segmentedControls["song-comments-sort"].buttons["最新"].tap()
        XCTAssertTrue(app.staticTexts[latest].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[hot].exists, "switching sort must not mix hot and latest rows")
        XCTAssertFalse(app.links["https://example.invalid/"].exists, "comment URL is plain untrusted text")
        XCTAssertTrue(app.buttons["song-comments-more"].exists)
        app.buttons["song-comments-close"].tap()
        let reopen = app.buttons["song-comments-open"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 5)); reopen.tap()
        XCTAssertTrue(app.staticTexts[hot].waitForExistence(timeout: 5), "reopened sheet starts a fresh hot context")
        XCTAssertFalse(app.staticTexts[latest].exists)
    }
    @MainActor func testEmptyIsGenuineServerZero() {
        let app = open("empty")
        XCTAssertTrue(app.staticTexts["song-comments-empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["song-comments-total"].label.contains("0"))
        XCTAssertFalse(app.buttons["song-comments-more"].exists)
        XCTAssertFalse(app.staticTexts["song-comments-error"].exists)
    }
    @MainActor func testErrorRequiresExplicitRetry() {
        let app = open("error")
        XCTAssertTrue(app.staticTexts["song-comments-error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["song-comments-empty"].exists)
        XCTAssertFalse(app.staticTexts["song-comments-total"].exists, "failed first response cannot invent a total")
        app.buttons["song-comments-retry"].tap()
        XCTAssertTrue(app.buttons["song-comments-more"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["song-comments-error"].exists)
    }
    @MainActor func testLoadingCanBeDismissedWithoutWaitingForNetwork() {
        let app = open("loading")
        XCTAssertTrue(app.descendants(matching: .any)["song-comments-loading"].waitForExistence(timeout: 5))
        app.buttons["song-comments-close"].tap()
        XCTAssertTrue(app.buttons["song-comments-open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["song-comments-loading"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
