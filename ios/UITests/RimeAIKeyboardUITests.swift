import XCTest

@MainActor
final class RimeAIKeyboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCustomKeyboardCommitsNiHaoCandidate() throws {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields["keyboard-test-field"]
        for _ in 0 ..< 4 where !field.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()

        dismissKeyboardTutorialIfPresent(in: app, timeout: 1)

        let rimeStatus = app.staticTexts["RimeAI 状态"]
        let switcherNames = [
            "Emoji",
            "Next keyboard",
            "下一个键盘",
            "下一项键盘",
            "ABC",
        ]
        for _ in 0 ..< 6 where !rimeStatus.waitForExistence(timeout: 1) {
            var switched = false
            for name in switcherNames {
                let switcher = app.buttons[name].firstMatch
                if switcher.exists, switcher.isHittable {
                    switcher.tap()
                    dismissKeyboardTutorialIfPresent(in: app, timeout: 2)
                    switched = true
                    break
                }
            }
            if !switched, app.otherElements["inputView"].exists {
                let keyboardSwitcher = app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0, dy: 0)
                ).withOffset(
                    CGVector(
                        dx: app.frame.width * 0.38,
                        dy: app.frame.height - 29
                    )
                )
                keyboardSwitcher.tap()
                dismissKeyboardTutorialIfPresent(in: app, timeout: 2)
                switched = true
            }
            XCTAssertTrue(
                switched,
                "Cannot find a visible keyboard switcher. "
                    + app.debugDescription
            )
        }
        XCTAssertTrue(
            rimeStatus.waitForExistence(timeout: 2),
            "RimeAI keyboard did not become active"
        )
        assertKeyboardLayout(in: app)
        let layoutScreenshot = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        layoutScreenshot.name = "RimeAI keyboard layout - iPhone SE"
        layoutScreenshot.lifetime = .keepAlways
        add(layoutScreenshot)

        for letter in ["n", "i", "h", "a", "o"] {
            let key = app.buttons[letter]
            XCTAssertTrue(key.waitForExistence(timeout: 2))
            key.tap()
        }

        let candidate = app.buttons["你好"]
        XCTAssertTrue(
            candidate.waitForExistence(timeout: 5),
            "Expected 你好 candidate after typing nihao"
        )
        candidate.tap()

        let value = field.value as? String
        XCTAssertEqual(value, "你好")
    }

    private func dismissKeyboardTutorialIfPresent(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: timeout) {
            continueButton.tap()
        }
    }

    private func assertKeyboardLayout(in app: XCUIApplication) {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { row in
            row.map { app.buttons[String($0)] }
        }
        for key in rows.flatMap({ $0 }) {
            XCTAssertTrue(key.exists)
            XCTAssertTrue(
                app.frame.insetBy(dx: -1, dy: -1).contains(key.frame),
                "Letter key escaped the screen: \(key.debugDescription)"
            )
            XCTAssertGreaterThanOrEqual(
                key.frame.width,
                28,
                "Letter key is too narrow to render its title: \(key.frame)"
            )
        }
        for row in rows {
            assertNoHorizontalOverlap(row)
        }

        let functionKeys = ["下一个键盘", "删除", "空格", "换行"].map {
            app.buttons[$0]
        }
        for key in functionKeys {
            XCTAssertTrue(key.exists)
            XCTAssertTrue(key.isHittable)
            XCTAssertTrue(
                app.frame.insetBy(dx: -1, dy: -1).contains(key.frame),
                "Function key escaped the screen: \(key.debugDescription)"
            )
            XCTAssertGreaterThanOrEqual(
                key.frame.width,
                44,
                "Function key is too narrow to operate: \(key.frame)"
            )
        }
        assertNoHorizontalOverlap(functionKeys)
        XCTAssertGreaterThan(
            functionKeys[2].frame.width,
            functionKeys[0].frame.width * 2,
            "Space key should remain wider than the utility keys"
        )
    }

    private func assertNoHorizontalOverlap(_ elements: [XCUIElement]) {
        for (left, right) in zip(elements, elements.dropFirst()) {
            XCTAssertLessThanOrEqual(
                left.frame.maxX,
                right.frame.minX,
                "Keyboard controls overlap: "
                    + left.debugDescription
                    + right.debugDescription
            )
        }
    }
}
