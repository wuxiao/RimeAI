public struct SessionContextStore: Sendable {
    public let maxCharacters: Int
    public private(set) var activeSessionID: String?
    public private(set) var retainedSessionID: String?
    public private(set) var context = ""
    private var activeOwnerIDs: Set<String> = []

    public init(maxCharacters: Int = 100) {
        precondition(maxCharacters > 0)
        self.maxCharacters = maxCharacters
    }

    public mutating func activate(
        sessionID: String,
        ownerID: String = "default"
    ) {
        if retainedSessionID != sessionID {
            erase()
            retainedSessionID = sessionID
        }
        activeOwnerIDs.insert(ownerID)
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

    public mutating func suspend(ownerID: String = "default") {
        activeOwnerIDs.remove(ownerID)
        if activeOwnerIDs.isEmpty {
            activeSessionID = nil
        }
    }

    public mutating func deactivate() {
        erase()
    }

    private mutating func erase() {
        context.removeAll(keepingCapacity: false)
        activeSessionID = nil
        retainedSessionID = nil
        activeOwnerIDs.removeAll(keepingCapacity: false)
    }
}
