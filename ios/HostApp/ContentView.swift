import SwiftUI
import UIKit

struct ContentView: View {
    @State private var sampleText = ""
    @FocusState private var isTestingKeyboard: Bool

    var body: some View {
        NavigationStack {
            List {
                introduction
                readiness
                setupInstructions
                keyboardTest
                privacyBoundary
            }
            .navigationTitle("RimeAI")
        }
    }

    private var introduction: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.green)

                Text("本地语义输入法")
                    .font(.title2.bold())

                Text(
                    "这是 iOS 内部工程预览。键盘扩展保持离线，"
                        + "已接入 librime 1.17.0 拼音候选；"
                        + "冻结 P0 轻量语义排序器已接入，神经排序器仍待验证。"
                )
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    private var readiness: some View {
        Section("当前状态") {
            StatusRow(
                title: "键盘扩展",
                detail: "可构建、可启用、可输入",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
            StatusRow(
                title: "Full Access",
                detail: "不需要，请保持关闭",
                systemImage: "lock.shield.fill",
                tint: .green
            )
            StatusRow(
                title: "Rime 候选",
                detail: "原生 1.17.0 已接入，等待真机验收",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
            StatusRow(
                title: "AI 语义候选",
                detail: "P0 轻量排序已接入；神经模型与真机仍待验",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        }
    }

    private var setupInstructions: some View {
        Section("启用键盘") {
            InstructionRow(number: 1, text: "打开“设置 → 通用 → 键盘 → 键盘”。")
            InstructionRow(number: 2, text: "选择“添加新键盘”，然后选择 RimeAI。")
            InstructionRow(number: 3, text: "不要开启“允许完全访问”。")

            Button("打开本应用设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString)
                else {
                    return
                }
                UIApplication.shared.open(url)
            }
        }
    }

    private var keyboardTest: some View {
        Section("本地键盘测试") {
            TextField(
                "在这里输入拼音或英文",
                text: $sampleText,
                axis: .vertical
            )
            .focused($isTestingKeyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(3 ... 6)
            .accessibilityIdentifier("keyboard-test-field")

            Button("开始测试") {
                isTestingKeyboard = true
            }

            if !sampleText.isEmpty {
                Button("清空测试文本", role: .destructive) {
                    sampleText = ""
                }
            }
        }
    }

    private var privacyBoundary: some View {
        Section("隐私边界") {
            Label("不请求网络访问", systemImage: "network.slash")
            Label("不共享跨应用容器", systemImage: "externaldrive.badge.xmark")
            Label("不记录输入原文", systemImage: "text.badge.xmark")
            Text(
                "本内部版本用于验证键盘无需 Full Access 时的基础输入、"
                    + "真实设备内存和隐私边界；通过前不视为 iOS 产品完成。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(.green.opacity(0.18), in: Circle())
                .accessibilityHidden(true)

            Text(text)
        }
    }
}

#Preview {
    ContentView()
}
