import Foundation

extension Notification.Name {
    static let rimeAIVoiceHistoryDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.voice-history-did-change"
    )
}

/// 进程级语音历史与使用情况统计服务（独立于云端明文历史，仅存本机）。
///
/// - 全部存储操作（含清空、关闭句柄）串行在同一条队列上；写入在调用时
///   捕获代次，执行前若已被一次清空超越则直接丢弃，绝不会把清空前的
///   会话内容悄悄写回去。
/// - `clearAll()` 之后进入“已清空”状态：读取返回空结果而不会重建一个
///   空数据库，直到下一次真实语音会话写入或显式 `resumeAfterClear()`。
final class VoiceHistoryService: @unchecked Sendable {
    static let shared = VoiceHistoryService()

    private let storeQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-history-service",
        qos: .utility
    )
    /// 只保护 `generation` / `isCleared`；`store` 指针仅在 `storeQueue` 上读写。
    private let lock = NSLock()
    private let databaseURL: URL
    private var store: VoiceHistoryStore?
    private var generation: UInt64 = 0
    private var isCleared = false

    private convenience init() {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        self.init(databaseURL: layout.voiceHistoryDatabase)
    }

    /// 测试注入独立数据库路径；首次访问时才创建，不会预先落盘。
    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    // MARK: - Write

    func recordSessionAsync(
        _ record: VoiceHistoryRecord,
        storeHistoryText: Bool
    ) {
        // 真实的语音会话是用户重新使用语音的明确信号：解除“已清空”状态。
        // 代次只在清空时前进；这里仅捕获当前值，供执行前判断是否已被清空超越。
        let capturedGeneration = lock.withLock { () -> UInt64 in
            isCleared = false
            return generation
        }
        storeQueue.async { [weak self] in
            guard let self else {
                return
            }
            let current = self.lock.withLock {
                (self.generation, self.isCleared)
            }
            guard Self.shouldPersistRecord(
                capturedGeneration: capturedGeneration,
                currentGeneration: current.0,
                isCleared: current.1
            ) else {
                NSLog("[VoiceHistoryService] 丢弃清空前入队的语音历史写入")
                return
            }
            guard let store = self.openStoreOnQueue() else {
                NSLog("[VoiceHistoryService] 语音历史存储不可用，放弃写入")
                return
            }
            do {
                try store.recordSession(record, storeHistoryText: storeHistoryText)
                self.notifyChanged()
            } catch {
                // 历史写入失败绝不阻塞或影响语音上屏，但必须留下诊断线索。
                NSLog("[VoiceHistoryService] 语音历史写入失败：\(error)")
            }
        }
    }

    // MARK: - Read

    func listRecords(
        query: String? = nil,
        actionKind: VoicePostProcessAction? = nil,
        limit: Int = 200
    ) throws -> [VoiceHistoryRecord] {
        try storeQueue.sync {
            guard let store = openStoreOnQueue() else {
                return []
            }
            return try store.listRecords(
                query: query,
                actionKind: actionKind,
                limit: limit
            )
        }
    }

    func usageSummary() throws -> VoiceUsageSummary {
        try storeQueue.sync {
            guard let store = openStoreOnQueue() else {
                return .empty
            }
            return try store.usageSummary()
        }
    }

    func exportHistoryJSONL(to url: URL) throws {
        try storeQueue.sync {
            if let store = openStoreOnQueue() {
                try store.exportHistoryJSONL(to: url)
            } else {
                try Data().write(to: url, options: .atomic)
            }
            applyPrivatePermissions(to: url)
        }
    }

    // MARK: - Mutate

    func deleteRecord(id: UUID) throws {
        try storeQueue.sync {
            // 已清空且无库可删：视为成功，而不是向用户报“存储不可用”。
            guard let store = openStoreOnQueue() else {
                return
            }
            try store.deleteRecord(id: id)
        }
        notifyChanged()
    }

    func clearHistory() throws {
        try clearAdvancingGeneration { store in
            try store.clearHistory()
        }
    }

    func resetUsageStatistics() throws {
        try clearAdvancingGeneration { store in
            try store.resetUsageStatistics()
        }
    }

    func clearAll() throws {
        try storeQueue.sync {
            advanceGenerationLocked(markCleared: true)
            if let store {
                try store.clearAll()
            }
            store = nil
        }
        notifyChanged()
    }

    /// 仅关闭当前打开的数据库句柄；下次访问时惰性重开。
    func discardOpenStore() {
        storeQueue.sync {
            store = nil
        }
    }

    /// 清空后允许重新打开数据库（下一次语音会话写入时也会自动解除）。
    func resumeAfterClear() {
        lock.withLock {
            isCleared = false
        }
    }

    // MARK: - Pure Policy

    /// 排队写入执行前是否仍应落库：清空前捕获的代次已被超越，或处于
    /// 已清空状态时丢弃。
    static func shouldPersistRecord(
        capturedGeneration: UInt64,
        currentGeneration: UInt64,
        isCleared: Bool
    ) -> Bool {
        capturedGeneration == currentGeneration && !isCleared
    }

    /// 无打开句柄时是否允许重建：已清空状态下绝不悄悄重建一个空库。
    static func shouldReopenStore(hasOpenStore: Bool, isCleared: Bool) -> Bool {
        !hasOpenStore && !isCleared
    }

    /// 导出的 JSONL 含听写原文：仅所有者可读。
    static func privateExportPosixPermissions() -> Int {
        0o600
    }

    // MARK: - Private

    private func clearAdvancingGeneration(
        _ body: (VoiceHistoryStore) throws -> Void
    ) throws {
        try storeQueue.sync {
            guard let store = openStoreOnQueue() else {
                return
            }
            // 丢弃清空前捕获、尚未执行的写入，避免清空后旧会话又被写回。
            advanceGenerationLocked(markCleared: false)
            try body(store)
        }
        notifyChanged()
    }

    private func advanceGenerationLocked(markCleared: Bool) {
        lock.withLock {
            generation &+= 1
            if markCleared {
                isCleared = true
            }
        }
    }

    /// 仅可在 `storeQueue` 上调用。
    private func openStoreOnQueue() -> VoiceHistoryStore? {
        if let store {
            return store
        }
        let cleared = lock.withLock { isCleared }
        guard Self.shouldReopenStore(hasOpenStore: false, isCleared: cleared) else {
            NSLog("[VoiceHistoryService] 语音历史已清空，跳过重建数据库")
            return nil
        }
        do {
            let opened = try VoiceHistoryStore(databaseURL: databaseURL)
            store = opened
            return opened
        } catch {
            NSLog("[VoiceHistoryService] 打开语音历史数据库失败：\(error)")
            return nil
        }
    }

    private func applyPrivatePermissions(to url: URL) {
        // 直接用 chmod(2)：Foundation 的 setAttributes(.posixPermissions) 在部分
        // 进程里会“成功返回却不生效”。导出文件含听写原文，0600 必须是确定结果。
        guard chmod(url.path, mode_t(Self.privateExportPosixPermissions())) == 0 else {
            NSLog(
                "[VoiceHistoryService] 设置导出文件权限失败：errno=\(errno) path=\(url.path)"
            )
            return
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .rimeAIVoiceHistoryDidChange,
                object: self
            )
        }
    }
}
