import UIKit
import XCTest

@MainActor
final class KeyboardLayoutTests: XCTestCase {
    func testPartialCandidateSelectionRetainsUnconfirmedComposition() throws {
        let selection = try XCTUnwrap(RimeKeyboardSelection(
            outcome: .partial,
            originalComposition: "mingtiantianqi",
            committedText: "明天",
            remainingComposition: "tianqi"
        ))

        XCTAssertEqual(selection.committedText, "明天")
        XCTAssertEqual(selection.historyInput, "mingtian")
        XCTAssertEqual(selection.remainingComposition, "tianqi")
    }

    func testWholeCandidateSelectionFinishesComposition() throws {
        let selection = try XCTUnwrap(RimeKeyboardSelection(
            outcome: .complete,
            originalComposition: "nihao",
            committedText: "你好",
            remainingComposition: ""
        ))

        XCTAssertEqual(selection.committedText, "你好")
        XCTAssertNil(selection.remainingComposition)
    }

    func testCandidateSelectionRejectsTailThatIsNotOriginalSuffix() {
        XCTAssertNil(RimeKeyboardSelection(
            outcome: .partial,
            originalComposition: "mingtiantianqi",
            committedText: "明天",
            remainingComposition: "qianqi"
        ))
    }

    func testSelectionOutcomeMustMatchWhetherTailRemains() {
        XCTAssertNil(RimeKeyboardSelection(
            outcome: .partial,
            originalComposition: "nihao",
            committedText: "你好",
            remainingComposition: ""
        ))
        XCTAssertNil(RimeKeyboardSelection(
            outcome: .complete,
            originalComposition: "mingtiantianqi",
            committedText: "明天",
            remainingComposition: "tianqi"
        ))
    }

    func testSelectionUsesSharedRawInputValidation() {
        XCTAssertNil(RimeKeyboardSelection(
            outcome: .partial,
            originalComposition: "Mingtiantianqi",
            committedText: "明天",
            remainingComposition: "tianqi"
        ))
    }

    func testPendingFirstSelectionUsesOnlyMatchingCandidateGeneration() throws {
        let pending = try XCTUnwrap(RimeKeyboardPendingFirstSelection(
            composition: "mingtiantianqi",
            requestRevision: 7
        ))
        let current = [
            RimeKeyboardCandidate(text: "明天", comment: nil, index: 0),
            RimeKeyboardCandidate(text: "明天甜汽", comment: nil, index: 1),
        ]

        XCTAssertEqual(
            pending.candidate(
                for: "mingtiantianqi",
                requestRevision: 7,
                from: current
            )?.text,
            "明天"
        )
        XCTAssertNil(pending.candidate(
            for: "mingtiantianq",
            requestRevision: 8,
            from: current
        ))
    }

    func testSentenceSuggestionWithoutCommitTargetIsDisabled() {
        let controller = KeyboardViewController()
        let button = controller.makeSemanticButton(
            evaluation: LocalSemanticEvaluation(
                decision: .sentenceSuggestion,
                candidate: "请执行这条命令",
                confidence: 0.93
            ),
            candidates: [
                RimeKeyboardCandidate(text: "明令", comment: nil, index: 0),
                RimeKeyboardCandidate(text: "命令", comment: nil, index: 1),
            ]
        )

        XCTAssertFalse(button.isEnabled)
    }

    func testKeyboardControlsFitIPhoneSEWidth() {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 375, height: 300)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let buttons = descendants(of: controller.view, type: UIButton.self)
        let letterButtons = "qwertyuiopasdfghjklzxcvbnm".compactMap { letter in
            buttons.first {
                $0.accessibilityIdentifier == "rime-key-letter-\(letter)"
            }
        }
        XCTAssertEqual(letterButtons.count, 26)
        assertContained(letterButtons, in: controller.view)

        let firstRow = "qwertyuiop".compactMap { letter in
            letterButtons.first { $0.accessibilityLabel == String(letter) }
        }
        assertNoHorizontalOverlap(firstRow, in: controller.view)
        for button in firstRow {
            XCTAssertGreaterThanOrEqual(
                button.frame.width,
                28,
                "Letter key is too narrow to render: \(button.frame)"
            )
        }

        let functionButtons = [
            "rime-key-next-keyboard",
            "rime-key-delete",
            "rime-key-space",
            "rime-key-return",
        ].compactMap { identifier in
            buttons.first { $0.accessibilityIdentifier == identifier }
        }
        XCTAssertEqual(functionButtons.count, 4)
        assertContained(functionButtons, in: controller.view)
        assertNoHorizontalOverlap(functionButtons, in: controller.view)
        for button in functionButtons {
            XCTAssertGreaterThanOrEqual(
                button.frame.width,
                44,
                "Function key is too narrow to operate: \(button.frame)"
            )
            button.layoutIfNeeded()
            if let titleLabel = button.titleLabel,
               !titleLabel.bounds.isEmpty
            {
                XCTAssertTrue(
                    button.bounds.insetBy(dx: -0.5, dy: -0.5)
                        .contains(titleLabel.frame),
                    "Function-key title is clipped: \(titleLabel.frame) "
                        + "inside \(button.bounds)"
                )
            }
            if let imageView = button.imageView,
               !imageView.bounds.isEmpty
            {
                XCTAssertTrue(
                    button.bounds.insetBy(dx: -0.5, dy: -0.5)
                        .contains(imageView.frame),
                    "Function-key image is clipped: \(imageView.frame) "
                        + "inside \(button.bounds)"
                )
            }
        }
    }

    private func descendants<T: UIView>(
        of view: UIView,
        type: T.Type
    ) -> [T] {
        view.subviews.flatMap { child -> [T] in
            let current = child as? T
            return (current.map { [$0] } ?? [])
                + descendants(of: child, type: type)
        }
    }

    private func assertContained(
        _ buttons: [UIButton],
        in container: UIView
    ) {
        for button in buttons {
            let frame = button.convert(button.bounds, to: container)
            XCTAssertTrue(
                container.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                "Control escaped the keyboard: \(frame)"
            )
        }
    }

    private func assertNoHorizontalOverlap(
        _ buttons: [UIButton],
        in container: UIView
    ) {
        let frames = buttons.map { $0.convert($0.bounds, to: container) }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(
                left.maxX,
                right.minX,
                "Keyboard controls overlap: \(left), \(right)"
            )
        }
    }
}
