import Foundation

public struct FailureCircuitBreaker: Sendable {
    public let failureThreshold: Int
    public let cooldown: TimeInterval
    public private(set) var consecutiveFailures = 0
    public private(set) var openUntil: Date?

    public init(
        failureThreshold: Int = 3,
        cooldown: TimeInterval = 30
    ) {
        precondition(failureThreshold > 0)
        precondition(cooldown >= 0)
        self.failureThreshold = failureThreshold
        self.cooldown = cooldown
    }

    public func allowsRequest(at date: Date = Date()) -> Bool {
        guard let openUntil else {
            return true
        }
        return date >= openUntil
    }

    public mutating func recordFailure(at date: Date = Date()) {
        if let openUntil, date >= openUntil {
            consecutiveFailures = 0
            self.openUntil = nil
        }
        consecutiveFailures += 1
        if consecutiveFailures >= failureThreshold {
            openUntil = date.addingTimeInterval(cooldown)
        }
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        openUntil = nil
    }
}
