import AppKit
import InputMethodKit

/// 候选面板渲染与光标锚点几何。
extension RimeAIInputController {
    /// LM-002 对比行：主槽为整句建议时，给出异源快照（本地槽→云端，
    /// 云端槽→本地）；其余形态不展示对比。
    private func comparisonLineForPanel()
        -> CandidatePanelController.Content.ComparisonLine? {
        guard case let .candidate(_, decision, _) = pipeline.presentation,
              decision == .sentenceSuggestion
        else {
            return nil
        }
        let cloudSources: Set<HistoryCommitSource> = [
            .cloudGenerated, .cloudExact, .cloudFuzzy,
        ]
        if cloudSources.contains(pipeline.historySource) {
            return pipeline.localComparisonSuggestion.map {
                .init(label: "local", text: $0)
            }
        }
        return pipeline.cloudComparisonSuggestion.map {
            .init(label: "cloud", text: $0)
        }
    }

    func renderCandidatePanel(client: any IMKTextInput) {
        let pageOffset = composition.candidatePage
            * CompositionState.candidatesPerPage
        candidatePanel.update(
            content: .init(
                visibleCandidates: composition.visibleMainCandidates,
                primaryCandidate: composition.mainCandidates.first,
                pageLabel: composition.candidatePageCount > 1
                    ? "\(composition.candidatePage + 1)/\(composition.candidatePageCount)"
                    : nil,
                semanticPresentation: pipeline.presentation,
                suggestionSource: pipeline.historySource,
                contextCharacterCount: pipeline.contextCharacterCount,
                cloudInFlight: pipeline.cloudInFlight,
                neuralLateApplied: pipeline.neuralLateApplied,
                comparisonLine: comparisonLineForPanel()
            ),
            onMainSelection: { [weak self] localIndex in
                guard let self,
                      let client = self.activeClientObject
                        as? any IMKTextInput
                else {
                    return
                }
                self.selectMainCandidate(
                    index: pageOffset + localIndex,
                    client: client
                )
            },
            onSemanticSelection: { [weak self] in
                guard let self,
                      let candidate = self.composition.semanticCandidate,
                      let client = self.activeClientObject
                        as? any IMKTextInput
                else {
                    return
                }
                self.selectSemanticCandidate(candidate, client: client)
            },
            onComparisonSelection: { [weak self] candidate in
                guard let self,
                      let client = self.activeClientObject
                        as? any IMKTextInput
                else {
                    return
                }
                self.selectSemanticCandidate(candidate, client: client)
            }
        )
        candidatePanel.show(anchorRect: cursorAnchorRect(
            client: client,
            characterIndex: 0
        ))
    }

    /// 面板刷新：只要有正在编辑的内容（含仅前缀态）都允许重绘；
    /// 面板自身按可见内容决定显示或隐藏。
    func refreshCandidatePanelIfActive() {
        guard let client = activeClientObject as? any IMKTextInput,
              composition.hasComposition
        else {
            return
        }
        renderCandidatePanel(client: client)
    }

    func cursorAnchorRect(
        client: any IMKTextInput,
        characterIndex: Int
    ) -> NSRect {
        var cursorRect = NSRect.zero
        _ = client.attributes(
            forCharacterIndex: max(0, characterIndex),
            lineHeightRectangle: &cursorRect
        )
        if cursorRect.isEmpty {
            cursorRect = NSRect(
                origin: NSEvent.mouseLocation,
                size: NSSize(width: 1, height: 20)
            )
        }
        return cursorRect
    }

    func voiceCaretRect(
        client: any IMKTextInput,
        characterIndex: Int
    ) -> NSRect? {
        var caretRect = NSRect.zero
        _ = client.attributes(
            forCharacterIndex: max(0, characterIndex),
            lineHeightRectangle: &caretRect
        )
        guard !caretRect.isEmpty,
              caretRect.origin.x.isFinite,
              caretRect.origin.y.isFinite,
              caretRect.size.width.isFinite,
              caretRect.size.height.isFinite
        else {
            return nil
        }
        return caretRect
    }
}
