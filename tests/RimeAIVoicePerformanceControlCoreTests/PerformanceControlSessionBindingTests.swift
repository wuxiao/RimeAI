import Testing
@testable import RimeAIVoicePerformanceControlCore

@Suite("Performance-control session binding")
struct PerformanceControlSessionBindingTests {
    @Test("derivation uses raw nonce bytes, fixed domains, and UInt64 big endian")
    func derivationHasFrozenByteContract() throws {
        let binding = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: PerformanceControlNonce(
                String(repeating: "0", count: 64)
            ),
            trial: 1
        )

        #expect(
            binding.sessionID.rawValue
                == "e376b43dea206e5f2e078d40d2a8dbd2f70669c6617d50ebe70819309b473645"
        )
        #expect(
            binding.planNonce.rawValue
                == "adbb57114a46850543d63f1c2227f181ef4a1f29153fd0dfe1b83b8caad5ddad"
        )
    }

    @Test("tracer trial bounds are closed at one and thirty-two")
    func rejectsTrialsOutsideTracerBounds() throws {
        let nonce = try PerformanceControlNonce(String(repeating: "a", count: 64))

        for trial in [UInt64(0), UInt64(33), UInt64.max] {
            #expect(throws: PerformanceControlSessionBindingError.invalidTrial) {
                try PerformanceControlSessionBinding.derive(
                    controlSessionNonce: nonce,
                    trial: trial
                )
            }
        }
        _ = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: nonce,
            trial: 32
        )
    }

    @Test("session and plan nonces never cross-reuse between trials")
    func domainsAndTrialsAreDisjoint() throws {
        let nonce = try PerformanceControlNonce(String(repeating: "f", count: 64))
        let first = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: nonce,
            trial: 1
        )
        let second = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: nonce,
            trial: 2
        )

        let values = [
            first.sessionID.rawValue,
            first.planNonce.rawValue,
            second.sessionID.rawValue,
            second.planNonce.rawValue,
        ]
        let repeatedFirst = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: nonce,
            trial: 1
        )
        #expect(Set(values).count == values.count)
        #expect(first == repeatedFirst)
    }
}
