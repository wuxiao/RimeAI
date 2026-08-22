import Foundation

struct VoiceEvaluationPartial: Codable, Equatable, Sendable {
    let sequence: Int
    let text: String
    let elapsedMilliseconds: Double

    enum CodingKeys: String, CodingKey {
        case sequence
        case text
        case elapsedMilliseconds = "elapsed_ms"
    }
}

private struct VoiceEvaluationFinal: Codable, Equatable, Sendable {
    let text: String
    let confidence: Double?
    let elapsedMilliseconds: Double

    enum CodingKeys: String, CodingKey {
        case text
        case confidence
        case elapsedMilliseconds = "elapsed_ms"
    }
}

struct VoiceEvaluationObservation: Encodable, Equatable, Sendable {
    enum Outcome: String, Encodable, Equatable, Sendable {
        case final
        case noResult = "no_result"
        case error
    }

    let schemaVersion = 1
    let sampleID: String
    let outcome: Outcome
    let partials: [VoiceEvaluationPartial]
    let stopReceivedElapsedMilliseconds: Double?
    private let finalValue: VoiceEvaluationFinal?

    static func final(
        sampleID: String,
        partials: [VoiceEvaluationPartial],
        stopReceivedElapsedMilliseconds: Double,
        text: String,
        confidence: Double?,
        elapsedMilliseconds: Double
    ) -> Self {
        Self(
            sampleID: sampleID,
            outcome: .final,
            partials: partials,
            stopReceivedElapsedMilliseconds:
                stopReceivedElapsedMilliseconds,
            finalValue: VoiceEvaluationFinal(
                text: text,
                confidence: confidence,
                elapsedMilliseconds: elapsedMilliseconds
            )
        )
    }

    static func noResult(
        sampleID: String,
        partials: [VoiceEvaluationPartial],
        stopReceivedElapsedMilliseconds: Double
    ) -> Self {
        Self(
            sampleID: sampleID,
            outcome: .noResult,
            partials: partials,
            stopReceivedElapsedMilliseconds:
                stopReceivedElapsedMilliseconds,
            finalValue: nil
        )
    }

    static func error(
        sampleID: String,
        partials: [VoiceEvaluationPartial],
        stopReceivedElapsedMilliseconds: Double?
    ) -> Self {
        Self(
            sampleID: sampleID,
            outcome: .error,
            partials: partials,
            stopReceivedElapsedMilliseconds:
                stopReceivedElapsedMilliseconds,
            finalValue: nil
        )
    }

    func validate(expectedSampleID: String) throws {
        guard sampleID == expectedSampleID else {
            throw VoiceEvaluationError.rejected
        }
        var previousSequence = 0
        var previousElapsed = -1.0
        for partial in partials {
            guard partial.sequence > previousSequence,
                  Self.isValidText(partial.text),
                  partial.elapsedMilliseconds.isFinite,
                  partial.elapsedMilliseconds > previousElapsed,
                  partial.elapsedMilliseconds >= 0
            else { throw VoiceEvaluationError.rejected }
            previousSequence = partial.sequence
            previousElapsed = partial.elapsedMilliseconds
        }
        if let stopReceivedElapsedMilliseconds {
            guard stopReceivedElapsedMilliseconds.isFinite,
                  stopReceivedElapsedMilliseconds >= 0
            else { throw VoiceEvaluationError.rejected }
        }
        switch outcome {
        case .final:
            guard let stopReceivedElapsedMilliseconds,
                  let finalValue,
                  Self.isValidText(finalValue.text),
                  finalValue.elapsedMilliseconds.isFinite,
                  finalValue.elapsedMilliseconds
                    >= stopReceivedElapsedMilliseconds,
                  previousElapsed <= finalValue.elapsedMilliseconds,
                  finalValue.confidence.map({
                      $0.isFinite && (0 ... 1).contains($0)
                  }) ?? true
            else { throw VoiceEvaluationError.rejected }
        case .noResult:
            guard let stopReceivedElapsedMilliseconds,
                  previousElapsed <= stopReceivedElapsedMilliseconds,
                  finalValue == nil
            else { throw VoiceEvaluationError.rejected }
        case .error:
            guard finalValue == nil,
                  stopReceivedElapsedMilliseconds.map({
                      previousElapsed <= $0
                  }) ?? true
            else {
                throw VoiceEvaluationError.rejected
            }
        }
    }

    private static func isValidText(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 200
            && !value.contains("\r")
            && !value.contains("\n")
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sampleID = "sample_id"
        case outcome
        case partials
        case stopReceivedElapsedMilliseconds = "stop_received_elapsed_ms"
        case finalValue = "final"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sampleID, forKey: .sampleID)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(partials, forKey: .partials)
        try container.encodeIfPresent(
            stopReceivedElapsedMilliseconds,
            forKey: .stopReceivedElapsedMilliseconds
        )
        try container.encodeIfPresent(finalValue, forKey: .finalValue)
    }
}
