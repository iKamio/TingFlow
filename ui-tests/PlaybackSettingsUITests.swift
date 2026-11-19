import XCTest

/// Real navigation through both settings owners, including the toolbar sheet.
final class PlaybackSettingsUITests: XCTestCase {
    @MainActor func testQualityPageFromToolbarSheet() throws {
        try openAndExerciseSettings(fromToolbar: true)
    }
    @MainActor func testQualityPageFromLibraryNavigation() throws {
        try openAndExerciseSettings(fromToolbar: false)
    }
    @MainActor private func openAndExerciseSettings(fromToolbar: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.navigationBars["现在就听"].waitForExistence(timeout: 15))
        if fromToolbar {
            let account = app.buttons["账号与服务器设置"]
            XCTAssertTrue(account.waitForExistence(timeout: 8)); account.tap()
        } else {
            app.tabBars.buttons["资料库"].tap()
            let account = app.staticTexts["账号与服务器"]
            XCTAssertTrue(account.waitForExistence(timeout: 8)); account.tap()
        }
        XCTAssertTrue(app.navigationBars["账号与设置"].waitForExistence(timeout: 8))
        let quality = app.staticTexts["音质与界面"]
        for _ in 0..<6 {
            if quality.exists && quality.isHittable && quality.frame.midY < app.frame.maxY - 160 { break }
            app.swipeUp()
        }
        XCTAssertTrue(quality.waitForExistence(timeout: 6)); XCTAssertTrue(quality.isHittable)
        capture(fromToolbar ? "21-toolbar-before-quality" : "22-library-before-quality")
        quality.tap()
        XCTAssertTrue(app.navigationBars["播放与界面"].waitForExistence(timeout: 10), "设置页面必须打开，不能因缺少依赖或渲染错误终止进程")
        XCTAssertTrue(app.staticTexts["请求方式"].exists)
        XCTAssertTrue(app.staticTexts["请求音质"].exists)
        capture(fromToolbar ? "23-toolbar-quality-page" : "24-library-quality-page")
        let toggle = app.switches["playback-minimize"]
        for _ in 0..<3 { if toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
        XCTAssertTrue(app.navigationBars["播放与界面"].exists, "偏好修改不能弹出当前页面")
        toggle.tap() // restore the original setting; don't leak state to other UI tests.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["账号与设置"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.state, .runningForeground)
    }
    @MainActor private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
