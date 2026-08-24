public struct CandidateSelectionTransition: Equatable, Sendable {
    public let committedText: String
    public let historyInput: String
    public let remainingInput: String?

    public init?(
        originalInput: String,
        committedText: String,
        remainingInput: String
    ) {
        guard Self.isValidRawInput(originalInput),
              !committedText.isEmpty,
              !committedText.contains("\n"),
              !committedText.contains("\r")
        else {
            return nil
        }
        if remainingInput.isEmpty {
            self.committedText = committedText
            historyInput = originalInput
            self.remainingInput = nil
            return
        }
        guard Self.isValidRawInput(remainingInput),
              remainingInput.count < originalInput.count,
              originalInput.hasSuffix(remainingInput)
        else {
            return nil
        }
        let consumedCount = originalInput.count - remainingInput.count
        let consumed = String(originalInput.prefix(consumedCount))
        guard !consumed.isEmpty else {
            return nil
        }
        self.committedText = committedText
        historyInput = consumed
        self.remainingInput = remainingInput
    }

    private static func isValidRawInput(_ input: String) -> Bool {
        !input.isEmpty && input.utf8.allSatisfy { byte in
            byte == 0x27 || (0x61 ... 0x7a).contains(byte)
        }
    }
}

enum CandidateSelectionApplicationTransition {
    @discardableResult
    static func apply(
        _ transition: CandidateSelectionTransition,
        secureInputIsActive: () -> Bool,
        cancelForSecureInput: () -> Void,
        insertConfirmedPrefix: (_ text: String, _ pinyin: String) -> Bool,
        retainMarkedComposition: (_ remainingInput: String) -> Void,
        resetComposition: () -> Void,
        recordConfirmedHotword: (_ text: String) -> Void
    ) -> Bool {
        guard !secureInputIsActive() else {
            cancelForSecureInput()
            return false
        }
        guard insertConfirmedPrefix(
            transition.committedText,
            transition.historyInput
        ) else {
            return false
        }
        guard !secureInputIsActive() else {
            cancelForSecureInput()
            return false
        }
        if let remainingInput = transition.remainingInput {
            retainMarkedComposition(remainingInput)
        } else {
            resetComposition()
        }
        recordConfirmedHotword(transition.committedText)
        return true
    }
}
