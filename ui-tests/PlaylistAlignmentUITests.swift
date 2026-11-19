import XCTest

final class PlaylistAlignmentUITests: XCTestCase {
    @MainActor func testMixedArtworkAndTitleLengthsStayAligned() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-TingFlowPolishFixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["浏览"].waitForExistence(timeout: 15))
        app.tabBars.buttons["浏览"].tap()
        let scroll = app.scrollViews.firstMatch
        let first = cover("100", app: app), second = cover("101", app: app)
        for _ in 0..<4 { if first.isHittable && second.isHittable { break }; scroll.swipeUp(velocity: .slow) }
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.exists)
        square(first); square(second)
        XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 1.5, "square and landscape images have identical containers")
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1.5, "long title cannot vertically center one cover")
        let columnWidth = first.frame.width
        let missing = cover("102", app: app), portrait = cover("103", app: app)
        for _ in 0..<3 { if missing.isHittable && portrait.isHittable { break }; scroll.swipeUp(velocity: .slow) }
        XCTAssertTrue(missing.waitForExistence(timeout: 5)); XCTAssertTrue(portrait.exists)
        square(missing); square(portrait)
        XCTAssertEqual(missing.frame.width, portrait.frame.width, accuracy: 1.5, "placeholder and portrait use one square size")
        XCTAssertEqual(missing.frame.minY, portrait.frame.minY, accuracy: 1.5, "second row shares a top edge")
        XCTAssertEqual(columnWidth, missing.frame.width, accuracy: 1.5, "same grid uses a single width across rows")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "20-fixture-mixed-covers-aligned"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func cover(_ id: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "playlist-cover-" + id).firstMatch
    }
    @MainActor private func square(_ element: XCUIElement) {
        XCTAssertGreaterThan(element.frame.width, 120, "preserve existing cover scale, do not shrink")
        XCTAssertEqual(element.frame.width, element.frame.height, accuracy: 1.5, "artwork is exactly square")
    }
}
