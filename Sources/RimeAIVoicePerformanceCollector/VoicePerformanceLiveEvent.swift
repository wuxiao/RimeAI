import Foundation

public enum VoicePerformanceKeyboardPhase:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case baseline
    case helperLoadedIdle = "helper_loaded_idle"
    case listeningCancelToRime = "listening_cancel_to_rime"
}

public enum VoicePerformanceLateChallengeScenario:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case cancel
    case applicationSwitch = "application_switch"
    case secureInput = "secure_input"
    case targetInvalidation = "target_invalidation"
    case keyboardInput = "keyboard_input"
}

public enum VoicePerformanceLiveEvent: Equatable, Sendable {
    public static let maximumEncodedBytes = 4_096

    case coldArtifactLoadBegin(sequence: Int)
    case coldArtifactLoadEnd(sequence: Int)
    case sessionBegin(sampleID: String)
    case sessionEnd(sampleID: String)
    case keyboardBegin(sequence: Int, phase: VoicePerformanceKeyboardPhase)
    case keyboardCandidateReady(
        sequence: Int,
        phase: VoicePerformanceKeyboardPhase
    )
    case lateVoiceCommit
    case challenge(scenario: VoicePerformanceLateChallengeScenario)
    case finish

    public static func decodeStrictNDJSONLine(_ data: Data) throws -> Self {
        do {
            let value = try VoicePerformanceStrictJSON.validate(
                data,
                maximumBytes: maximumEncodedBytes,
                maximumDepth: 2,
                maximumNodes: 16
            )
            guard let object = value as? [String: Any],
                  VoicePerformanceStrictJSON.strictInteger(
                      object["schema_version"]
                  ) == 1,
                  let event = object["event"] as? String
            else { throw VoicePerformanceCollectorError.invalidEvent }

            switch event {
            case "cold_artifact_load_begin":
                return try artifactEvent(
                    object,
                    event: event,
                    constructor: Self.coldArtifactLoadBegin
                )
            case "cold_artifact_load_end":
                return try artifactEvent(
                    object,
                    event: event,
                    constructor: Self.coldArtifactLoadEnd
                )
            case "session_begin":
                return try sessionEvent(
                    object,
                    event: event,
                    constructor: Self.sessionBegin
                )
            case "session_end":
                return try sessionEvent(
                    object,
                    event: event,
                    constructor: Self.sessionEnd
                )
            case "keyboard_begin":
                return try keyboardEvent(
                    object,
                    event: event,
                    constructor: Self.keyboardBegin
                )
            case "keyboard_candidate_ready":
                return try keyboardEvent(
                    object,
                    event: event,
                    constructor: Self.keyboardCandidateReady
                )
            case "late_voice_commit":
                guard VoicePerformanceStrictJSON.hasExactKeys(object, [
                    "schema_version", "event",
                ]) else { throw VoicePerformanceCollectorError.invalidEvent }
                return .lateVoiceCommit
            case "challenge":
                guard VoicePerformanceStrictJSON.hasExactKeys(object, [
                    "schema_version", "event", "scenario",
                ]),
                      let rawScenario = object["scenario"] as? String,
                      let scenario = VoicePerformanceLateChallengeScenario(
                          rawValue: rawScenario
                      )
                else { throw VoicePerformanceCollectorError.invalidEvent }
                return .challenge(scenario: scenario)
            case "finish":
                guard VoicePerformanceStrictJSON.hasExactKeys(object, [
                    "schema_version", "event",
                ]) else { throw VoicePerformanceCollectorError.invalidEvent }
                return .finish
            default:
                throw VoicePerformanceCollectorError.invalidEvent
            }
        } catch let error as VoicePerformanceCollectorError {
            if error == .invalidEvent { throw error }
            throw VoicePerformanceCollectorError.invalidEvent
        } catch {
            throw VoicePerformanceCollectorError.invalidEvent
        }
    }

    private static func artifactEvent(
        _ object: [String: Any],
        event: String,
        constructor: (Int) -> Self
    ) throws -> Self {
        guard VoicePerformanceStrictJSON.hasExactKeys(object, [
            "schema_version", "event", "sequence",
        ]),
              let sequence = VoicePerformanceStrictJSON.strictInteger(
                  object["sequence"]
              ),
              sequence > 0
        else { throw VoicePerformanceCollectorError.invalidEvent }
        return constructor(sequence)
    }

    private static func sessionEvent(
        _ object: [String: Any],
        event: String,
        constructor: (String) -> Self
    ) throws -> Self {
        guard VoicePerformanceStrictJSON.hasExactKeys(object, [
            "schema_version", "event", "sample_id",
        ]),
              let sampleID = object["sample_id"] as? String,
              isSafeIdentifier(sampleID)
        else { throw VoicePerformanceCollectorError.invalidEvent }
        return constructor(sampleID)
    }

    private static func keyboardEvent(
        _ object: [String: Any],
        event: String,
        constructor: (Int, VoicePerformanceKeyboardPhase) -> Self
    ) throws -> Self {
        guard VoicePerformanceStrictJSON.hasExactKeys(object, [
            "schema_version", "event", "sequence", "phase",
        ]),
              let sequence = VoicePerformanceStrictJSON.strictInteger(
                  object["sequence"]
              ),
              sequence > 0,
              let phaseValue = object["phase"] as? String,
              let phase = VoicePerformanceKeyboardPhase(rawValue: phaseValue)
        else { throw VoicePerformanceCollectorError.invalidEvent }
        return constructor(sequence, phase)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              value.utf8.count <= 128,
              isAlphaNumeric(first)
        else { return false }
        return value.utf8.allSatisfy {
            isAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5A).contains(byte)
            || (0x61 ... 0x7A).contains(byte)
    }
}
