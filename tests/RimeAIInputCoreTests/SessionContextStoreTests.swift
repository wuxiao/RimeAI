import Testing
@testable import RimeAIInputCore

@Test
func contextKeepsOnlyTheConfiguredCharacterWindow() {
    var store = SessionContextStore(maxCharacters: 5)
    store.activate(sessionID: "app-1")

    store.appendCommittedText("前文内容")
    store.appendCommittedText("新的句子")

    #expect(store.context == "容新的句子")
}

@Test
func switchingApplicationsCannotRecoverPreviousContext() {
    var store = SessionContextStore(maxCharacters: 100)
    store.activate(sessionID: "app-1")
    store.appendCommittedText("应用一的私密内容")

    store.activate(sessionID: "app-2")
    #expect(store.context.isEmpty)
    #expect(store.activeSessionID == "app-2")

    store.activate(sessionID: "app-1")
    #expect(store.context.isEmpty)
}

@Test
func secureInputAndDeactivationEraseContext() {
    var store = SessionContextStore(maxCharacters: 100)
    store.activate(sessionID: "app-1")
    store.appendCommittedText("不应保留")

    store.enterSecureInput()
    #expect(store.context.isEmpty)
    #expect(store.activeSessionID == nil)

    store.activate(sessionID: "app-2")
    store.appendCommittedText("也不应保留")
    store.deactivate()
    #expect(store.context.isEmpty)
    #expect(store.activeSessionID == nil)
}

@Test
func contextIsAvailableOnlyToTheActiveSession() {
    var store = SessionContextStore(maxCharacters: 100)
    store.activate(sessionID: "app-1")
    store.appendCommittedText("当前应用上下文")

    #expect(store.context(for: "app-1") == "当前应用上下文")
    #expect(store.context(for: "app-2").isEmpty)
}

@Test
func suspendedContextCanResumeOnlyForTheSameApplication() {
    var store = SessionContextStore(maxCharacters: 100)
    store.activate(sessionID: "com.example.editor")
    store.appendCommittedText("数据库迁移需要索引")

    store.suspend()
    #expect(store.context(for: "com.example.editor").isEmpty)

    store.activate(sessionID: "com.example.editor")
    #expect(
        store.context(for: "com.example.editor")
            == "数据库迁移需要索引"
    )

    store.suspend()
    store.activate(sessionID: "com.example.mail")
    #expect(store.context(for: "com.example.mail").isEmpty)
}

@Test
func deactivatingOneControllerDoesNotSuspendAnotherControllerInSameApp() {
    var store = SessionContextStore(maxCharacters: 100)
    store.activate(
        sessionID: "com.example.editor",
        ownerID: "controller-a"
    )
    store.appendCommittedText("仍在使用的上下文")
    store.activate(
        sessionID: "com.example.editor",
        ownerID: "controller-b"
    )

    store.suspend(ownerID: "controller-a")

    #expect(
        store.context(for: "com.example.editor") == "仍在使用的上下文"
    )
}
