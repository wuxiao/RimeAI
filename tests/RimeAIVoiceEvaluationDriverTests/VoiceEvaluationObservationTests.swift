import Testing
@testable import RimeAIVoiceEvaluationDriver

struct VoiceEvaluationObservationTests {
    @Test
    func finalAllowsTailPartialAfterStopButBeforeFinal() throws {
        let observation = VoiceEvaluationObservation.final(
            sampleID: "sample-1",
            partials: [VoiceEvaluationPartial(
                sequence: 1,
                text: "尾帧",
                elapsedMilliseconds: 21
            )],
            stopReceivedElapsedMilliseconds: 20,
            text: "尾帧",
            confidence: 0.5,
            elapsedMilliseconds: 22
        )

        try observation.validate(expectedSampleID: "sample-1")
    }

    @Test
    func rejectsTextsThatCannotComeFromServerCore() {
        let invalidPartials = [
            "",
            "line\nbreak",
            String(repeating: "字", count: 201),
        ]
        for text in invalidPartials {
            let observation = VoiceEvaluationObservation.error(
                sampleID: "sample-1",
                partials: [VoiceEvaluationPartial(
                    sequence: 1,
                    text: text,
                    elapsedMilliseconds: 1
                )],
                stopReceivedElapsedMilliseconds: nil
            )
            #expect(throws: VoiceEvaluationError.self) {
                try observation.validate(expectedSampleID: "sample-1")
            }
        }

        for text in [
            "line\rbreak",
            String(repeating: "字", count: 201),
        ] {
            let observation = VoiceEvaluationObservation.final(
                sampleID: "sample-1",
                partials: [],
                stopReceivedElapsedMilliseconds: 1,
                text: text,
                confidence: 0.5,
                elapsedMilliseconds: 2
            )
            #expect(throws: VoiceEvaluationError.self) {
                try observation.validate(expectedSampleID: "sample-1")
            }
        }
    }
}
