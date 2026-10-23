import AppKit
import XCTest
@testable import RimeAIInputMethod

@MainActor
final class CandidatePanelContinuationTests: XCTestCase {
    private func semanticButton(in view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton,
               button.title.hasPrefix("✦ 续写")
            {
                return button
            }
            if let found = semanticButton(in: subview) {
                return found
            }
        }
        return nil
    }

    /// 续写 chip 所在面板：以按钮文案定位，不依赖窗口层级过滤
    /// （测试宿主里可能同时存在其他 NSPanel）。
    private func continuationPanel() -> NSPanel? {
        NSApp.windows.first { window in
            window.contentView.flatMap { semanticButton(in: $0) } != nil
        } as? NSPanel
    }

    func testContinuationPresentationIsSelectableAndLabeledContinuation() {
        let presentation = SemanticCandidatePresentation.continuation(
            candidate: "疑是地上霜"
        )

        XCTAssertTrue(presentation.isSelectable)
        XCTAssertTrue(presentation.isContinuation)
        XCTAssertEqual(presentation.title, "✦ 续写：疑是地上霜")
    }

    func testShowContinuationDisplaysSingleChipAndFiresSelection() throws {
        let panel = CandidatePanelController()
        var selections = 0

        panel.showContinuation(
            "疑是地上霜",
            anchor: NSRect(x: 100, y: 400, width: 0, height: 20),
            onSelection: { selections += 1 }
        )

        let window = try XCTUnwrap(
            continuationPanel(),
            "NSApp.windows=\(NSApp.windows.map { "\(type(of: $0)) level=\($0.level.rawValue) visible=\($0.isVisible)" }) isShowingContinuation=\(panel.isShowingContinuation)"
        )
        XCTAssertTrue(window.isVisible)
        let button = try XCTUnwrap(
            window.contentView.flatMap { semanticButton(in: $0) }
        )
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.title, "✦ 续写：疑是地上霜")
        XCTAssertTrue(panel.isShowingContinuation)

        button.performClick(nil)
        XCTAssertEqual(selections, 1)

        panel.hide()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(panel.isShowingContinuation)
    }

    func testShowContinuationWithoutCompositionDoesNotAffectRefreshPath() {
        let panel = CandidatePanelController()
        // 既有刷新路径的等价行为：空 Content（无候选、无语义建议）调用
        // show 必须隐藏面板而不是展示。
        panel.update(
            content: CandidatePanelController.Content(
                visibleCandidates: [],
                primaryCandidate: nil,
                pageLabel: nil,
                semanticPresentation: .idle,
                suggestionSource: .rimeMain,
                contextCharacterCount: 0,
                cloudInFlight: false,
                neuralLateApplied: false
            ),
            onMainSelection: { _ in },
            onSemanticSelection: {}
        )
        panel.show(anchorRect: NSRect(x: 100, y: 400, width: 0, height: 20))

        XCTAssertNil(continuationPanel())
        XCTAssertFalse(panel.isShowingContinuation)
    }
}
