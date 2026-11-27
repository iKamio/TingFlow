import XCTest

final class NavigationSmokeTests: XCTestCase {
    @MainActor func testNativeTabsAndLibrary() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.navigationBars["现在就听"].waitForExistence(timeout: 15))
        capture("01-home-native-glass")
        let library = app.tabBars.buttons["资料库"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["账号与服务器"].exists)
        capture("02-library-native-glass")
        app.tabBars.buttons["浏览"].tap()
        XCTAssertTrue(app.navigationBars["浏览"].waitForExistence(timeout: 8))
        capture("03-browse-native-glass")
    }
    @MainActor func testSourceManagerFromLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["资料库"].waitForExistence(timeout: 15))
        app.tabBars.buttons["资料库"].tap()
        app.staticTexts["账号与服务器"].tap()
        let source = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "管理洛雪 JS 音源")).firstMatch
        for _ in 0..<4 {
            if source.exists && source.isHittable && source.frame.midY < app.frame.maxY - 180 { break }
            app.swipeUp()
        }
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        source.tap()
        XCTAssertTrue(app.navigationBars["自定义音源"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["source-import"].exists)
        capture("04-source-manager")
    }
    @MainActor func testServerTypesAndUpdates() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["资料库"].waitForExistence(timeout: 15))
        app.tabBars.buttons["资料库"].tap(); app.staticTexts["账号与服务器"].tap()
        let navidrome = app.staticTexts["Navidrome"]
        for _ in 0..<3 { if navidrome.exists && navidrome.isHittable && navidrome.frame.midY < app.frame.maxY - 180 { break }; app.swipeUp() }
        XCTAssertTrue(navidrome.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Subsonic 兼容服务器"].exists)
        capture("05-server-types")
        navidrome.tap()
        XCTAssertTrue(app.navigationBars["Navidrome 账户"].waitForExistence(timeout: 8))
        capture("06-navidrome-connect")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let update = app.staticTexts["检查更新"]
        for _ in 0..<3 { if update.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(update.waitForExistence(timeout: 5)); update.tap()
        XCTAssertTrue(app.navigationBars["检查更新"].waitForExistence(timeout: 8))
        capture("07-native-updates")
    }
    @MainActor func testModularLibraryAndPlayer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowPolishFixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["现在就听"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["为你精选"].waitForExistence(timeout: 8))
        capture("08-fixture-home-playlist-first")
        let opener = app.buttons["展开播放器"]
        XCTAssertTrue(opener.waitForExistence(timeout: 6)); opener.tap()
        XCTAssertTrue(app.buttons["player-queue"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists, "播放器不再是带抓手的卡片弹层")
        XCTAssertFalse(app.tabBars.buttons["现在就听"].exists && app.tabBars.buttons["现在就听"].isHittable, "全屏播放器覆盖主导航")
        let screen = app.frame
        XCTAssertLessThanOrEqual(app.buttons["player-queue"].frame.maxX, screen.maxX + 1)
        XCTAssertGreaterThanOrEqual(app.buttons["player-lyrics"].frame.minX, screen.minX)
        capture("09-fixture-player-cover")
        app.buttons["player-lyrics"].tap()
        XCTAssertTrue(app.buttons["这一刻只想听见音乐"].waitForExistence(timeout: 5))
        capture("10-fixture-inline-lyrics")
        app.buttons["player-queue"].tap()
        XCTAssertTrue(app.staticTexts["播放队列"].waitForExistence(timeout: 5))
        capture("11-fixture-inline-queue")
        app.buttons["收起播放器"].tap()
        let closed = NSPredicate(format: "exists == false")
        expectation(for: closed, evaluatedWith: app.buttons["player-queue"])
        waitForExpectations(timeout: 6)
        XCTAssertTrue(app.tabBars.buttons["资料库"].waitForExistence(timeout: 6))
        app.tabBars.buttons["资料库"].tap()
        let lists = app.staticTexts["网易云歌单"]
        for _ in 0..<3 { if lists.isHittable && lists.frame.midY < app.frame.maxY - 190 { break }; app.swipeUp() }
        XCTAssertTrue(lists.exists); lists.tap()
        XCTAssertTrue(app.navigationBars["我的歌单"].waitForExistence(timeout: 8))
        capture("12-fixture-my-playlist-grid")
        app.staticTexts.matching(identifier: "留给晚风的歌").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["歌单"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts.matching(identifier: "听流测试音乐").firstMatch.waitForExistence(timeout: 8))
        capture("13-fixture-playlist-detail")
    }
    @MainActor func testNativeScrollingDock() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowPolishFixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["为你精选"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["下一首"].exists)
        let scroll = app.scrollViews.element(boundBy: 0)
        scroll.swipeUp(velocity: .slow)
        let inline = NSPredicate(format: "exists == false")
        expectation(for: inline, evaluatedWith: app.buttons["下一首"])
        waitForExpectations(timeout: 6)
        XCTAssertTrue(app.buttons["展开播放器"].isHittable)
        capture("14-fixture-native-inline-dock")
        scroll.swipeDown(velocity: .slow)
        XCTAssertTrue(app.buttons["下一首"].waitForExistence(timeout: 6))
        capture("15-fixture-native-expanded-dock")
    }
    @MainActor func testFullScreenPlayerSwipeDismissal() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowPolishFixture"]
        app.launch()
        XCTAssertTrue(app.buttons["展开播放器"].waitForExistence(timeout: 15))
        app.buttons["展开播放器"].tap()
        XCTAssertTrue(app.buttons["player-queue"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists)
        XCTAssertFalse(app.tabBars.buttons["现在就听"].exists && app.tabBars.buttons["现在就听"].isHittable)
        capture("16-fixture-fullscreen-player")
        let start = app.staticTexts["原生界面测试数据"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 190)))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["player-queue"])
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["展开播放器"].isHittable)
        XCTAssertTrue(app.staticTexts["海风来信"].exists, "收起不清空当前曲目")
        capture("17-fixture-fullscreen-return")
    }
    /// This verifies app re-entry only, not the OS media-card tap target.
    @MainActor func testBackgroundReturnPreservesCurrentSongAndPlayerNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowPolishFixture"]
        app.launch()
        let opener = app.buttons["展开播放器"]
        XCTAssertTrue(opener.waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        XCTAssertTrue(opener.waitForExistence(timeout: 8))
        XCTAssertTrue(opener.isHittable)
        opener.tap()
        XCTAssertTrue(app.buttons["player-queue"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["海风来信"].exists)
        capture("18-fixture-background-player-return")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        app.activate()
        XCTAssertTrue(app.buttons["player-queue"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["收起播放器"].isHittable)
        capture("19-fixture-background-fullscreen-preserved")
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
