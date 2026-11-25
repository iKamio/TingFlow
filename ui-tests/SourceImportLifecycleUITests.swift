import XCTest

/// Exercises the real account navigation and explicit paste modal; no mocked
/// picker callback, clipboard access, network request or script evaluation.
final class SourceImportLifecycleUITests: XCTestCase {
    @MainActor func testPasteDismissalAndPageReturnKeepImportedQuarantine() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowImportPickerFixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["资料库"].waitForExistence(timeout: 15))
        app.tabBars.buttons["资料库"].tap()
        let accounts = app.staticTexts["账号与服务器"]
        for _ in 0..<3 {
            if accounts.isHittable && accounts.frame.midY < app.frame.maxY - 180 { break }
            app.swipeUp()
        }
        XCTAssertTrue(accounts.isHittable); accounts.tap()
        openManager(app)
        let paste = app.buttons["source-import-paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
        let editor = app.textViews["source-paste-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("/* @name Import-Lifecycle-Only */\nthrow Error('lifecycle-import-must-not-run');")
        let submit = app.buttons["source-paste-submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5)); submit.tap()
        XCTAssertTrue(app.alerts["音源管理"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "音源已导入并隔离")).firstMatch.exists)
        app.alerts.buttons["知道了"].tap()
        XCTAssertTrue(app.staticTexts["Import-Lifecycle-Only"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已隔离 · 尚未信任"].exists, "import must not initialize or run a source")
        let back = app.navigationBars["自定义音源"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.exists); back.tap()
        XCTAssertTrue(app.navigationBars["账号与设置"].waitForExistence(timeout: 8))
        openManager(app)
        XCTAssertTrue(app.staticTexts["Import-Lifecycle-Only"].waitForExistence(timeout: 5), "a true page exit must not remove an already committed imported source")
        XCTAssertTrue(app.staticTexts["已隔离 · 尚未信任"].exists)
        XCTAssertTrue(app.buttons["source-import"].isEnabled && app.buttons["source-import-paste"].isEnabled,
                      "re-entry must create a usable new owner, not retain a stale presentation lock")
        XCTAssertFalse(app.alerts["音源管理"].exists, "no old modal notice may return after re-entry")
    }
    @MainActor private func openManager(_ app: XCUIApplication) {
        let source = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "管理洛雪 JS 音源")).firstMatch
        for _ in 0..<4 {
            if source.exists && source.isHittable && source.frame.midY < app.frame.maxY - 180 { break }
            app.swipeUp()
        }
        XCTAssertTrue(source.waitForExistence(timeout: 8)); XCTAssertTrue(source.isHittable); source.tap()
        XCTAssertTrue(app.navigationBars["自定义音源"].waitForExistence(timeout: 8))
    }
}
