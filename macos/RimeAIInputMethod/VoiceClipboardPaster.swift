import AppKit
import ApplicationServices
import Carbon
import Foundation

/// 剪贴板完整快照：逐个 `NSPasteboardItem` 记录全部类型及其原始数据
/// （图片、RTF、文件 URL 等一并保留），恢复时按条目原样写回。
/// 只保存 `.string` 会把用户剪贴板里的图片与富文本永久清空。
struct VoicePasteboardSnapshot: Equatable {
    struct Item: Equatable {
        var payloads: [NSPasteboard.PasteboardType: Data]

        var isEmpty: Bool {
            payloads.isEmpty
        }
    }

    let items: [Item]

    /// 读取每个条目的全部类型；宿主此刻拿不到数据的类型会被跳过。
    static func capture(from pasteboard: NSPasteboard = .general) -> VoicePasteboardSnapshot {
        var items: [Item] = []
        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            var payloads: [NSPasteboard.PasteboardType: Data] = [:]
            for type in Set(pasteboardItem.types) {
                if let data = pasteboardItem.data(forType: type) {
                    payloads[type] = data
                }
            }
            if !payloads.isEmpty {
                items.append(Item(payloads: payloads))
            }
        }
        return VoicePasteboardSnapshot(items: items)
    }

    var isEmpty: Bool {
        items.allSatisfy(\.isEmpty)
    }

    /// 清空并原样写回全部条目。
    func restore(into pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { item -> NSPasteboardItem in
            let target = NSPasteboardItem()
            for (type, data) in item.payloads {
                target.setData(data, forType: type)
            }
            return target
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}

/// 自动粘贴回退器：当宿主应用无法通过 IMK `insertText` 真正插入（例如
/// 部分 Electron/网页控件）时，把文本写入剪贴板并在已授予辅助功能权限时
/// 合成 ⌘V 粘贴，随后恢复原剪贴板内容；若无辅助功能权限，则保留在
/// 剪贴板并提示用户按 ⌘V。绝不在 Secure Input 下运行。
@MainActor
enum VoiceClipboardPaster {
    enum Outcome: Equatable {
        case pastedViaCommandV
        case copiedToClipboardOnly
        case blocked
    }

    /// 目标应用读取 ⌘V 剪贴板内容需要时间；260ms 在慢速宿主上会在粘贴
    /// 完成前就把剪贴板换回去，导致上屏的是旧内容。
    static let restoreDelayMilliseconds = 1_500

    static func paste(_ text: String) -> Outcome {
        guard !text.isEmpty, !IsSecureEventInputEnabled() else {
            return .blocked
        }
        let pasteboard = NSPasteboard.general
        let snapshot = VoicePasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            // 写入失败：立即还原原内容，绝不留一个空剪贴板。
            snapshot.restore(into: pasteboard)
            return .blocked
        }
        let changeCountAfterCopy = pasteboard.changeCount

        guard AXIsProcessTrusted() else {
            return .copiedToClipboardOnly
        }
        guard synthesizeCommandV() else {
            return .copiedToClipboardOnly
        }

        // 目标应用完成 ⌘V 读取后，若剪贴板未被他人改动则恢复原内容。
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(restoreDelayMilliseconds)
        ) {
            let currentBoard = NSPasteboard.general
            guard currentBoard.changeCount == changeCountAfterCopy else {
                // 用户或其他应用在窗口期内改动了剪贴板：放弃恢复，绝不覆盖新内容。
                return
            }
            snapshot.restore(into: currentBoard)
        }
        return .pastedViaCommandV
    }

    private static func synthesizeCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(9), // V
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(9), // V
                  keyDown: false
              )
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
