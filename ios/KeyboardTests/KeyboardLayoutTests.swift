import UIKit
import XCTest

@MainActor
final class KeyboardLayoutTests: XCTestCase {
    func testKeyboardControlsFitIPhoneSEWidth() {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 375, height: 300)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let buttons = descendants(of: controller.view, type: UIButton.self)
        let letterButtons = "qwertyuiopasdfghjklzxcvbnm".compactMap { letter in
            buttons.first { $0.accessibilityLabel == String(letter) }
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

        let functionButtons = ["下一个键盘", "删除", "空格", "换行"].compactMap {
            label in
            buttons.first { $0.accessibilityLabel == label }
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
