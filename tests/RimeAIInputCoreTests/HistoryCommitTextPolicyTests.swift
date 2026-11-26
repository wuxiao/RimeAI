import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Voice commits in the shared keyboard history")
struct HistoryCommitTextPolicyTests {
    @Test("text within the store limit is recorded unchanged")
    func unchanged() {
        let text = "明天下午三点开会"
        #expect(HistoryCommitTextPolicy.textForHistory(text) == text)
    }

    @Test("an over-long dictation is cut on a character boundary instead of rejected")
    func truncatedOnCharacterBoundary() {
        let han = String(repeating: "长", count: 6_000)
        let boundedHan = HistoryCommitTextPolicy.textForHistory(han)
        #expect(boundedHan.utf8.count <= HistoryCommitTextPolicy.maximumUTF8Bytes)
        // 16_383 bytes = 5_461 three-byte characters: never a split code point.
        #expect(boundedHan.count == 5_461)
        #expect(han.hasPrefix(boundedHan))

        let ascii = String(repeating: "a", count: 20_000)
        #expect(
            HistoryCommitTextPolicy.textForHistory(ascii).utf8.count
                == HistoryCommitTextPolicy.maximumUTF8Bytes
        )
    }

    @Test("a voice commit with empty pinyin is accepted by the history store")
    func storeAcceptsVoiceCommit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeAI-HistoryCommitTextPolicy-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(
            databaseURL: directory.appendingPathComponent("history.sqlite3")
        )
        let overLongDictation = String(repeating: "长", count: 6_000)

        // Over the limit the store refuses; the bounded text is stored.
        #expect(throws: HistoryStoreError.self) {
            try store.append(
                HistoryCommit(
                    bundleIdentifier: "com.example.Editor",
                    pinyin: "",
                    committedText: overLongDictation,
                    source: .voiceDictation
                )
            )
        }
        try store.append(
            HistoryCommit(
                bundleIdentifier: "com.example.Editor",
                pinyin: "",
                committedText: HistoryCommitTextPolicy.textForHistory(
                    overLongDictation
                ),
                source: .voiceDictation
            )
        )

        let records = try store.records()
        #expect(records.count == 1)
        #expect(records.first?.source == .voiceDictation)
        #expect(records.first?.pinyin.isEmpty == true)
    }
}
