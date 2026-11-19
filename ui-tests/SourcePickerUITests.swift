import XCTest

final class SourcePickerUITests: XCTestCase {
    @MainActor func testSelectRealFilesAndKeepScriptQuarantined() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowImportPickerFixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["资料库"].waitForExistence(timeout: 15))
        app.tabBars.buttons["资料库"].tap()
        let accounts = app.staticTexts["账号与服务器"]
        for _ in 0..<3 { if accounts.isHittable && accounts.frame.midY < app.frame.maxY - 180 { break }; app.swipeUp() }
        XCTAssertTrue(accounts.isHittable); accounts.tap()
        let source = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "管理洛雪 JS 音源")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 8)); source.tap()
        XCTAssertTrue(app.navigationBars["自定义音源"].waitForExistence(timeout: 8))
        app.buttons["source-import"].tap()
        openFixtureDirectory(in: app, target: "TingFlow-Wrong-Type")
        let wrong = document("TingFlow-Wrong-Type", in: app)
        XCTAssertTrue(wrong.waitForExistence(timeout: 20), "Must see actual system picker files, not a mocked callback")
        XCTAssertTrue(wrong.isEnabled, "Provider generic text should be selectable")
        capture("18-system-picker-broad-types")
        wrong.tap()
        confirmOpen(in: app)
        XCTAssertTrue(app.alerts["音源管理"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", ".js 音源文件")).firstMatch.exists)
        app.alerts.buttons["知道了"].tap()
        app.buttons["source-import"].tap()
        openFixtureDirectory(in: app, target: "TingFlow-Import-Check")
        let script = document("TingFlow-Import-Check", in: app)
        XCTAssertTrue(script.waitForExistence(timeout: 20)); XCTAssertTrue(script.isEnabled)
        script.tap()
        confirmOpen(in: app)
        XCTAssertTrue(app.alerts["音源管理"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "音源已导入并隔离")).firstMatch.exists)
        app.alerts.buttons["知道了"].tap()
        XCTAssertTrue(app.staticTexts["文件导入测试源"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["已隔离 · 尚未信任"].exists)
        capture("19-system-file-import-quarantined")
        // Trust is a different case of the SAME modal route; cancel then reopen
        // the native picker to catch stale delegate/presentation ownership.
        app.buttons.matching(identifier: "审阅脚本并授权域名").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["审阅并授权"].waitForExistence(timeout: 5))
        app.navigationBars["审阅并授权"].buttons["取消"].tap()
        app.buttons["source-import"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8)); cancel.tap()
        XCTAssertTrue(app.buttons["source-import-paste"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["音源管理"].exists, "native cancel is not an import error")
        app.buttons["source-import-paste"].tap()
        let editor = app.textViews["source-paste-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        // Type explicitly; tests never read or populate the system clipboard.
        editor.typeText("/* @name Paste-Only-Test */\nthrow Error('paste-must-not-run');")
        app.buttons["source-paste-submit"].tap()
        XCTAssertTrue(app.alerts["音源管理"].waitForExistence(timeout: 8))
        app.alerts.buttons["知道了"].tap()
        XCTAssertTrue(app.staticTexts["Paste-Only-Test"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: "已隔离 · 尚未信任").count, 2)
    }
    @MainActor private func confirmOpen(in app: XCUIApplication) {
        // asCopy may label the confirmation Import rather than Open by provider/OS.
        for name in ["导入", "打开", "Import", "Open"] {
            let button = app.buttons[name].firstMatch
            if button.waitForExistence(timeout: 1), button.isHittable { button.tap(); return }
        }
    }
    @MainActor private func openFixtureDirectory(in app: XCUIApplication, target: String) {
        if document(target, in: app).waitForExistence(timeout: 3) { return }
        let browse = app.staticTexts["浏览"].firstMatch
        if browse.waitForExistence(timeout: 6) { browse.tap() }
        let phone = app.staticTexts["我的iPhone"].firstMatch
        if phone.waitForExistence(timeout: 6) { phone.tap() }
        let folder = app.cells.matching(NSPredicate(format: "identifier CONTAINS %@ OR label CONTAINS %@", "SourceImportUITest", "SourceImportUITest")).firstMatch
        if folder.waitForExistence(timeout: 10) { folder.tap() }
    }
    @MainActor private func document(_ name: String, in app: XCUIApplication) -> XCUIElement {
        // Tapping the filename StaticText only selects/highlights it in Files; it
        // doesn't activate the file/provider. Tap the containing native Cell so
        // the picker opens folders or proceeds to the copy confirmation.
        let cell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        if cell.exists { return cell }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }
    @MainActor private func capture(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
    }
}
