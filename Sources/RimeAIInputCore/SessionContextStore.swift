public struct SessionContextStore: Sendable {
    public let maxCharacters: Int
    public private(set) var activeSessionID: String?
    public private(set) var context = ""

    public init(maxCharacters: Int = 100) {
        precondition(maxCharacters > 0)
        self.maxCharacters = maxCharacters
    }

    public mutating func activate(sessionID: String) {
        guard activeSessionID != sessionID else {
            return
        }
        erase()
        activeSessionID = sessionID
    }

    public mutating func appendCommittedText(_ text: String) {
        guard activeSessionID != nil, !text.isEmpty else {
            return
        }
        let combined = context + text
        context = String(combined.suffix(maxCharacters))
    }

    public func context(for sessionID: String) -> String {
        activeSessionID == sessionID ? context : ""
    }

    public mutating func enterSecureInput() {
        erase()
    }

    public mutating func deactivate() {
        erase()
    }

    private mutating func erase() {
        context.removeAll(keepingCapacity: false)
        activeSessionID = nil
    }
}
