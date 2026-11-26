import AppKit
import XCTest
@testable import RimeAIInputMethod

/// 上屏前的「同一输入框」证据：记录位置上的文字对得上才允许自动上屏；
/// 滚动、重排、在同一输入框内移动光标都不算换框。
final class VoiceTargetFingerprintTests: XCTestCase {
    private let document = "您好，这是一段已有的正文，听写会接在后面。"

    /// 模拟宿主的 IMK 回读：按 UTF-16 范围取文字，越界返回 nil。
    private func reader(_ text: String) -> (NSRange) -> String? {
        let utf16 = Array(text.utf16)
        return { range in
            guard NSMaxRange(range) <= utf16.count else {
                return nil
            }
            return String(decoding: utf16[range.location ..< NSMaxRange(range)], as: UTF16.self)
        }
    }

    func testTextBeforeTheCaretIsRecordedAndMustReadBackUnchanged() {
        let fingerprint = VoiceTargetFingerprint.capture(
            caretLocation: 12,
            selectionLength: 0,
            read: reader(document)
        )

        XCTAssertTrue(fingerprint.hasTextEvidence)
        XCTAssertEqual(fingerprint.probes.count, 1)
        XCTAssertEqual(fingerprint.probes.first?.offset, 0)
        XCTAssertEqual(fingerprint.probes.first?.text, "您好，这是一段已有的正文")
        // 同一输入框：被记录位置上的文字没有变。
        XCTAssertTrue(fingerprint.matches(reader(document)))
        // 同一客户端里的另一个输入框：位置上的文字不同，或者根本没有那么长。
        XCTAssertFalse(fingerprint.matches(reader("完全不同的内容，但长度足够读到")))
        XCTAssertFalse(fingerprint.matches(reader("短")))
        XCTAssertFalse(fingerprint.matches { _ in nil })
    }

    func testOnlyTheNearestSixteenUnitsBeforeTheCaretAreUsed() {
        let fingerprint = VoiceTargetFingerprint.capture(
            caretLocation: document.utf16.count,
            selectionLength: 0,
            read: reader(document)
        )

        XCTAssertEqual(fingerprint.probes.first?.length, VoiceTargetFingerprint.probeLength)
        XCTAssertEqual(fingerprint.probes.first?.offset, document.utf16.count - 16)
        // 光标在同一输入框内移动，不影响原位置上的文字。
        XCTAssertTrue(fingerprint.matches(reader(document)))
    }

    func testCaretAtDocumentStartFallsBackToTheTextAfterTheCaret() {
        let fingerprint = VoiceTargetFingerprint.capture(
            caretLocation: 0,
            selectionLength: 0,
            read: reader(document)
        )

        XCTAssertTrue(fingerprint.hasTextEvidence)
        XCTAssertEqual(fingerprint.probes.first?.offset, 0)
        XCTAssertEqual(fingerprint.probes.first?.text, String(document.prefix(16)))
        XCTAssertTrue(fingerprint.matches(reader(document)))
        // 另一个同样以别的内容开头的输入框。
        XCTAssertFalse(fingerprint.matches(reader("搜索……" + document)))
    }

    func testShortDocumentTriesNarrowerRangesWhenTheHostRejectsTheWideOne() {
        let fingerprint = VoiceTargetFingerprint.capture(
            caretLocation: 0,
            selectionLength: 0,
            read: reader("ab")
        )

        XCTAssertTrue(fingerprint.hasTextEvidence)
        XCTAssertEqual(fingerprint.probes.first?.length, 2)
        XCTAssertEqual(fingerprint.probes.first?.text, "ab")
    }

    func testEmptyDocumentLeavesNoTextEvidence() {
        let fingerprint = VoiceTargetFingerprint.capture(
            caretLocation: 0,
            selectionLength: 0,
            read: reader("")
        )

        XCTAssertFalse(fingerprint.hasTextEvidence)
        // 没有文字证据时 `matches` 恒为假：调用方必须改用光标矩形判定。
        XCTAssertFalse(fingerprint.matches(reader("")))
    }

    func testCaretRectFallbackToleratesJitterButNotAnotherField() {
        let anchor = NSRect(x: 100, y: 200, width: 1, height: 18)

        XCTAssertTrue(
            VoiceCaretRectMatch.isSameCaretRect(
                anchor,
                NSRect(x: 105, y: 196, width: 1, height: 18)
            )
        )
        XCTAssertFalse(
            VoiceCaretRectMatch.isSameCaretRect(
                anchor,
                NSRect(x: 100, y: 260, width: 1, height: 18)
            )
        )
        XCTAssertFalse(
            VoiceCaretRectMatch.isSameCaretRect(
                anchor,
                NSRect(x: 100, y: 200, width: 1, height: 40)
            )
        )
    }
}
