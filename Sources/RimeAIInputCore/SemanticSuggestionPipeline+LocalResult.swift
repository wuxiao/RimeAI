import Foundation

/// 本地 daemon 结果应用：请求消费、冻结守卫梯（pending request id →
/// secure input → cloud ownership → status/token/structure）与展示/
/// 应用落点。守卫语义与拆分前一致，仅按 lint 边界拆分为阶梯判定、
/// 展示分派与候选应用三个函数。
extension SemanticSuggestionPipeline {
    /// Apply a local daemon result. Guard ladder: pending request id →
    /// secure input → cloud ownership → status/token/structure. After the
    /// ladder resolves, an empty slot may still be filled by the L1
    /// phrasebook fallback.
    public func applyInferenceResult(
        _ result: SemanticInferenceResult?,
        requestID: String,
        token: CompositionToken
    ) {
        applyLocalResult(result, requestID: requestID, token: token)
        tryPhraseBookFill()
    }

    /// 守卫梯结论：proceed 进入展示/应用；terminal 直接落展示态。
    private enum LocalResultGateOutcome {
        case proceed(SemanticInferenceResult)
        case terminal(SemanticCandidatePresentation, RimeAIDiagnosticEvent?)
    }

    /// 消费在途请求槽（latest-request-wins）：迟到响应计入 stale。
    /// 返回清空的 startedAt（供延迟采样）与请求段布局。
    private func consumePendingLocalResult(
        requestID: String
    ) -> (startedAt: TimeInterval?, segments: [PinyinSegment]?)? {
        guard pendingRequestID == requestID else {
            return nil
        }
        pendingRequestID = nil
        let startedAt = pendingRequestStartedAt
        let segments = pendingRequestSegments
        pendingRequestStartedAt = nil
        pendingRequestSegments = nil
        return (startedAt, segments)
    }

    private func applyLocalResult(
        _ result: SemanticInferenceResult?,
        requestID: String,
        token: CompositionToken
    ) {
        guard let consumed = consumePendingLocalResult(requestID: requestID)
        else {
            emit(.diagnostic(.staleResult))
            return
        }
        if let startedAt = consumed.startedAt {
            emit(.latency(milliseconds: max(
                0,
                (
                    dependencies.now()
                        - startedAt
                ) * 1_000
            )))
        }
        guard !dependencies.isSecureEventInputEnabled() else {
            emit(.secureInputDetected)
            return
        }
        if cloudSuggestionApplied {
            // A valid cloud decision owns the single explicit suggestion
            // slot.
            return
        }
        switch gateLocalResult(
            result,
            token: token,
            requestSegments: consumed.segments
        ) {
        case let .terminal(presentationState, diagnostic):
            if let diagnostic {
                emit(.diagnostic(diagnostic))
            }
            presentation = presentationState
            emit(.suggestionSlotChanged)
        case let .proceed(validResult):
            presentLocalCandidate(
                validResult,
                requestSegments: consumed.segments,
                token: token
            )
        }
    }

    /// 守卫梯：结果存在性 → status → token 匹配 → 结构校验。
    private func gateLocalResult(
        _ result: SemanticInferenceResult?,
        token: CompositionToken,
        requestSegments: [PinyinSegment]?
    ) -> LocalResultGateOutcome {
        guard let result else {
            return .terminal(.failure, .daemonFailure)
        }
        guard result.status == "ok" else {
            if result.status == "timeout" {
                return .terminal(.failure, .timeout)
            } else if result.status == "circuit_open" {
                return .terminal(.failure, .circuitOpen)
            } else {
                return .terminal(.failure, .daemonFailure)
            }
        }
        guard result.matches(token) else {
            return .terminal(.idle, .staleResult)
        }
        guard result.isValid(
            for: token,
            candidates: composition.mainCandidates,
            segments: requestSegments
        ) else {
            return .terminal(.failure, .invalidResult)
        }
        return .proceed(result)
    }

    /// 展示分派：均匀落点态（诊断+槽位刷新）直接收敛；scriptMismatch
    /// 走字形回退，`.candidate` 落到候选应用尾部。
    private func presentLocalCandidate(
        _ result: SemanticInferenceResult,
        requestSegments: [PinyinSegment]?,
        token: CompositionToken
    ) {
        let candidatePresentation = result.candidatePresentation(
            characterSet: dependencies.characterSet()
        )
        presentation = candidatePresentation
        if let diagnostic = Self.uniformTerminalDiagnostic(
            candidatePresentation
        ) {
            emit(.diagnostic(diagnostic))
            emit(.suggestionSlotChanged)
            return
        }
        switch candidatePresentation {
        case .scriptMismatch:
            applyScriptMismatchFallback(
                result,
                requestSegments: requestSegments,
                token: token
            )
            return
        case .sameTopCandidate,
             .insufficientCandidates,
             .belowConfidence,
             .noCandidate,
             .sentenceTooLong,
             .sentenceIncomplete,
             .inputTooLong:
            // 已被均匀落点分支处理；防御性收敛（不可达）。
            emit(.suggestionSlotChanged)
            return
        case .idle,
             .analyzing,
             .cloudAnalyzing,
             .cloudSameTopCandidate,
             .cloudBelowConfidence,
             .cloudFailure,
             .continuation,
             .unavailable,
             .failure:
            emit(.diagnostic(.invalidResult))
            presentation = .failure
            emit(.suggestionSlotChanged)
            return
        case .candidate:
            break
        }
        applyRankedOrSentenceCandidate(
            result,
            requestSegments: requestSegments,
            token: token
        )
    }

    /// 均匀落点展示态 → 诊断事件映射（保持展示态、发诊断、刷新槽
    /// 位）；返回 nil 表示需要专属处理。
    private static func uniformTerminalDiagnostic(
        _ state: SemanticCandidatePresentation
    ) -> RimeAIDiagnosticEvent? {
        switch state {
        case .sameTopCandidate:
            return .sameTopCandidate
        case .insufficientCandidates:
            return .insufficientCandidates
        case .belowConfidence:
            return .belowConfidence
        case .noCandidate:
            return .noCandidate
        case .sentenceTooLong:
            return .sentenceTooLong
        case .sentenceIncomplete:
            return .sentenceIncomplete
        case .inputTooLong:
            return .inputTooLong
        default:
            return nil
        }
    }

    /// 字形不符不再静默丢弃：就地转换为用户设置的字形后照常展示
    /// （繁体整句转简体），仅无法转换时才拒绝。
    private func applyScriptMismatchFallback(
        _ result: SemanticInferenceResult,
        requestSegments: [PinyinSegment]?,
        token: CompositionToken
    ) {
        if let decision = result.resolvedDecision,
           let sanitized = SemanticCandidateScriptPolicy.sanitized(
               text: result.displayCandidate,
               characterSet: dependencies.characterSet()
           ),
           dependencies.applySemanticCandidate(
               sanitized,
               token,
               decision,
               requestSegments
           )
        {
            presentation = .candidate(
                text: sanitized,
                decision: decision,
                confidence: result.confidence ?? 0
            )
            historySource = .localSemantic
            cloudCandidate = nil
            emit(.diagnostic(.resultShown))
            emit(.suggestionSlotChanged)
            return
        }
        emit(.diagnostic(.sentenceScriptMismatch))
        emit(.suggestionSlotChanged)
    }

    /// 候选应用尾部：重排候选或整句建议写入语义建议槽。
    private func applyRankedOrSentenceCandidate(
        _ result: SemanticInferenceResult,
        requestSegments: [PinyinSegment]?,
        token: CompositionToken
    ) {
        let candidate = result.displayCandidate
        guard let decision = result.resolvedDecision else {
            emit(.diagnostic(.invalidResult))
            presentation = .failure
            emit(.suggestionSlotChanged)
            return
        }
        guard !candidate.isEmpty,
              !candidate.contains("\n"),
              dependencies.applySemanticCandidate(
                  candidate,
                  token,
                  decision,
                  requestSegments
              )
        else {
            emit(.diagnostic(.invalidResult))
            presentation = .failure
            emit(.suggestionSlotChanged)
            return
        }
        historySource = .localSemantic
        cloudCandidate = nil
        emit(.diagnostic(.resultShown))
        if decision == .sentenceSuggestion {
            emit(.diagnostic(.sentenceSuggestionShown))
        } else {
            emit(.diagnostic(.rankedCandidateShown))
        }
        emit(.suggestionSlotChanged)
    }

    // MARK: - 异步神经整句迟到帧（LM-001 双延迟档神经臂）

    /// 应用 daemon 迟到帧：同步 n-gram 句建议先出，神经整句 100-300ms
    /// 后到达同一建议位。守卫梯：期望槽匹配 → 活组合令牌未推进
    /// （击键/选词会推进 revision，旧帧即 stale）→ Secure Input →
    /// 云端所有权 → 结构门。拼音正确性由 worker 端拼音掩码与终门
    /// 保证（约束解码合同），客户端不重复拼音校验。
    public func applyNeuralSentenceLate(_ frame: DaemonSentenceLateFrame) {
        guard neuralLateRequestID == frame.requestID,
              let expectedToken = neuralLateToken,
              frame.matches(expectedToken)
        else {
            emit(.diagnostic(.staleResult))
            return
        }
        // 一次性消费：同帧不重复应用。
        neuralLateRequestID = nil
        neuralLateToken = nil
        neuralLateSegments = nil
        guard composition.token == expectedToken else {
            emit(.diagnostic(.staleResult))
            return
        }
        guard !dependencies.isSecureEventInputEnabled() else {
            emit(.secureInputDetected)
            return
        }
        guard !cloudSuggestionApplied, frame.isValid else {
            return
        }
        let result = frame.asInferenceResult()
        let segments = neuralLateSegments
        let candidatePresentation = result.candidatePresentation(
            characterSet: dependencies.characterSet()
        )
        guard case let .candidate(text, decision, confidence) =
            candidatePresentation
        else {
            // 字形不符等终端态：迟到帧静默丢弃，保持既有展示。
            emit(.suggestionSlotChanged)
            return
        }
        guard dependencies.applySemanticCandidate(
            text,
            expectedToken,
            decision,
            segments
        ) else {
            emit(.diagnostic(.invalidResult))
            return
        }
        presentation = .candidate(
            text: text,
            decision: decision,
            confidence: confidence
        )
        historySource = .localSemantic
        cloudCandidate = nil
        emit(.diagnostic(.resultShown))
        emit(.diagnostic(.sentenceSuggestionShown))
        emit(.suggestionSlotChanged)
    }
}
