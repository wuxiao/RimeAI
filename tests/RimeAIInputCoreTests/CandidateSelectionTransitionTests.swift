import Testing
@testable import RimeAIInputCore

@Suite("Candidate selection transition")
struct CandidateSelectionTransitionTests {
    @Test("whole-composition selection records the whole input")
    func completeSelection() throws {
        let transition = try #require(CandidateSelectionTransition(
            originalInput: "nihao",
            committedText: "你好",
            remainingInput: ""
        ))

        #expect(transition.committedText == "你好")
        #expect(transition.historyInput == "nihao")
        #expect(transition.remainingInput == nil)
    }

    @Test("partial selection commits only the chosen prefix and retains tail")
    func partialSelection() throws {
        let transition = try #require(CandidateSelectionTransition(
            originalInput: "mingtiantianqi",
            committedText: "明天",
            remainingInput: "tianqi"
        ))

        #expect(transition.committedText == "明天")
        #expect(transition.historyInput == "mingtian")
        #expect(transition.remainingInput == "tianqi")
    }

    @Test("apostrophe separator belongs to the consumed prefix")
    func apostropheBoundary() throws {
        let transition = try #require(CandidateSelectionTransition(
            originalInput: "xi'anrenmin",
            committedText: "西安",
            remainingInput: "renmin"
        ))

        #expect(transition.historyInput == "xi'an")
        #expect(transition.remainingInput == "renmin")
    }

    @Test("unauthoritative native tails fail closed")
    func invalidTail() {
        #expect(CandidateSelectionTransition(
            originalInput: "mingtiantianqi",
            committedText: "明天",
            remainingInput: "qianqi"
        ) == nil)
        #expect(CandidateSelectionTransition(
            originalInput: "mingtiantianqi",
            committedText: "明天",
            remainingInput: "mingtiantianqi"
        ) == nil)
        #expect(CandidateSelectionTransition(
            originalInput: "mingtiantianqi",
            committedText: "明天\n天气",
            remainingInput: "tianqi"
        ) == nil)
    }
}
