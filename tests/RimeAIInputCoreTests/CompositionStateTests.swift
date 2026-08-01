import Testing
@testable import RimeAIInputCore

@Test
func mainCandidatesNeverMoveWhenSemanticResultArrives() {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件", "实践"]
    )

    let accepted = state.applySemanticCandidate(
        "事件",
        token: token
    )

    #expect(accepted)
    #expect(state.mainCandidates == ["时间", "事件", "实践"])
    #expect(state.semanticCandidate == "事件")
}

@Test
func staleSemanticResultCannotRefreshANewerComposition() {
    var state = CompositionState(appSessionID: "app-1")
    let oldToken = state.replaceInput(
        pinyin: "shi",
        candidates: ["是", "时"]
    )
    _ = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )

    let accepted = state.applySemanticCandidate(
        "是",
        token: oldToken
    )

    #expect(!accepted)
    #expect(state.semanticCandidate == nil)
}

@Test
func selectionAndSecureInputInvalidatePendingResults() {
    var state = CompositionState(appSessionID: "app-1")
    let selectingToken = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )
    state.beginSelection()
    let acceptedWhileSelecting = state.applySemanticCandidate(
        "事件",
        token: selectingToken
    )
    #expect(!acceptedWhileSelecting)

    let secureToken = state.replaceInput(
        pinyin: "mima",
        candidates: ["密码"]
    )
    state.enterSecureInput()
    let acceptedInSecureInput = state.applySemanticCandidate(
        "密码",
        token: secureToken
    )
    #expect(!acceptedInSecureInput)
    #expect(state.pinyin.isEmpty)
    #expect(state.mainCandidates.isEmpty)
}

@Test
func resultsAreIsolatedByApplicationSession() {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )
    state.switchApplicationSession(to: "app-2")

    let acceptedAcrossApplications = state.applySemanticCandidate(
        "事件",
        token: token
    )
    #expect(!acceptedAcrossApplications)
    #expect(state.appSessionID == "app-2")
    #expect(state.pinyin.isEmpty)
}
