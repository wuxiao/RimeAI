#if canImport(RimeAIInputCore) && canImport(RimeAIVoicePerformanceHelperBridge)
import Darwin
import Foundation
import RimeAIInputCore
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceControlDarwin
import RimeAIVoicePerformanceTracerProcessDarwin
@_spi(VoicePerformanceTracer) import RimeAIVoicePerformanceHelperBridge

/// Live boundary adapter for the signed helper child. Product-data layout is
/// derived from the effective user's passwd record; environment HOME is never
/// consulted.
public final class DarwinVoicePerformanceTracerHelperRuntime:
    VoicePerformanceTracerHelperCommandRuntime,
    @unchecked Sendable
{
    private let homeDirectoryResolver:
        VoicePerformanceTracerHomeDirectoryResolver

    public init() {
        homeDirectoryResolver =
            VoicePerformanceTracerHomeDirectoryResolver()
    }

    public func currentContinuousNanoseconds() throws -> UInt64 {
        try VoicePerformanceContinuousDeadline.currentNanoseconds()
    }

    public func currentHelperGeneration() throws
        -> VoicePerformanceSupervisedProcessGeneration
    {
        try VoicePerformanceLiveProcessGenerationReader()
            .currentGeneration()
    }

    public func makeFacade(
        measurementPolicy: VoicePerformanceMeasurementPolicy
    ) throws -> any VoicePerformanceTracerHelperFacade {
        let layout = RimeAIProductDataLayout(
            homeDirectory: try homeDirectoryResolver.resolve()
        )
        return try DarwinVoicePerformanceTracerHelperFacade(
            VoiceHelperPerformanceTracerBridgeFactory.make(
                layout: layout,
                measurementPolicy: measurementPolicy
            )
        )
    }

    public func connect(
        socketPath: String,
        expectedCollector: PerformanceControlExpectedPeerIdentity,
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> any VoicePerformanceTracerHelperConnection {
        do {
            let connection = try DarwinPerformanceControlUnixClient
                .connectAuthenticated(
                    socketPath: socketPath,
                    expectedCollector: expectedCollector,
                    deadline: try
                        VoicePerformanceHelperTransportDeadlineConverter()
                            .instant(for: deadline)
            )
            return DarwinVoicePerformanceTracerHelperConnection(connection)
        } catch {
            throw VoicePerformanceHelperTransportErrorNormalizer.normalize(
                error
            )
        }
    }
}

private final class DarwinVoicePerformanceTracerHelperConnection:
    VoicePerformanceTracerHelperConnection,
    @unchecked Sendable
{
    private let connection:
        DarwinPerformanceControlAuthenticatedConnection

    init(
        _ connection: DarwinPerformanceControlAuthenticatedConnection
    ) {
        self.connection = connection
    }

    func receive(
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> PerformanceControlWireFrame {
        do {
            return try connection.receive(
                deadline: try
                    VoicePerformanceHelperTransportDeadlineConverter()
                        .instant(for: deadline)
            )
        } catch {
            throw VoicePerformanceHelperTransportErrorNormalizer.normalize(
                error
            )
        }
    }

    func send(
        _ frame: PerformanceControlWireFrame,
        deadline: VoicePerformanceContinuousDeadline
    ) throws {
        do {
            try connection.send(
                frame,
                deadline: try
                    VoicePerformanceHelperTransportDeadlineConverter()
                        .instant(for: deadline)
            )
        } catch {
            throw VoicePerformanceHelperTransportErrorNormalizer.normalize(
                error
            )
        }
    }

    func close() {
        connection.close()
    }
}

enum VoicePerformanceHelperTransportErrorNormalizer {
    static func normalize(
        _ error: Error
    ) -> VoicePerformanceTracerHelperConnectionError {
        if let typed =
            error as? VoicePerformanceTracerHelperConnectionError
        {
            return typed
        }
        guard let transport = error as? PerformanceControlTransportError
        else {
            return .failed
        }
        switch transport {
        case .operationTimedOut:
            return .timedOut
        case .peerDisconnected:
            return .peerDisconnected
        default:
            return .failed
        }
    }
}

private final class DarwinVoicePerformanceTracerHelperFacade:
    VoicePerformanceTracerHelperFacade,
    @unchecked Sendable
{
    private let bridge: VoiceHelperPerformanceTracerBridge

    var authenticatedProductionDriver: Bool {
        bridge.authenticatedProductionDriver
    }

    init(_ bridge: VoiceHelperPerformanceTracerBridge) throws {
        guard !bridge.authenticatedProductionDriver else {
            throw VoicePerformanceTracerHelperCommandError
                .invalidVerifiedBundle
        }
        self.bridge = bridge
    }

    func receive(
        _ frame: PerformanceControlWireFrame,
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> PerformanceControlWireFrame {
        try requireFacadeDeadline(deadline)

        // The native Sherpa load is synchronous. The collector's outer
        // watchdog and driver-group TERM/KILL path are the hard 60-second
        // enforcement boundary. This local check prevents a completed
        // over-deadline load from emitting load_ready.
        let response = try bridge.receive(frame)
        do {
            try requireFacadeDeadline(deadline)
        } catch {
            bridge.timeout()
            throw error
        }
        return response
    }

    func cancel() {
        bridge.cancel()
    }

    func disconnect() {
        bridge.disconnect()
    }

    func timeout() {
        bridge.timeout()
    }
}

struct VoicePerformanceHelperTransportDeadlineConverter {
    private let baseInstant: () -> ContinuousClock.Instant
    private let remainingNanoseconds:
        (VoicePerformanceContinuousDeadline) throws -> UInt64

    init(
        baseInstant: @escaping () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        remainingNanoseconds: @escaping (
            VoicePerformanceContinuousDeadline
        ) throws -> UInt64 = {
            try $0.remainingNanoseconds()
        }
    ) {
        self.baseInstant = baseInstant
        self.remainingNanoseconds = remainingNanoseconds
    }

    func instant(
        for deadline: VoicePerformanceContinuousDeadline
    ) throws -> ContinuousClock.Instant {
        // Capturing the target clock before sampling mach remaining time
        // prevents conversion latency from extending the global deadline.
        let base = baseInstant()
        let remaining = try remainingNanoseconds(deadline)
        guard remaining > 0 else {
            throw VoicePerformanceTracerHelperConnectionError.timedOut
        }
        let duration = min(remaining, UInt64(Int64.max))
        return base.advanced(by: .nanoseconds(Int64(duration)))
    }
}

private func requireFacadeDeadline(
    _ deadline: VoicePerformanceContinuousDeadline
) throws {
    guard try !deadline.isExpired() else {
        throw VoicePerformanceTracerHelperConnectionError.timedOut
    }
}

#endif
