import Foundation

public struct CompositionToken: Equatable, Sendable {
    public let compositionID: UUID
    public let revision: UInt64
    public let appSessionID: String

    public init(
        compositionID: UUID,
        revision: UInt64,
        appSessionID: String
    ) {
        self.compositionID = compositionID
        self.revision = revision
        self.appSessionID = appSessionID
    }
}

public struct CompositionState: Sendable {
    public private(set) var compositionID = UUID()
    public private(set) var revision: UInt64 = 0
    public private(set) var appSessionID: String
    public private(set) var pinyin = ""
    public private(set) var mainCandidates: [String] = []
    public private(set) var semanticCandidate: String?
    public private(set) var isSelecting = false
    public private(set) var isSecureInput = false

    public init(appSessionID: String) {
        self.appSessionID = appSessionID
    }

    @discardableResult
    public mutating func replaceInput(
        pinyin: String,
        candidates: [String]
    ) -> CompositionToken {
        if self.pinyin.isEmpty {
            compositionID = UUID()
        }
        revision &+= 1
        self.pinyin = pinyin
        mainCandidates = candidates
        semanticCandidate = nil
        isSelecting = false
        isSecureInput = false
        return token
    }

    @discardableResult
    public mutating func applySemanticCandidate(
        _ candidate: String,
        token: CompositionToken
    ) -> Bool {
        guard !candidate.isEmpty,
              !isSelecting,
              !isSecureInput,
              token == self.token
        else {
            return false
        }
        semanticCandidate = candidate
        return true
    }

    public mutating func beginSelection() {
        revision &+= 1
        isSelecting = true
        semanticCandidate = nil
    }

    public mutating func reset() {
        revision &+= 1
        compositionID = UUID()
        pinyin = ""
        mainCandidates = []
        semanticCandidate = nil
        isSelecting = false
    }

    public mutating func enterSecureInput() {
        reset()
        isSecureInput = true
    }

    public mutating func switchApplicationSession(to identifier: String) {
        reset()
        appSessionID = identifier
        isSecureInput = false
    }

    public var token: CompositionToken {
        CompositionToken(
            compositionID: compositionID,
            revision: revision,
            appSessionID: appSessionID
        )
    }
}
