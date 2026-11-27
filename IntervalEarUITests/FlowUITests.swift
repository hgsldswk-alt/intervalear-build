import XCTest

final class FlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private let wrongChoice = ["answer.2", "answer.4", "answer.5", "answer.7"]

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ args: [String] = ["-reset"], language: String = "en", environment: [String: String] = [:]) {
        let locales = ["en": "en_US", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW", "ja": "ja_JP"]
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", locales[language]!] + args
        app.launchEnvironment = environment
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tap(_ id: String) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 7), id)
        for _ in 0..<7 { if button.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(button.isHittable, id)
        button.tap()
    }

    private func waitForAnswer(_ id: String) {
        let button = app.buttons[id].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
    }

    private func answer(_ id: String = "answer.2") {
        waitForAnswer(id)
        tap(id)
        XCTAssertTrue(element("feedback.answer").waitForExistence(timeout: 7))
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFiveQuestionsAndPersistedFeedback() {
        launch()
        XCTAssertTrue(element("practice.number").waitForExistence(timeout: 7))
        XCTAssertFalse(app.buttons[wrongChoice[0]].isEnabled)
        tap("practice.play")
        answer()
        let answerLabel = element("feedback.answer").label
        app.terminate()
        launch([])
        XCTAssertTrue(element("feedback.answer").waitForExistence(timeout: 7))
        XCTAssertEqual(element("feedback.answer").label, answerLabel)
        for _ in 1..<5 { tap("practice.next"); answer() }
        XCTAssertTrue(element("summary.title").exists)
        tap("practice.next")
        XCTAssertTrue(element("practice.number").waitForExistence(timeout: 7))
        XCTAssertEqual(element("practice.number").label, "Question 1 of 5")
    }

    func testAudioFailureKeepsOriginalQuestionLocked() {
        launch(["-reset", "-audio-failure"])
        tap("practice.play")
        XCTAssertTrue(element("practice.message").waitForExistence(timeout: 7))
        XCTAssertFalse(app.buttons[wrongChoice[0]].isEnabled)
        XCTAssertEqual(element("practice.number").label, "Question 1 of 5")
        tap("practice.play")
        XCTAssertTrue(element("practice.message").waitForExistence(timeout: 7))
    }

    func testBackgroundDoesNotUnlockOrReplayUnfinishedAudio() {
        launch(["-reset", "-slow-audio"])
        tap("practice.play")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element("practice.number").waitForExistence(timeout: 7))
        XCTAssertFalse(app.buttons[wrongChoice[0]].isEnabled)
        XCTAssertEqual(app.buttons["practice.play"].label, "Play notes")
        tap("practice.play"); answer()
    }

    func testExpiredCanReviewAndImportButCannotCreateSet() {
        let code = Data("[{\"direction\":\"ascending\",\"first\":60,\"second\":62,\"choices\":[2,4,5,7]}]".utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        launch(["-reset", "-expired", "-fixture"], environment: ["INTERVALEAR_TEST_SET": "\nIE1:\(code)\n"])
        tap("practice.review")
        XCTAssertTrue(element("practice.number").label.hasPrefix("Review"))
        tap("practice.back")
        tap("practice.importSet")
        XCTAssertFalse(app.buttons["import.save"].exists)
        tap("import.paste")
        tap("import.save")
        XCTAssertTrue(element("import.message").waitForExistence(timeout: 7))
        app.terminate()
        launch(["-expired"])
        tap("practice.settings")
        tap("settings.sets")
        XCTAssertTrue(app.buttons["sets.entry"].waitForExistence(timeout: 7))
        tap("sets.new")
        XCTAssertTrue(app.buttons["purchase.restore"].waitForExistence(timeout: 7))
    }

    func testNewQuestionSharesWithoutPlaybackOrAnswer() {
        launch(["-reset", "-fixture"])
        tap("practice.challenge")
        XCTAssertFalse(element("feedback.answer").exists)
        tap("share.combo")
        XCTAssertTrue(element("share.requested").waitForExistence(timeout: 10))
        for _ in 0..<5 where !app.buttons["screen.back"].isHittable { app.swipeDown() }
        tap("screen.back")
        XCTAssertEqual(element("practice.number").label, "Question 1 of 5")
        XCTAssertFalse(app.buttons["answer.2"].isEnabled)
    }

    func testHomeFileImportShowsPreviewImmediately() {
        let bytes = Data(#"[{"direction":"ascending","first":60,"second":62,"choices":[2,4,5,7]}]"#.utf8)
        let code = bytes.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        launch(["-reset"], environment: ["INTERVALEAR_TEST_SET_FILE": "IE1:" + code])
        tap("practice.importSetFile")
        tap("import.save")
        let message = element("import.message")
        XCTAssertTrue(message.waitForExistence(timeout: 7))
        XCTAssertEqual(message.label, "Set added. Nothing was played or overwritten.")
    }

    func testFreeAndPaidDownloadSettingsHidePurchases() {
        for mode in ["-free-mode", "-paid-download", "-paid-mode"] {
            launch(["-reset", mode])
            tap("practice.settings")
            XCTAssertTrue(app.buttons["settings.export"].waitForExistence(timeout: 7))
            XCTAssertEqual(app.buttons["settings.purchase"].exists, mode == "-paid-mode")
            XCTAssertFalse(app.buttons["purchase.restore"].exists)
            app.terminate()
        }
    }

    func testChallengeExportsWithoutSystemSheet() {
        launch(["-reset", "-fixture"])
        tap("practice.play"); answer()
        tap("feedback.challenge")
        tap("share.combo")
        for _ in 0..<5 { if element("share.requested").exists { break }; app.swipeUp() }
        XCTAssertTrue(element("share.requested").waitForExistence(timeout: 10))
    }

    func testStoreEnglish() { store(language: "en") }
    func testStoreSimplifiedChinese() { store(language: "zh-Hans") }
    func testStoreTraditionalChinese() { store(language: "zh-Hant") }
    func testStoreJapanese() { store(language: "ja") }

    private func store(language: String) {
        launch(["-reset", "-fixture"], language: language)
        XCTAssertTrue(app.buttons["practice.play"].waitForExistence(timeout: 7))
        shot("store-\(language)-01-practice")
        tap("practice.play"); answer("answer.2")
        shot("store-\(language)-02-feedback")
        tap("practice.back"); tap("practice.review")
        XCTAssertTrue(element("practice.number").waitForExistence(timeout: 7))
        waitForAnswer("answer.2")
        shot("store-\(language)-03-review")
        tap("practice.back")
        if !app.buttons["practice.progress"].waitForExistence(timeout: 2), app.buttons["practice.back"].exists { tap("practice.back") }
        tap("practice.progress")
        XCTAssertTrue(element("progress.first").waitForExistence(timeout: 7))
        shot("store-\(language)-04-progress")
        tap("screen.back"); tap("practice.feedback"); tap("feedback.challenge")
        XCTAssertTrue(app.buttons["share.combo"].waitForExistence(timeout: 7))
        shot("store-\(language)-05-challenge")
    }

    func testPaidScreenshot() {
        launch(["-reset", "-paywall"], language: "zh-Hans")
        XCTAssertTrue(element("paywall.terms").waitForExistence(timeout: 7))
        XCTAssertTrue(app.buttons["purchase.restore"].exists)
        shot("paid-01-paywall")
    }
}
