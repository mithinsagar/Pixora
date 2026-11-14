import XCTest

/// Drives the real app on a simulator: import + scan a labelled test card, name people, Find with All / Any,
/// viewer, export sheet, Slideshow Studio + player, and the whole Private Space flow. Set PIXORA_TEST_CARD to a
/// folder of photos (tools/make_test_card.py) before running.
final class FlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        let card = ProcessInfo.processInfo.environment["PIXORA_TEST_CARD"] ?? ""
        if !card.isEmpty { app.launchEnvironment["PIXORA_TEST_FOLDER"] = card; app.launchEnvironment["PIXORA_AUTOSCAN"] = "1" }
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func tab(_ name: String) { app.tabBars.buttons[name].tap() }

    private func finishScan() {
        XCTAssertTrue(app.staticTexts["Scan complete"].waitForExistence(timeout: 240), "scan did not finish")
        shot("01-scan-complete")
    }

    func test1_ScanNameFindViewExportSlideshow() {
        app.launch()
        finishScan()
        let review = app.buttons["Name People and Review"]
        if review.exists { review.tap() } else { app.buttons["Done"].tap(); tab("People") }
        tab("People")
        sleep(1)
        shot("02-people-unnamed")

        // Name every group the scan found.
        for name in ["Ana", "Ben", "Cara", "Dev"] {
            let nameButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Name this group'")).firstMatch
            guard nameButton.waitForExistence(timeout: 5) else { break }
            nameButton.tap()
            let field = app.textFields["name.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            if name == "Ana" { shot("03-name-sheet") }
            field.typeText(name)
            app.buttons["name.save"].tap()
            sleep(2)
        }
        shot("04-people-named")

        // Find: two people, All then Any.
        tab("Find")
        XCTAssertTrue(app.buttons["person.Ana"].waitForExistence(timeout: 5))
        app.buttons["person.Ana"].tap()
        sleep(1)
        let one = photoCount()
        app.buttons["person.Ben"].tap()
        sleep(2)
        let all = photoCount()
        shot("05-find-all")
        app.segmentedControls["find.mode"].buttons["Any of them"].tap()
        sleep(2)
        let any = photoCount()
        shot("06-find-any")
        print("FIND counts: Ana=\(one) Ana&Ben all=\(all) any=\(any)")
        XCTAssertGreaterThan(one, 0)
        XCTAssertGreaterThanOrEqual(any, all)
        XCTAssertGreaterThanOrEqual(any, one)
        XCTAssertLessThanOrEqual(all, one)

        // Viewer.
        let firstPhoto = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 5))
        firstPhoto.tap()
        XCTAssertTrue(app.buttons["viewer.close"].waitForExistence(timeout: 5))
        sleep(1)
        shot("07-viewer")
        app.buttons["viewer.close"].tap()

        // Select and open the save sheet.
        app.buttons["find.select"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).element(boundBy: 0).tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).element(boundBy: 1).tap()
        shot("08-find-selecting")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["export.files"].waitForExistence(timeout: 5))
        shot("09-export-sheet")
        app.buttons["Cancel"].tap()
        app.buttons["find.select"].tap()

        // Slideshow Studio with music opted in: the player must still start muted.
        app.buttons["find.slideshow"].tap()
        XCTAssertTrue(app.buttons["studio.play"].waitForExistence(timeout: 5))
        sleep(1)
        shot("10-studio")
        let musicSwitch = app.switches["studio.music"]
        app.swipeUp(); app.swipeUp()
        if musicSwitch.waitForExistence(timeout: 3) { musicSwitch.switches.firstMatch.exists ? musicSwitch.switches.firstMatch.tap() : musicSwitch.tap() }
        sleep(1)
        shot("11-studio-music")
        app.buttons["studio.play"].tap()
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 8))
        sleep(2)
        shot("12-player")
        let music = app.buttons["player.music"]
        if !music.exists { app.tap() }   // controls auto-hide after a few seconds
        XCTAssertTrue(music.waitForExistence(timeout: 3))
        XCTAssertEqual(music.label, "Play music", "music must start muted until the speaker is tapped")
        app.buttons["player.close"].tap()
    }

    func test2_PrivateSpace() {
        app.launch()
        if app.staticTexts["Scan complete"].waitForExistence(timeout: 240) { app.buttons["Done"].tap() }
        tab("Private")
        let password = "violet harbour 42"
        if app.secureTextFields["private.new"].waitForExistence(timeout: 5) {
            shot("20-private-setup")
            app.secureTextFields["private.new"].tap()
            app.secureTextFields["private.new"].typeText(password)
            app.secureTextFields["private.confirm"].tap()
            app.secureTextFields["private.confirm"].typeText(password)
            app.buttons["private.create"].tap()
            XCTAssertTrue(app.buttons["private.done"].waitForExistence(timeout: 20))
            shot("21-private-keep-copy")
            XCTAssertTrue(app.buttons["private.savePasswordFile"].exists)
            app.buttons["private.done"].tap()
        } else {
            unlock(password)
        }
        XCTAssertTrue(app.buttons["private.lock"].waitForExistence(timeout: 10))
        shot("22-private-unlocked-empty")

        // Lock, wrong password, right password.
        app.buttons["private.lock"].tap()
        XCTAssertTrue(app.secureTextFields["private.password"].waitForExistence(timeout: 3), "lock should be immediate")
        shot("23-private-locked")
        app.secureTextFields["private.password"].tap()
        app.secureTextFields["private.password"].typeText("wrong password!")
        app.buttons["private.unlock"].tap()
        XCTAssertTrue(app.staticTexts["private.error"].waitForExistence(timeout: 15))
        shot("24-private-wrong")
        XCTAssertEqual(app.secureTextFields["private.password"].value as? String ?? "", "Password", "the field empties after a wrong password")
        unlock(password)

        // Leaving the tab locks it.
        tab("Library")
        tab("Private")
        XCTAssertTrue(app.secureTextFields["private.password"].waitForExistence(timeout: 3), "switching tabs should lock")

        // Make a person private; they disappear from Find while locked.
        tab("People")
        let dev = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dev,'")).firstMatch
        if dev.waitForExistence(timeout: 5) {
            dev.tap()
            app.buttons["person.menu"].tap()
            app.buttons["Make Private"].tap()
            app.buttons["Make Private"].firstMatch.tap()
            sleep(2)
            tab("Find")
            XCTAssertFalse(app.buttons["person.Dev"].exists, "a private person must not appear while locked")
            shot("25-find-without-private-person")
            tab("Private")
            unlock(password)
            sleep(2)
            shot("26-private-with-photos")
            app.segmentedControls.buttons.element(boundBy: 1).tap()
            sleep(1)
            shot("27-private-people")
        }

        // Delete Private Space (what a forgotten password leads to).
        app.buttons["Private Space options"].tap()
        app.buttons["Delete Private Space"].tap()
        XCTAssertTrue(app.switches["private.understand"].waitForExistence(timeout: 5))
        shot("28-private-delete")
        app.switches["private.understand"].switches.firstMatch.exists ? app.switches["private.understand"].switches.firstMatch.tap() : app.switches["private.understand"].tap()
        app.buttons["private.delete"].tap()
        XCTAssertTrue(app.staticTexts["You can start again"].waitForExistence(timeout: 10))
        shot("29-private-deleted")
    }

    func test4_ReviewFullScreen() {
        app.launch()
        if app.staticTexts["Scan complete"].waitForExistence(timeout: app.launchEnvironment["PIXORA_AUTOSCAN"] == nil ? 3 : 240) { app.buttons["Done"].tap() }
        tab("Review")
        let open = app.buttons["review.fullscreen"].firstMatch
        guard open.waitForExistence(timeout: 5) else { shot("40-review-nothing"); return }
        XCTAssertFalse(app.staticTexts["Is this Unnamed?"].exists, "never asks about unnamed groups")
        shot("40-review")
        open.tap()
        XCTAssertTrue(app.buttons["reviewfull.yes"].waitForExistence(timeout: 5))
        sleep(1)
        shot("41-review-fullscreen")
        app.buttons["Zoom"].tap()
        sleep(1)
        shot("42-review-zoomed")
        app.buttons["Whole Photo"].tap()
        sleep(1)
        app.otherElements.firstMatch.pinch(withScale: 2.5, velocity: 2)   // two-finger pinch on the photo
        sleep(1)
        shot("43-review-pinched")
        XCTAssertTrue(app.buttons["Whole Photo"].exists, "pinching zooms in")
        app.buttons["reviewfull.close"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "closing returns to Review")
    }

    private func unlock(_ password: String) {
        let field = app.secureTextFields["private.password"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(password)
        app.buttons["private.unlock"].tap()
        XCTAssertTrue(app.buttons["private.lock"].waitForExistence(timeout: 20), "correct password should unlock")
    }

    /// Reads "12 PHOTOS" from the results header.
    private func photoCount() -> Int {
        let label = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9,]+ PHOTOS?$'")).firstMatch
        guard label.waitForExistence(timeout: 5) else { return 0 }
        return Int(label.label.split(separator: " ")[0].replacingOccurrences(of: ",", with: "")) ?? 0
    }
}

final class PhotosImportTests: XCTestCase {
    /// Import through the real system Photos picker (photos added to the simulator with `simctl addmedia`).
    func test3_ImportFromPhotosLibrary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons["library.add"].tap()
        app.buttons["import.photos"].tap()
        let picker = app.otherElements.matching(NSPredicate(format: "label CONTAINS 'Photo'")).firstMatch
        _ = picker.waitForExistence(timeout: 10)
        sleep(2)
        let a0 = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a0.name = "30-photos-picker"; a0.lifetime = .keepAlways; add(a0)
        let images = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
        XCTAssertTrue(images.firstMatch.waitForExistence(timeout: 10), "picker photos not found")
        let n = min(3, images.count)
        for i in 0..<n { images.element(boundBy: i).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let a3 = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a3.name = "30a-picked"; a3.lifetime = .keepAlways; add(a3)
        let confirm = app.buttons.matching(NSPredicate(format: "label IN {'Add', 'Done', 'Confirm'} OR identifier IN {'Add', 'Done'}")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "picker confirm button")
        confirm.tap()
        XCTAssertTrue(app.buttons["scan.start"].waitForExistence(timeout: 60), "copied photos should open the scan preview")
        let a2 = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a2.name = "31a-scan-preview"; a2.lifetime = .keepAlways; add(a2)
        app.buttons["scan.start"].tap()
        XCTAssertTrue(app.staticTexts["Scan complete"].waitForExistence(timeout: 120))
        let a1 = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a1.name = "31-photos-imported"; a1.lifetime = .keepAlways; add(a1)
    }
}
