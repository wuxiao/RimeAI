import XCTest
@testable import RimeAIInputMethod

/// 进程级语音历史服务：写入/清空串行化、清空后不悄悄重建空库、
/// 导出文件 0600 权限。
@MainActor
final class VoiceHistoryServiceTests: XCTestCase {
    private var root: URL!
    private var databaseURL: URL!
    private var service: VoiceHistoryService!
    private var observers: [NSObjectProtocol] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeai-voice-history-\(UUID().uuidString)", isDirectory: true)
        databaseURL = root.appendingPathComponent("voice-history/voice-history.sqlite3")
        service = VoiceHistoryService(databaseURL: databaseURL)
    }

    override func tearDown() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    private func makeRecord(
        _ text: String = "你好世界",
        bundleIdentifier: String = "com.apple.finder"
    ) -> VoiceHistoryRecord {
        VoiceHistoryRecord(
            bundleIdentifier: bundleIdentifier,
            rawText: "尼号世界",
            finalText: text,
            actionKind: .dictation,
            durationMilliseconds: 1_200,
            autoPasted: true
        )
    }

    /// 轮询期间持续驱动主 run loop：后台串行队列完成写入后，变更通知也要能
    /// 及时投递到主线程，避免积压到后面的用例里。
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// 让主队列上已排队的通知先投递完。
    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// 统计变更通知次数；配合 `waitUntil` 使用，避免 XCTestExpectation 重复 fulfill。
    private func observeChangeNotifications() -> Int {
        changeNotifications = 0
        observers.append(NotificationCenter.default.addObserver(
            forName: .rimeAIVoiceHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.changeNotifications += 1
        })
        return changeNotifications
    }

    private var changeNotifications = 0

    // MARK: - Write Path

    func testAsyncWriteIsPersistedAndListed() throws {
        service.recordSessionAsync(makeRecord(), storeHistoryText: true)

        XCTAssertTrue(waitUntil { (try? self.service.listRecords())?.count == 1 })
        let records = try service.listRecords()
        XCTAssertEqual(records.first?.finalText, "你好世界")
        XCTAssertEqual(try service.usageSummary().totalSessions, 1)
        XCTAssertEqual(try service.usageSummary().autoPastedSessions, 1)
    }

    func testHistoryTextIsNotStoredWhenDisabledButUsageStillCounts() throws {
        service.recordSessionAsync(makeRecord(), storeHistoryText: false)

        XCTAssertTrue(waitUntil { (try? self.service.usageSummary())?.totalSessions == 1 })
        XCTAssertTrue(try service.listRecords().isEmpty, "关闭历史后只累计统计，不落明文")
    }

    func testDiscardOpenStoreReopensLazilyOnNextAccess() throws {
        service.recordSessionAsync(makeRecord(), storeHistoryText: true)
        XCTAssertTrue(waitUntil { (try? self.service.listRecords())?.count == 1 })

        service.discardOpenStore()

        XCTAssertEqual(try service.usageSummary().totalSessions, 1)
        XCTAssertEqual(try service.listRecords().count, 1)
    }

    // MARK: - clearAll vs Async Writes

    func testClearAllWinsOverQueuedAsyncWrites() throws {
        for index in 0 ..< 20 {
            service.recordSessionAsync(makeRecord("第 \(index) 条"), storeHistoryText: true)
        }

        // 与 20 条排队写入并发：清空必须排在他们之后生效，而不是被旧写入覆盖。
        try service.clearAll()

        XCTAssertTrue(waitUntil { (try? self.service.usageSummary())?.totalSessions == 0 })
        XCTAssertEqual(try service.listRecords(), [])
        XCTAssertEqual(try service.usageSummary(), .empty)
    }

    func testClearAllPreventsSilentlyRecreatingAnEmptyDatabase() throws {
        service.recordSessionAsync(makeRecord(), storeHistoryText: true)
        XCTAssertTrue(waitUntil { (try? self.service.listRecords())?.count == 1 })

        try service.clearAll()
        // 模拟“停用并清除本地制品”把数据库文件移走。
        try FileManager.default.removeItem(at: root)

        XCTAssertEqual(try service.listRecords(), [])
        XCTAssertEqual(try service.usageSummary(), .empty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: databaseURL.path),
            "清空后仅为了刷新页面不得悄悄重建一个空数据库"
        )

        // 新的真实语音会话会解除“已清空”状态并重新建库。
        service.recordSessionAsync(makeRecord("新会话"), storeHistoryText: true)
        XCTAssertTrue(waitUntil { (try? self.service.listRecords())?.count == 1 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testResumeAfterClearAllowsReopeningForDisplay() throws {
        // 从未写入过的服务没有数据库目录可删：clearAll 后同样不得重建。
        try service.clearAll()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        _ = try service.listRecords()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        service.resumeAfterClear()

        XCTAssertEqual(try service.listRecords(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testClearHistoryAndResetStatisticsAdvanceGeneration() throws {
        service.recordSessionAsync(makeRecord(), storeHistoryText: true)
        XCTAssertTrue(waitUntil { (try? self.service.listRecords())?.count == 1 })

        try service.clearHistory()
        XCTAssertEqual(try service.listRecords(), [])
        XCTAssertEqual(try service.usageSummary().totalSessions, 1, "清空文本保留统计")

        try service.resetUsageStatistics()
        XCTAssertEqual(try service.usageSummary().totalSessions, 0)
    }

    func testMutationsAfterClearAllSucceedWithoutAStore() throws {
        try service.clearAll()

        // 已清空且无库：视为成功，而不是向用户报“存储不可用”。
        try service.deleteRecord(id: UUID())
        try service.clearHistory()
        try service.resetUsageStatistics()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testStaleWriteGenerationIsDropped() {
        XCTAssertTrue(VoiceHistoryService.shouldPersistRecord(
            capturedGeneration: 4, currentGeneration: 4, isCleared: false
        ))
        XCTAssertFalse(VoiceHistoryService.shouldPersistRecord(
            capturedGeneration: 4, currentGeneration: 5, isCleared: false
        ), "清空前捕获的代次已被超越：丢弃，避免旧会话被写回")
        XCTAssertFalse(VoiceHistoryService.shouldPersistRecord(
            capturedGeneration: 5, currentGeneration: 5, isCleared: true
        ))
        XCTAssertFalse(VoiceHistoryService.shouldReopenStore(hasOpenStore: false, isCleared: true))
        XCTAssertTrue(VoiceHistoryService.shouldReopenStore(hasOpenStore: false, isCleared: false))
    }

    // MARK: - Change Notification

    func testDeleteNotifiesOnMainThread() throws {
        service.recordSessionAsync(makeRecord(), storeHistoryText: true)
        XCTAssertTrue(waitUntil { (try? self.service.listRecords())?.count == 1 })
        // 先让写入产生的通知投递完，再只统计删除触发的通知。
        _ = observeChangeNotifications()
        waitUntil { self.changeNotifications >= 1 }
        drainMainQueue()
        changeNotifications = 0
        let record = try XCTUnwrap(try service.listRecords().first)

        try service.deleteRecord(id: record.id)

        XCTAssertTrue(waitUntil { self.changeNotifications == 1 }, "删除后恰好通知一次")
        XCTAssertTrue(try service.listRecords().isEmpty)
    }

    // MARK: - Export

    func testExportHistoryJSONLIsOwnerReadableOnly() throws {
        service.recordSessionAsync(makeRecord("第一条"), storeHistoryText: true)
        service.recordSessionAsync(makeRecord("第二条"), storeHistoryText: true)
        XCTAssertTrue(waitUntil { (try? self.service.listRecords())?.count == 2 })
        let destination = root.appendingPathComponent("export/voice-history.jsonl")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try service.exportHistoryJSONL(to: destination)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? Int).map { $0 & 0o777 },
            0o600,
            "导出文件含听写原文，只能所有者读取"
        )
        XCTAssertEqual(VoiceHistoryService.privateExportPosixPermissions(), 0o600)
        let lines = try String(contentsOf: destination, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        // 每行都是可独立解码的记录，且导出的是明文成稿。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { try decoder.decode(VoiceHistoryRecord.self, from: Data($0.utf8)) }
        XCTAssertEqual(Set(decoded.map(\.finalText)), ["第一条", "第二条"])
    }

    func testExportAfterClearAllWritesAnEmptyPrivateFile() throws {
        try service.clearAll()
        // 用户通过存储面板选择的位置总是已存在的目录。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("empty.jsonl")

        try service.exportHistoryJSONL(to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data())
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    }
}
