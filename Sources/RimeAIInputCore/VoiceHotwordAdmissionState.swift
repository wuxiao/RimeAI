import Foundation

/// Identifies one input-controller focus session. Hotwords never cross any of
/// these three boundaries.
public struct VoiceHotwordAdmissionSession: Hashable, Sendable {
    public let applicationIdentifier: String
    public let controllerSessionIdentifier: String
    public let focusEpoch: UInt64

    public init(
        applicationIdentifier: String,
        controllerSessionIdentifier: String,
        focusEpoch: UInt64
    ) {
        self.applicationIdentifier = applicationIdentifier
        self.controllerSessionIdentifier = controllerSessionIdentifier
        self.focusEpoch = focusEpoch
    }
}

/// Complete, explicit privacy policy for admitting ephemeral Rime commits as
/// voice hotwords. Hotword assistance is independent of the voice master
/// switch so callers cannot enable it merely by enabling dictation.
public struct VoiceHotwordAdmissionPolicy: Equatable, Sendable {
    public let isVoiceEnabled: Bool
    public let isAIAllowed: Bool
    public let isHotwordAssistEnabled: Bool
    public let contextPolicy: ContextPolicy
    public let isSecureInput: Bool

    public init(
        isVoiceEnabled: Bool,
        isAIAllowed: Bool,
        isHotwordAssistEnabled: Bool,
        contextPolicy: ContextPolicy,
        isSecureInput: Bool
    ) {
        self.isVoiceEnabled = isVoiceEnabled
        self.isAIAllowed = isAIAllowed
        self.isHotwordAssistEnabled = isHotwordAssistEnabled
        self.contextPolicy = contextPolicy
        self.isSecureInput = isSecureInput
    }

    fileprivate var allowsHotwords: Bool {
        isVoiceEnabled
            && isAIAllowed
            && isHotwordAssistEnabled
            && contextPolicy != .strict
            && !isSecureInput
    }
}

/// Pure, in-memory admission state for the bounded MRU sent to the voice
/// helper. It never reads Rime userdb/history and has no persistence surface.
public struct VoiceHotwordAdmissionState: Equatable, Sendable {
    private var activeSession: VoiceHotwordAdmissionSession?
    private var activePolicy: VoiceHotwordAdmissionPolicy?
    private var phrases: [String] = []

    public init() {}

    public mutating func activate(
        session: VoiceHotwordAdmissionSession,
        policy: VoiceHotwordAdmissionPolicy
    ) {
        if activeSession != session {
            phrases.removeAll(keepingCapacity: true)
        }
        activeSession = session
        activePolicy = policy
        if !policy.allowsHotwords {
            phrases.removeAll(keepingCapacity: false)
        }
    }

    public mutating func updatePolicy(
        _ policy: VoiceHotwordAdmissionPolicy
    ) {
        activePolicy = policy
        if !policy.allowsHotwords {
            phrases.removeAll(keepingCapacity: false)
        }
    }

    /// Accepts the actual optional result returned by Rime. `nil` is an
    /// unsuccessful commit and therefore cannot enter the hotword set.
    public mutating func recordRimeCommitResult(
        _ committedText: String?,
        matching expectedText: String? = nil,
        session: VoiceHotwordAdmissionSession
    ) {
        guard activeSession == session,
              activePolicy?.allowsHotwords == true,
              let committedText,
              expectedText.map({ $0 == committedText }) ?? true,
              let single = try? VoiceHotwordSnapshot(phrases: [committedText]),
              let normalized = single.phrases.first
        else {
            return
        }
        phrases.removeAll { $0 == normalized }
        phrases.insert(normalized, at: 0)
        if phrases.count > VoiceDictationConstants.maximumHotwordCount {
            phrases.removeLast(
                phrases.count - VoiceDictationConstants.maximumHotwordCount
            )
        }
    }

    public func snapshot(
        session: VoiceHotwordAdmissionSession
    ) -> VoiceHotwordSnapshot {
        guard activeSession == session,
              activePolicy?.allowsHotwords == true
        else {
            return .empty
        }
        return (try? VoiceHotwordSnapshot(phrases: phrases)) ?? .empty
    }

    public mutating func deactivate() {
        activeSession = nil
        activePolicy = nil
        phrases.removeAll(keepingCapacity: false)
    }

    public mutating func enterSecureInput() {
        activePolicy = nil
        phrases.removeAll(keepingCapacity: false)
    }

    public mutating func clear() {
        phrases.removeAll(keepingCapacity: false)
    }
}
