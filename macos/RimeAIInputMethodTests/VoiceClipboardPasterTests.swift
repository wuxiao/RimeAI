import AppKit
import XCTest
@testable import RimeAIInputMethod

/// 自动粘贴回退：剪贴板全类型快照/恢复，以及回退结果到用户可见原因的映射。
/// 绝不在测试里调用 `VoiceClipboardPaster.paste`（它会合成真实 ⌘V）。
@MainActor
final class VoiceClipboardPasterTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []

    override func tearDown() {
        for pasteboard in pasteboards {
            pasteboard.releaseGlobally()
        }
        pasteboards = []
        super.tearDown()
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "fun.wwcn.inputmethod.RimeAI.tests.paste.\(UUID().uuidString)"
        ))
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private let customType = NSPasteboard.PasteboardType(
        "fun.wwcn.inputmethod.RimeAI.tests.custom"
    )
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
    private let rtfBytes = Data("{\\rtf1 Hi}".utf8)

    // MARK: - Full-Type Snapshot

    func testSnapshotCapturesEveryPasteboardItemType() {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setString("你好", forType: .string)
        item.setData(Data([1, 2, 3]), forType: customType)
        item.setData(pngBytes, forType: .png)
        item.setData(rtfBytes, forType: .rtf)
        pasteboard.writeObjects([item])

        let snapshot = VoicePasteboardSnapshot.capture(from: pasteboard)

        XCTAssertEqual(snapshot.items.count, 1)
        let payloads = snapshot.items[0].payloads
        XCTAssertEqual(payloads[.string], Data("你好".utf8))
        XCTAssertEqual(payloads[customType], Data([1, 2, 3]))
        XCTAssertEqual(payloads[.png], pngBytes, "只快照 .string 会永久丢失用户剪贴板里的图片")
        XCTAssertEqual(payloads[.rtf], rtfBytes)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testRestoreWritesBackEveryItemAndType() {
        let pasteboard = makePasteboard()
        let textItem = NSPasteboardItem()
        textItem.setString("第一项", forType: .string)
        let richItem = NSPasteboardItem()
        richItem.setData(pngBytes, forType: .png)
        richItem.setData(rtfBytes, forType: .rtf)
        pasteboard.writeObjects([textItem, richItem])
        let snapshot = VoicePasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        XCTAssertNil(pasteboard.string(forType: .string))
        snapshot.restore(into: pasteboard)

        let restored = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].data(forType: .string), Data("第一项".utf8))
        XCTAssertEqual(restored[1].data(forType: .png), pngBytes)
        XCTAssertEqual(restored[1].data(forType: .rtf), rtfBytes)
        // 按条目断言：AppKit 读取整个面板的 .string 时会把 RTF 条目自动转换成纯文本并拼接。
        XCTAssertEqual(restored[0].string(forType: .string), "第一项")
    }

    func testEmptySnapshotRestoresAnEmptyPasteboard() {
        let pasteboard = makePasteboard()
        let snapshot = VoicePasteboardSnapshot.capture(from: pasteboard)
        XCTAssertTrue(snapshot.isEmpty)

        pasteboard.setString("临时内容", forType: .string)
        snapshot.restore(into: pasteboard)

        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)
    }

    func testRestoreBumpsChangeCountSoGuardsCanDetectReplacement() {
        let pasteboard = makePasteboard()
        pasteboard.setString("A", forType: .string)
        let snapshot = VoicePasteboardSnapshot.capture(from: pasteboard)
        pasteboard.setString("B", forType: .string)
        let countBefore = pasteboard.changeCount

        snapshot.restore(into: pasteboard)

        XCTAssertGreaterThan(pasteboard.changeCount, countBefore)
        XCTAssertEqual(pasteboard.string(forType: .string), "A")
    }

    func testRestoreDelayIsLongEnoughForSlowHosts() {
        // 260ms 会在慢速宿主完成 ⌘V 读取前就把剪贴板换回去，导致上屏旧内容。
        XCTAssertGreaterThanOrEqual(VoiceClipboardPaster.restoreDelayMilliseconds, 1_000)
    }

    // MARK: - Fallback Outcome → Accurate Reason

    func testFallbackOutcomeMapsToAccuratePersistentCopyReason() {
        XCTAssertEqual(
            VoiceClipboardFallbackPolicy.reason(
                pasteOutcome: .blocked,
                hadEditableTarget: true,
                focusSwitched: false,
                isAccessibilityTrusted: true
            ),
            .secureInputBlocked
        )

        let needsAccessibility = VoiceClipboardFallbackPolicy.reason(
            pasteOutcome: .copiedToClipboardOnly,
            hadEditableTarget: true,
            focusSwitched: false,
            isAccessibilityTrusted: false
        )
        XCTAssertEqual(needsAccessibility, .accessibilityNeeded)
        XCTAssertEqual(
            needsAccessibility.hint,
            "已复制到剪贴板，请按 ⌘V 粘贴（开启辅助功能权限可自动粘贴）"
        )
        XCTAssertTrue(needsAccessibility.offersAccessibilityAuthorization)

        let commandVFailed = VoiceClipboardFallbackPolicy.reason(
            pasteOutcome: .copiedToClipboardOnly,
            hadEditableTarget: true,
            focusSwitched: false,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(commandVFailed, .commandVUnavailable)
        XCTAssertEqual(commandVFailed.hint, "已复制到剪贴板，请按 ⌘V 粘贴")
        XCTAssertFalse(commandVFailed.offersAccessibilityAuthorization)
    }

    func testMissingPasteOutcomeDistinguishesNoCursorFromFocusSwitch() {
        let noCursor = VoiceClipboardFallbackPolicy.reason(
            pasteOutcome: nil,
            hadEditableTarget: false,
            focusSwitched: false,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(noCursor, .noCursor)
        XCTAssertEqual(noCursor.hint, "未检测到光标，内容已保留在浮窗")

        let switched = VoiceClipboardFallbackPolicy.reason(
            pasteOutcome: nil,
            hadEditableTarget: true,
            focusSwitched: true,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(switched, .focusSwitched)
        XCTAssertEqual(switched.hint, "焦点已切换，内容已保留在浮窗")

        // 光标仍在原处、宿主却拒绝写入（且自动粘贴关闭未尝试 ⌘V）：
        // 不得谎称“焦点已切换”。
        let refused = VoiceClipboardFallbackPolicy.reason(
            pasteOutcome: nil,
            hadEditableTarget: true,
            focusSwitched: false,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(refused, .hostRefusedCommit)
        XCTAssertEqual(refused.hint, "当前应用无法直接写入，内容已保留在浮窗")
        XCTAssertFalse(refused.offersAccessibilityAuthorization)
    }

    // MARK: - Post-Commit Readback

    func testReadbackDetectsInsertThatNeverHappened() {
        XCTAssertEqual(
            VoiceCommitReadback.verify(
                committedText: "你好世界",
                baseline: "旧内容",
                readback: "旧内容"
            ),
            .missing,
            "插入区段原封不动即代表 insertText 什么也没写"
        )
        XCTAssertEqual(
            VoiceCommitReadback.verify(committedText: "你好世界", baseline: nil, readback: ""),
            .missing
        )
    }

    func testReadbackMissingIsOverriddenWhenTheCaretAdvanced() {
        // 某些宿主的回读恒定返回与插入位置无关的内容：仅凭回读会误判为缺失，
        // 但光标确实前进了一个文本长度 → 判定已插入，不触发 ⌘V（否则重复上屏）。
        XCTAssertEqual(
            VoiceCommitReadback.verify(
                committedText: "你好世界",
                baseline: "恒定内容",
                readback: "恒定内容",
                caretBefore: 10,
                caretAfter: 10 + "你好世界".utf16.count
            ),
            .inserted
        )
        // 光标没有前进：维持回读的“缺失”结论。
        XCTAssertEqual(
            VoiceCommitReadback.verify(
                committedText: "你好世界",
                baseline: "恒定内容",
                readback: "恒定内容",
                caretBefore: 10,
                caretAfter: 10
            ),
            .missing
        )
        // 光标信息不可用（NSNotFound）时退回仅凭回读判断。
        XCTAssertEqual(
            VoiceCommitReadback.verify(
                committedText: "你好世界",
                baseline: "",
                readback: "",
                caretBefore: nil,
                caretAfter: nil
            ),
            .missing
        )
        // 光标佐证只会“升级”，不会把已插入降级为缺失。
        XCTAssertEqual(
            VoiceCommitReadback.verify(
                committedText: "你好世界",
                baseline: "",
                readback: "你好世界",
                caretBefore: 10,
                caretAfter: 10
            ),
            .inserted
        )
    }

    func testReadbackTrustsHostWhenUnavailableOrRewritten() {
        XCTAssertEqual(
            VoiceCommitReadback.verify(committedText: "你好", baseline: nil, readback: nil),
            .unknown,
            "宿主不支持回读时不得误判为缺失，否则 ⌘V 回退会造成重复上屏"
        )
        XCTAssertEqual(
            VoiceCommitReadback.verify(committedText: "你好", baseline: "", readback: "你好"),
            .inserted
        )
        XCTAssertEqual(
            VoiceCommitReadback.verify(committedText: "你好", baseline: "", readback: " 你好\n"),
            .inserted
        )
        // 宿主做了智能引号等改写：无法断定缺失，保守视为已插入。
        XCTAssertEqual(
            VoiceCommitReadback.verify(committedText: "\"hi\"", baseline: "", readback: "“hi”"),
            .inserted
        )
    }
}
