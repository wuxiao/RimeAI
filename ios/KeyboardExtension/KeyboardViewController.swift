import UIKit

private final class WeightedKeyRowView: UIView {
    private let buttons: [UIButton]
    private let weights: [CGFloat]
    private let spacing: CGFloat

    init(
        buttons: [UIButton],
        weights: [CGFloat],
        spacing: CGFloat
    ) {
        precondition(!buttons.isEmpty)
        precondition(buttons.count == weights.count)
        precondition(weights.allSatisfy { $0 > 0 })
        self.buttons = buttons
        self.weights = weights
        self.spacing = spacing
        super.init(frame: .zero)
        semanticContentAttribute = .forceLeftToRight
        for button in buttons {
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let totalSpacing = spacing * CGFloat(buttons.count - 1)
        let availableWidth = max(0, bounds.width - totalSpacing)
        let totalWeight = weights.reduce(0, +)
        let scale = window?.screen.scale ?? UIScreen.main.scale
        var x: CGFloat = 0

        for (index, button) in buttons.enumerated() {
            let width: CGFloat
            if index == buttons.indices.last {
                width = max(0, bounds.width - x)
            } else {
                let proportionalWidth =
                    availableWidth * weights[index] / totalWeight
                width = (proportionalWidth * scale).rounded() / scale
            }
            button.frame = CGRect(
                x: x,
                y: 0,
                width: width,
                height: bounds.height
            )
            x += width + spacing
        }
    }
}

final class KeyboardViewController: UIInputViewController {
    private let engine = RimeKeyboardEngine()
    private let rootStack = UIStackView()
    private let statusLabel = UILabel()
    private let compositionLabel = UILabel()
    private let candidateStack = UIStackView()
    private var heightConstraint: NSLayoutConstraint?
    private var composition = ""
    private var requestRevision = 0
    private var isEngineReady = false
    private var engineVersion = "unknown"
    private var semanticRanker: LocalSemanticRanker?
    private var semanticModelFailure: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureRootView()
        buildKeyboard()
        updateAppearance()
        loadSemanticRanker()
        startEngine()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        heightConstraint?.isActive = false
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 300)
        heightConstraint?.priority = .defaultHigh
        heightConstraint?.isActive = true
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateAppearance()
    }

    private func configureRootView() {
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.distribution = .fill
        rootStack.spacing = 7
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 6
            ),
            rootStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -6
            ),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            rootStack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -7
            ),
        ])
    }

    private func buildKeyboard() {
        rootStack.addArrangedSubview(makeStatusView())
        rootStack.addArrangedSubview(makeCandidateView())

        let keyRows = UIStackView()
        keyRows.axis = .vertical
        keyRows.alignment = .fill
        keyRows.distribution = .fillEqually
        keyRows.spacing = 7

        for row in ["qwertyuiop", "asdfghjkl", "zxcvbnm"] {
            keyRows.addArrangedSubview(
                makeRow(
                    Array(row).map { character in
                        makeLetterKey(String(character))
                    }
                )
            )
        }
        keyRows.addArrangedSubview(makeFunctionRow())
        rootStack.addArrangedSubview(keyRows)
    }

    private func makeStatusView() -> UIView {
        statusLabel.text = "正在准备离线 librime…"
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.textColor = .secondaryLabel
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityLabel = "RimeAI 状态"
        statusLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return statusLabel
    }

    private func makeCandidateView() -> UIView {
        compositionLabel.text = "输入拼音"
        compositionLabel.font = .preferredFont(forTextStyle: .callout)
        compositionLabel.textColor = .secondaryLabel
        compositionLabel.setContentHuggingPriority(.required, for: .horizontal)
        compositionLabel.accessibilityLabel = "当前拼音"

        candidateStack.axis = .horizontal
        candidateStack.alignment = .fill
        candidateStack.distribution = .fill
        candidateStack.spacing = 6

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.addSubview(candidateStack)
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor
            ),
            candidateStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor
            ),
            candidateStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor
            ),
            candidateStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor
            ),
            candidateStack.heightAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.heightAnchor
            ),
        ])

        let row = UIStackView(arrangedSubviews: [compositionLabel, scrollView])
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fill
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return row
    }

    private func makeRow(
        _ buttons: [UIButton],
        weights: [CGFloat]? = nil
    ) -> UIView {
        WeightedKeyRowView(
            buttons: buttons,
            weights: weights ?? Array(repeating: 1, count: buttons.count),
            spacing: 5
        )
    }

    private func makeFunctionRow() -> UIView {
        let globe = makeFunctionKey(
            systemImageName: "globe",
            accessibilityLabel: "下一个键盘"
        )
        globe.addTarget(
            self,
            action: #selector(handleInputModeList(from:with:)),
            for: .allTouchEvents
        )

        let delete = makeFunctionKey(
            systemImageName: "delete.left",
            accessibilityLabel: "删除"
        )
        delete.addAction(
            UIAction { [weak self] _ in
                self?.handleDelete()
            },
            for: .touchUpInside
        )

        let space = makeFunctionKey(
            title: "空格",
            accessibilityLabel: "空格"
        )
        space.addAction(
            UIAction { [weak self] _ in
                self?.handleSpace()
            },
            for: .touchUpInside
        )

        let enter = makeFunctionKey(
            systemImageName: "return",
            accessibilityLabel: "换行"
        )
        enter.addAction(
            UIAction { [weak self] _ in
                self?.handleEnter()
            },
            for: .touchUpInside
        )

        return makeRow(
            [globe, delete, space, enter],
            weights: [1, 1, 2.5, 1]
        )
    }

    private func makeLetterKey(_ letter: String) -> UIButton {
        let button = makeFunctionKey(
            title: letter,
            accessibilityLabel: letter
        )
        button.addAction(
            UIAction { [weak self] _ in
                self?.appendLetter(letter)
            },
            for: .touchUpInside
        )
        return button
    }

    private func makeFunctionKey(
        title: String? = nil,
        systemImageName: String? = nil,
        accessibilityLabel: String
    ) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        if let systemImageName {
            configuration.image = UIImage(systemName: systemImageName)
            configuration.preferredSymbolConfigurationForImage =
                UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        }
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = .secondarySystemBackground
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: 2,
            bottom: 0,
            trailing: 2
        )
        configuration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 18, weight: .medium)
                return outgoing
            }

        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = accessibilityLabel
        button.clipsToBounds = true
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        button.setContentCompressionResistancePriority(
            .fittingSizeLevel,
            for: .horizontal
        )
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.75
        button.titleLabel?.lineBreakMode = .byClipping
        button.titleLabel?.textAlignment = .center
        button.imageView?.contentMode = .scaleAspectFit
        return button
    }

    private func makeCandidateButton(
        _ candidate: RimeKeyboardCandidate
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = candidate.text
        configuration.subtitle = candidate.comment
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 2,
            leading: 8,
            bottom: 2,
            trailing: 8
        )
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = candidate.text
        button.addAction(
            UIAction { [weak self] _ in
                self?.commit(candidateIndex: candidate.index)
            },
            for: .touchUpInside
        )
        return button
    }

    func makeSemanticButton(
        evaluation: LocalSemanticEvaluation,
        candidates: [RimeKeyboardCandidate]
    ) -> UIButton {
        let presentation = evaluation.candidatePresentation
        var configuration = UIButton.Configuration.tinted()
        configuration.title = presentation.title
        configuration.baseForegroundColor = .systemIndigo
        configuration.baseBackgroundColor = .systemIndigo
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 2,
            leading: 8,
            bottom: 2,
            trailing: 8
        )
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "local-semantic-candidate-state"
        button.accessibilityLabel = presentation.title
        let original = evaluation.candidate.flatMap { candidate in
            candidates.first(where: { $0.text == candidate })
        }
        let isActionable = presentation.isSelectable && original != nil
        button.isEnabled = isActionable
        button.alpha = isActionable ? 1 : 0.74
        if let original, isActionable {
            button.addAction(
                UIAction { [weak self] _ in
                    self?.commit(candidateIndex: original.index)
                },
                for: .touchUpInside
            )
        }
        return button
    }

    private func loadSemanticRanker() {
        let bundles = [Bundle(for: Self.self), .main]
        let modelURL = bundles.lazy.compactMap { bundle in
            bundle.url(
                forResource: "rimeai-p0-ngram-v1",
                withExtension: "bin",
                subdirectory: "SemanticModel"
            ) ?? bundle.url(
                forResource: "rimeai-p0-ngram-v1",
                withExtension: "bin"
            )
        }.first
        guard let modelURL else {
            semanticModelFailure = "P0 本地模型资源缺失"
            return
        }
        do {
            semanticRanker = try LocalSemanticRanker(contentsOf: modelURL)
            semanticModelFailure = nil
        } catch {
            semanticModelFailure = error.localizedDescription
        }
    }

    private func startEngine() {
        engine.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                switch result {
                case let .success(version):
                    self.isEngineReady = true
                    self.engineVersion = version
                    self.statusLabel.text = self.readinessDescription()
                    self.refreshCandidates()
                case let .failure(error):
                    self.statusLabel.text =
                        "librime 启动失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func appendLetter(_ letter: String) {
        composition.append(letter)
        refreshCandidates()
    }

    private func handleDelete() {
        guard !composition.isEmpty else {
            textDocumentProxy.deleteBackward()
            return
        }
        composition.removeLast()
        refreshCandidates()
    }

    private func handleSpace() {
        guard !composition.isEmpty else {
            textDocumentProxy.insertText(" ")
            return
        }
        commit(candidateIndex: 0)
    }

    private func handleEnter() {
        guard !composition.isEmpty else {
            textDocumentProxy.insertText("\n")
            return
        }
        commit(candidateIndex: 0)
    }

    private func refreshCandidates() {
        requestRevision += 1
        let revision = requestRevision
        compositionLabel.text = composition.isEmpty ? "输入拼音" : composition
        removeCandidates()

        guard !composition.isEmpty, isEngineReady else {
            statusLabel.text = readinessDescription()
            return
        }
        let requestedComposition = composition
        engine.candidates(for: requestedComposition) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      revision == self.requestRevision,
                      requestedComposition == self.composition
                else {
                    return
                }
                switch result {
                case let .success(candidates):
                    if let ranker = self.semanticRanker {
                        let context = String(
                            (self.textDocumentProxy.documentContextBeforeInput ?? "")
                                .suffix(40)
                        )
                        let evaluation = ranker.evaluate(
                            context: context,
                            candidates: candidates.map(\.text)
                        )
                        self.candidateStack.addArrangedSubview(
                            self.makeSemanticButton(
                                evaluation: evaluation,
                                candidates: candidates
                            )
                        )
                    } else {
                        let unavailable = LocalSemanticEvaluation(
                            decision: .noCandidate,
                            candidate: nil,
                            confidence: 0
                        )
                        let button = self.makeSemanticButton(
                            evaluation: unavailable,
                            candidates: candidates
                        )
                        button.configuration?.title = "✦ 本地模型不可用"
                        button.accessibilityLabel = "✦ 本地模型不可用"
                        self.candidateStack.addArrangedSubview(button)
                    }
                    for candidate in candidates {
                        self.candidateStack.addArrangedSubview(
                            self.makeCandidateButton(candidate)
                        )
                    }
                    self.statusLabel.text = self.candidateStatusDescription(
                        count: candidates.count
                    )
                case let .failure(error):
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
    }

    private func readinessDescription() -> String {
        if let semanticModelFailure {
            return "librime \(engineVersion) · \(semanticModelFailure) · 离线"
        }
        guard let semanticRanker else {
            return "librime \(engineVersion) · P0 本地模型未加载 · 离线"
        }
        return "librime \(engineVersion) · \(semanticRanker.artifactID) · 离线"
    }

    private func candidateStatusDescription(count: Int) -> String {
        let modelStatus = semanticRanker == nil ? "模型回退" : "P0 模型已评估"
        return "librime \(engineVersion) · \(count) 个候选 · \(modelStatus) · 离线"
    }

    private func commit(candidateIndex: Int) {
        guard !composition.isEmpty, isEngineReady else {
            return
        }
        let requestedComposition = composition
        engine.commit(
            pinyin: requestedComposition,
            candidateIndex: candidateIndex
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      requestedComposition == self.composition
                else {
                    return
                }
                switch result {
                case let .success(text):
                    self.textDocumentProxy.insertText(text)
                    self.composition = ""
                    self.refreshCandidates()
                case let .failure(error):
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
    }

    private func removeCandidates() {
        for view in candidateStack.arrangedSubviews {
            candidateStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func updateAppearance() {
        let isDark =
            textDocumentProxy.keyboardAppearance == .dark
            || traitCollection.userInterfaceStyle == .dark
        view.backgroundColor =
            isDark
            ? UIColor(white: 0.08, alpha: 1)
            : UIColor(white: 0.92, alpha: 1)
    }
}
