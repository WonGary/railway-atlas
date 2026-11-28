import XCTest

final class StationBoardUITests: XCTestCase {
    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication, scrolling scroll: XCUIElement? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), app.debugDescription, file: file, line: line)
        if let scroll {
            for _ in 0..<4 where !element.isHittable { scroll.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, app.debugDescription, file: file, line: line)
        element.tap()
    }

    @MainActor
    func testMapPanelsKeepSelectionAndAppearanceAfterRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let parent = try XCTUnwrap(ProcessInfo.processInfo.environment["ATLAS_STATION_TEST_DIR"])
        app.launchArguments = ["--ui-smoke", parent + "/panels-" + UUID().uuidString,
                               "--station-board-ui", "-AppleLanguages", "(zh-Hans)"]
        app.launch()

        let textOnly = app.segmentedControls.buttons["仅文字"]
        func scaleSlider() -> XCUIElement {
            let slider = app.sliders["opacity-scaleOpacity"]
            let scroll = app.scrollViews.containing(.slider, identifier: "opacity-scaleOpacity").firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 10), app.debugDescription)
            for _ in 0..<4 where !slider.isHittable { scroll.swipeUp() }
            XCTAssertTrue(slider.isHittable, app.debugDescription)
            return slider
        }
        tap(app.buttons["sidebar-close"], in: app)
        tap(app.buttons["collapse-map-launcher"], in: app)
        XCTAssertFalse(app.buttons["map-open-sidebar"].exists)
        tap(app.buttons["restore-map-launcher"], in: app)
        let launcher = app.buttons["map-open-sidebar"]
        XCTAssertTrue(launcher.label.contains("广元"), app.debugDescription)
        tap(launcher, in: app)
        tap(app.buttons["sidebar-open-settings"], in: app)
        tap(textOnly, in: app)
        XCTAssertTrue(textOnly.isSelected)
        let slider = scaleSlider()
        let before = try XCTUnwrap(slider.value as? String)
        slider.adjust(toNormalizedSliderPosition: 0.75)
        let recorded = try XCTUnwrap(slider.value as? String)
        XCTAssertNotEqual(recorded, before)
        tap(app.buttons["完成"], in: app)
        tap(app.buttons["sidebar-close"], in: app)
        tap(launcher, in: app)
        app.terminate()
        app.launch()
        // Exercise the second visible gear while the station sidebar is at its medium detent.
        XCTAssertTrue(app.buttons["sidebar-open-settings"].waitForExistence(timeout: 15), app.debugDescription)
        tap(app.buttons["map-toolbar-settings"], in: app)
        XCTAssertTrue(textOnly.waitForExistence(timeout: 10) && textOnly.isSelected, app.debugDescription)
        XCTAssertEqual(scaleSlider().value as? String, recorded)
    }

    @MainActor
    func testStartD174AndKeepItWhenAnotherTrainHasMissingTrack() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["ATLAS_STATION_TEST_DIR"])
        app.launchArguments = ["--ui-smoke", directory, "--station-board-ui", "-AppleLanguages", "(zh-Hans)"]
        app.launch()

        func selectTrain(_ train: String, id: String) {
            let entry = app.buttons["open-station-directory"]
            let inspector = app.scrollViews.containing(.button, identifier: "open-station-directory").firstMatch
            tap(entry, in: app, scrolling: inspector)
            let search = app.textFields["station-board-search"]
            tap(search, in: app)
            search.typeText(train + "\n")
            tap(app.buttons[id], in: app)
            tap(app.buttons["station-board-start"], in: app)
        }
        func checkCurrentRide() {
            let header = app.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@ AND value CONTAINS %@ AND value CONTAINS %@", "D174", "2026-11-26", "广元 → 攀枝花南")).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 25), app.debugDescription)
            let pause = app.buttons["暂停"]
            XCTAssertTrue(pause.waitForExistence(timeout: 10) && pause.isHittable, app.debugDescription)
        }
        selectTrain("D174", id: "station-board-run-880000D17403/2026-11-26/8")
        checkCurrentRide()
        tap(app.buttons["collapse-map-player"], in: app)
        let restore = app.buttons["restore-map-player"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["暂停"].exists)
        tap(restore, in: app)
        checkCurrentRide()
        tap(app.buttons["map-open-sidebar"], in: app)
        selectTrain("Z316", id: "station-board-run-760000Z31604/2026-11-25/2")
        let error = app.staticTexts["station-board-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(error.label.contains("缺少连续轨迹：广元 → 汉中"), error.label)
        tap(app.buttons["完成"], in: app)
        tap(app.buttons["sidebar-close"], in: app)
        checkCurrentRide()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "D174 from Guangyuan after a rejected Z316"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
