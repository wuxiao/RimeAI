import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Failure circuit breaker")
struct FailureCircuitBreakerTests {
    @Test("opens after threshold and closes after cooldown")
    func opensAndCloses() {
        var breaker = FailureCircuitBreaker(
            failureThreshold: 3,
            cooldown: 30
        )
        let start = Date(timeIntervalSince1970: 1_000)

        breaker.recordFailure(at: start)
        breaker.recordFailure(at: start)
        #expect(breaker.allowsRequest(at: start))

        breaker.recordFailure(at: start)
        #expect(!breaker.allowsRequest(at: start.addingTimeInterval(29)))
        #expect(breaker.allowsRequest(at: start.addingTimeInterval(30)))
    }

    @Test("success resets consecutive failures")
    func successResets() {
        var breaker = FailureCircuitBreaker()
        let start = Date(timeIntervalSince1970: 2_000)

        breaker.recordFailure(at: start)
        breaker.recordFailure(at: start)
        breaker.recordSuccess()
        breaker.recordFailure(at: start)

        #expect(breaker.allowsRequest(at: start))
        #expect(breaker.consecutiveFailures == 1)
    }
}
