import Foundation
import RimeAIInputCore
import RimeAIVoicePerformanceControlCore

struct VoiceHelperInternalTracerLoadAuthorization: Equatable, Sendable {
    let sessionID: String
    let generation: UInt64
    let ticket: String
}

enum VoiceHelperInternalTracerLoadError: Error, Equatable, Sendable {
    case invalidState
    case authorizationMismatch
    case engineLoadFailed
}

/// Prepared loader used only by the internal performance-control tracer.
/// Preparing it selects a policy-authorized factory but does not invoke it.
/// It performs no transport authentication and is not release evidence.
final class VoiceHelperInternalTracerPreparedEngine: @unchecked Sendable {
    typealias Loader = () throws -> any VoiceDictationEngine

    private enum State {
        case prepared
        case armed(VoiceHelperInternalTracerLoadAuthorization)
        case loading
        case loaded
        case terminal
    }

    private let lock = NSLock()
    private var loader: Loader?
    private var state = State.prepared

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func arm(
        sessionID: String,
        generation: UInt64,
        ticket: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard case .prepared = state else {
            loader = nil
            state = .terminal
            throw VoiceHelperInternalTracerLoadError.invalidState
        }
        state = .armed(VoiceHelperInternalTracerLoadAuthorization(
            sessionID: sessionID,
            generation: generation,
            ticket: ticket
        ))
    }

    func completeBeginBoundaryAcknowledgement(
        sessionID: String,
        generation: UInt64,
        ticket: String
    ) throws -> any VoiceDictationEngine {
        let authorization = VoiceHelperInternalTracerLoadAuthorization(
            sessionID: sessionID,
            generation: generation,
            ticket: ticket
        )
        let selectedLoader: Loader
        lock.lock()
        guard case .armed(let expected) = state,
              let loader
        else {
            if case .prepared = state {
                self.loader = nil
                state = .terminal
            }
            lock.unlock()
            throw VoiceHelperInternalTracerLoadError.invalidState
        }
        guard expected == authorization else {
            self.loader = nil
            state = .terminal
            lock.unlock()
            throw VoiceHelperInternalTracerLoadError.authorizationMismatch
        }
        selectedLoader = loader
        self.loader = nil
        state = .loading
        lock.unlock()

        let engine: any VoiceDictationEngine
        do {
            engine = try selectedLoader()
        } catch {
            guard finishLoading(as: .terminal) else {
                throw VoiceHelperInternalTracerLoadError.invalidState
            }
            throw VoiceHelperInternalTracerLoadError.engineLoadFailed
        }
        guard finishLoading(as: .loaded) else {
            throw VoiceHelperInternalTracerLoadError.invalidState
        }
        return engine
    }

    func cancel() {
        terminate()
    }

    func disconnect() {
        terminate()
    }

    func timeout() {
        terminate()
    }

    private func terminate() {
        lock.lock()
        loader = nil
        state = .terminal
        lock.unlock()
    }

    @discardableResult
    private func finishLoading(as completedState: State) -> Bool {
        lock.lock()
        guard case .loading = state else {
            lock.unlock()
            return false
        }
        state = completedState
        lock.unlock()
        return true
    }
}

struct VoiceHelperInternalTracerPreparedBundle: Sendable {
    let engine: VoiceHelperInternalTracerPreparedEngine
    let verifiedReleasePolicySHA256: PerformanceControlSHA256
}
