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
}
