import XCTest

final class StationBoardUITests: XCTestCase {
    @MainActor
    func testStartD174AndKeepItWhenAnotherTrainHasMissingTrack() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["ATLAS_STATION_TEST_DIR"])
        app.launchArguments = ["--ui-smoke", directory, "--station-board-ui", "-AppleLanguages", "(zh-Hans)"]
        app.launch()

        func button(_ id: String, _ label: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, label)).firstMatch
        }
        func tap(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 30), app.debugDescription)
            for _ in 0..<3 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.isHittable, app.debugDescription)
            element.tap()
        }
        func selectTrain(_ train: String, id: String) {
            tap(button("open-station-directory", "全线站点与本站车次"))
            let search = app.textFields.firstMatch
            tap(search)
            search.typeText(train + "\n")
            let row = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", id, train)).firstMatch
            tap(row)
            tap(button("station-board-start", "在主地图沿线旅行"))
        }
        func checkCurrentRide() {
            let header = app.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@ AND value CONTAINS %@ AND value CONTAINS %@", "D174", "2026-11-26", "广元 → 攀枝花南")).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 25), app.debugDescription)
            XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 10))
        }
        selectTrain("D174", id: "station-board-run-880000D17403/2026-11-26/8")
        checkCurrentRide()
        tap(button("map-open-sidebar", "广元"))
        selectTrain("Z316", id: "station-board-run-760000Z31604/2026-11-25/2")
        let error = app.staticTexts.matching(NSPredicate(format: "identifier == %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                                         "station-board-error", "缺少", "轨迹")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 20), app.debugDescription)
        tap(app.buttons["完成"])
        // Dismiss the station inspector to inspect the running train on the map again.
        let sheet = app.sheets.firstMatch
        if sheet.exists { sheet.swipeDown(); if sheet.exists { sheet.swipeDown() } }
        checkCurrentRide()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "D174 from Guangyuan after a rejected Z316"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
