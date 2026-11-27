import XCTest

final class KugouNavigationUITests: XCTestCase {
    @MainActor func testCredentialRemovalCanBeRetriedAfterSignOut() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowPolishFixture", "-TingFlowKugouRemovalFixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["资料库"].waitForExistence(timeout: 15))
        app.tabBars.buttons["资料库"].tap(); app.staticTexts["账号与服务器"].tap()
        app.staticTexts["连接酷狗音乐 · 扫码只读"].tap()
        let signOut = app.buttons["退出此机酷狗账号"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 8)); signOut.tap()
        let retry = app.buttons["kugou-retry-credential-removal"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertFalse(signOut.exists, "即使内存已退出，也必须保留删除凭据重试操作")
        retry.tap()
        let removed = NSPredicate(format: "exists == false")
        expectation(for: removed, evaluatedWith: retry)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts["kugou-credential-removal-pending"].exists)
        XCTAssertTrue(app.buttons["用酷狗 App 扫码登录"].exists)
    }
    @MainActor func testKugouAccountAndReadOnlyLibraryEntrypoints() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowPolishFixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["资料库"].waitForExistence(timeout: 15))
        app.tabBars.buttons["资料库"].tap()
        app.staticTexts["账号与服务器"].tap()
        let login = app.staticTexts["连接酷狗音乐 · 扫码只读"]
        XCTAssertTrue(login.waitForExistence(timeout: 8))
        login.tap()
        XCTAssertTrue(app.navigationBars["酷狗账号"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["用酷狗 App 扫码登录"].exists)
        XCTAssertFalse(app.staticTexts["正在向酷狗申请二维码…"].exists, "导航不可自动申请或轮询二维码")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let cloud = app.staticTexts["酷狗云歌单 · 只读"]
        for _ in 0..<3 {
            if cloud.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(cloud.waitForExistence(timeout: 8)); cloud.tap()
        XCTAssertTrue(app.navigationBars["酷狗歌单"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["登录酷狗账号"].exists)
        XCTAssertFalse(app.buttons["播放全部"].exists, "未登录时不能把合成或跨账号歌曲呈现为真实歌单")
    }
}
