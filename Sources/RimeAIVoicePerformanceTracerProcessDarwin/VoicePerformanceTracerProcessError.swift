public enum VoicePerformanceTracerProcessError: String, Error, Equatable,
    Sendable, CustomStringConvertible
{
    case invalidArguments = "E_ARGUMENTS"
    case invalidTracerBundle = "E_TRACER_BUNDLE"
    case invalidResultPath = "E_RESULT_PATH"
    case invalidDeadline = "E_DEADLINE"
    case deadlineExpired = "E_DEADLINE_EXPIRED"
    case invalidTrial = "E_TRIAL"
    case clockFailure = "E_CLOCK"
    case resultAlreadyExists = "E_RESULT_EXISTS"
    case resultWriteFailed = "E_RESULT_WRITE"
    case resultCommitFailed = "E_RESULT_COMMIT"
    case resultDurabilityFailed = "E_RESULT_DURABILITY"
    case resultInstallationIndeterminate = "E_RESULT_INDETERMINATE"
    case processSpawnFailed = "E_PROCESS_SPAWN"
    case processGroupFailure = "E_PROCESS_GROUP"
    case processGenerationMismatch = "E_PROCESS_GENERATION"
    case processTerminationTimedOut = "E_PROCESS_TIMEOUT"
    case processWaitFailed = "E_PROCESS_WAIT"
    case processExitedUnsuccessfully = "E_PROCESS_EXIT"
    case processCleanupFailed = "E_PROCESS_CLEANUP"

    public var code: String { rawValue }
    public var description: String { rawValue }
}
