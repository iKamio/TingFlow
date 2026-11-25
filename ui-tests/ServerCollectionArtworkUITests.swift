import XCTest

final class ServerCollectionArtworkUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowServerCoverFixture"]
        app.launch()
        return app
    }
    @MainActor private func artwork(_ index: Int, header: Bool = false, app: XCUIApplication) -> XCUIElement {
        let kind = index == 3 ? "album" : "playlist"
        let suffix = header ? ".header.artwork" : ".artwork"
        return app.descendants(matching: .any).matching(identifier: "serverCollection.fixture.\(kind).\(index)" + suffix).firstMatch
    }
    @MainActor private func square(_ element: XCUIElement, expected: CGFloat) {
        XCTAssertEqual(element.frame.width, expected, accuracy: 1.5)
        XCTAssertEqual(element.frame.width, element.frame.height, accuracy: 1.5, "server artwork container remains square regardless of image aspect or text")
    }
    @MainActor private func value(_ expected: String, element: XCUIElement) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 8), .completed)
    }
    @MainActor func testMixedAspectAndMissingCollectionCoversHaveOneRowSize() {
        let app = launch()
        let first = artwork(0, app: app), landscape = artwork(1, app: app)
        let missing = artwork(2, app: app), portrait = artwork(3, app: app)
        for element in [first, landscape, missing, portrait] {
            XCTAssertTrue(element.waitForExistence(timeout: 10))
            square(element, expected: 60)
        }
        value("已载入服务器封面", element: first)
        value("已载入服务器封面", element: landscape)
        value("服务器未提供封面", element: missing)
        value("已载入服务器封面", element: portrait)
        // Validate again after decoding: loaded aspect-fill pixels must not
        // expand the original placeholder's geometry or accessibility region.
        for element in [first, landscape, missing, portrait] { square(element, expected: 60) }
        XCTAssertEqual(first.frame.width, landscape.frame.width, accuracy: 1)
        XCTAssertEqual(missing.frame.width, portrait.frame.width, accuracy: 1)
        XCTAssertTrue(app.buttons["serverCoverFixture.row.0"].exists || app.descendants(matching: .any).matching(identifier: "serverCoverFixture.row.0").firstMatch.exists)
    }
    @MainActor func testCollectionHeaderUsesLargeCoverAndClearsOnScopeLoss() {
        let app = launch()
        let row = app.descendants(matching: .any).matching(identifier: "serverCoverFixture.row.0").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let header = artwork(0, header: true, app: app)
        XCTAssertTrue(header.waitForExistence(timeout: 8)); square(header, expected: 210)
        value("已载入服务器封面", element: header)
        let signOut = app.buttons["serverCoverFixture.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5)); signOut.tap()
        value("封面暂未载入", element: header)
        XCTAssertTrue(app.staticTexts["封面暂未载入"].exists, "late or previous-account image is not kept after account loss")
    }

    @MainActor private func launchDiagnostics() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                                "-TingFlowServerCoverFixture", "-TingFlowServerCoverDiagnosticFixture"]
        app.launch()
        return app
    }
    @MainActor private func diagnosticID(_ index: Int) -> String {
        let kind = index == 3 ? "album" : "playlist"
        return "serverCollection.fixture.\(kind).\(index).header.artwork.diagnostic"
    }
    @MainActor private func openFixtureRow(_ index: Int, app: XCUIApplication) {
        let row = app.descendants(matching: .any).matching(identifier: "serverCoverFixture.row.\(index)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        XCTAssertTrue(artwork(index, header: true, app: app).waitForExistence(timeout: 8))
    }
    @MainActor private func openDiagnostic(_ index: Int, app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[diagnosticID(index)]
        XCTAssertTrue(button.waitForExistence(timeout: 8)); button.tap()
        let summary = app.staticTexts[diagnosticID(index) + ".summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["封面诊断"].exists)
        return summary
    }
    @MainActor private func closeDiagnostic(_ index: Int, app: XCUIApplication) {
        let close = app.buttons[diagnosticID(index) + ".close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                              object: app.staticTexts[diagnosticID(index) + ".summary"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }
    @MainActor private func backToFixtureList(app: XCUIApplication) {
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "identifier != %@", "serverCoverFixture.signOut")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(artwork(0, app: app).waitForExistence(timeout: 8))
    }
    @MainActor private func assertSafeDiagnostic(_ summary: XCUIElement) {
        let text = summary.label
        for forbidden in ["https://", "http://", "synthetic.invalid", "synthetic-cover-scope",
                          "synthetic-cover-secret-id", "synthetic-cover-token", "serverCollection.fixture",
                          "接口权限错误（合成）", "未找到封面（合成）", "缩略图解码失败（合成）",
                          "重试与取消隔离（合成）", "合成测试艺术家"] {
            XCTAssertFalse(text.contains(forbidden), "diagnostic excludes synthetic private context")
        }
    }

    @MainActor func testDiagnosticFailureIsSafeExplicitlyCopiedAndDismissedOnScopeLoss() {
        let app = launchDiagnostics()
        XCTAssertTrue(artwork(0, app: app).waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["serverCollection.fixture.playlist.0.artwork.diagnostic"].exists,
                       "diagnostic entry is detail-only")
        openFixtureRow(0, app: app)
        let header = artwork(0, header: true, app: app)
        value("封面暂未载入", element: header); square(header, expected: 210)
        let summary = openDiagnostic(0, app: app)
        for expected in ["服务：Navidrome", "HTTP：200", "Subsonic 状态：failed", "Subsonic 接口码：50",
                         "阶段：Subsonic 错误响应", "响应类型：application/json"] {
            XCTAssertTrue(summary.label.contains(expected))
        }
        assertSafeDiagnostic(summary)
        let copy = app.buttons[diagnosticID(0) + ".copy"]
        XCTAssertTrue(copy.exists); XCTAssertTrue(copy.isHittable)
        XCTAssertEqual(copy.label, "复制诊断")
        XCTAssertEqual(copy.value as? String, "尚未复制", "opening the sheet does not auto-copy")
        copy.tap(); value("已复制", element: copy)
        closeDiagnostic(0, app: app)
        let delayedSignOut = app.buttons["serverCoverFixture.signOutAfterDelay"]
        XCTAssertTrue(delayedSignOut.waitForExistence(timeout: 5)); delayedSignOut.tap()
        let reopened = openDiagnostic(0, app: app)
        XCTAssertEqual(app.buttons[diagnosticID(0) + ".copy"].value as? String, "尚未复制")
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: reopened)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 20), .completed)
        value("封面暂未载入", element: header)
        XCTAssertFalse(app.buttons[diagnosticID(0)].exists, "account loss hides the old diagnostic entry")
        XCTAssertFalse(app.buttons[diagnosticID(0) + ".copy"].exists)
        square(header, expected: 210)
    }

    @MainActor func testMissingThumbnailAndRetryDiagnosticsStayRequestScopedAfterCancellation() {
        let app = launchDiagnostics()
        openFixtureRow(1, app: app)
        value("服务器未提供封面", element: artwork(1, header: true, app: app))
        let missing = openDiagnostic(1, app: app)
        for expected in ["HTTP：200", "Subsonic 接口码：70", "阶段：Subsonic 错误响应", "结果：服务器返回未找到封面"] {
            XCTAssertTrue(missing.label.contains(expected))
        }
        assertSafeDiagnostic(missing)
        closeDiagnostic(1, app: app); backToFixtureList(app: app)

        openFixtureRow(2, app: app)
        value("封面暂未载入", element: artwork(2, header: true, app: app))
        let thumbnail = openDiagnostic(2, app: app)
        for expected in ["HTTP：200", "阶段：界面缩略图解码", "结果：缩略图无法解码", "图片格式：PNG", "响应类型：image/png"] {
            XCTAssertTrue(thumbnail.label.contains(expected))
        }
        XCTAssertFalse(thumbnail.label.contains("Subsonic 接口码：70"))
        assertSafeDiagnostic(thumbnail)
        closeDiagnostic(2, app: app); backToFixtureList(app: app)

        openFixtureRow(3, app: app)
        let header = artwork(3, header: true, app: app)
        value("封面暂未载入", element: header)
        let failure = openDiagnostic(3, app: app)
        XCTAssertTrue(failure.label.contains("Subsonic 接口码：50"))
        closeDiagnostic(3, app: app)
        let retryID = "serverCollection.fixture.album.3.header.artwork.retry"
        let retry = app.buttons[retryID]
        XCTAssertTrue(retry.waitForExistence(timeout: 5)); retry.tap()
        value("正在载入封面…", element: header)
        XCTAssertFalse(app.buttons[diagnosticID(3)].exists, "retry clears the prior diagnostic immediately")
        value("已载入服务器封面", element: header); square(header, expected: 210)
        let fresh = openDiagnostic(3, app: app)
        for expected in ["HTTP：200", "阶段：取图完成", "结果：无", "图片格式：PNG", "Subsonic 接口码：未观察到"] {
            XCTAssertTrue(fresh.label.contains(expected))
        }
        XCTAssertFalse(fresh.label.contains("Subsonic 接口码：50"), "retry success cannot reuse the previous failure")
        assertSafeDiagnostic(fresh)
        closeDiagnostic(3, app: app); backToFixtureList(app: app)

        // Re-entering starts a new header request: fail, then a delayed retry.
        // Revoke its scope while loading and wait for the actual late callback,
        // not an arbitrary test sleep, before asserting isolation.
        openFixtureRow(3, app: app)
        let cancelledHeader = artwork(3, header: true, app: app)
        value("封面暂未载入", element: cancelledHeader)
        let cancelledRetry = app.buttons[retryID]
        XCTAssertTrue(cancelledRetry.waitForExistence(timeout: 5)); cancelledRetry.tap()
        value("正在载入封面…", element: cancelledHeader)
        let signOut = app.buttons["serverCoverFixture.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5)); signOut.tap()
        value("封面暂未载入", element: cancelledHeader)
        let completion = app.staticTexts["serverCoverFixture.retryCompletion"]
        XCTAssertTrue(completion.waitForExistence(timeout: 5))
        let lateCallback = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "合成重试完成：2"), object: completion)
        XCTAssertEqual(XCTWaiter.wait(for: [lateCallback], timeout: 10), .completed)
        value("封面暂未载入", element: cancelledHeader); square(cancelledHeader, expected: 210)
        XCTAssertFalse(app.buttons[diagnosticID(3)].exists, "cancelled late success cannot revive an old-account diagnostic")
        XCTAssertFalse(app.staticTexts[diagnosticID(3) + ".summary"].exists)
        XCTAssertFalse(app.buttons[retryID].exists)
    }
}
