import AppKit

/// 近 7 日语音使用量迷你柱状图（自绘，无第三方依赖）。
/// 今天用强调色，其余半透明；没有任何数据时显示空状态文案。
@MainActor
final class VoiceUsageBarChartView: NSView {
    enum Metric: Equatable {
        case sessions
        case characters

        var title: String {
            switch self {
            case .sessions:
                return "次数"
            case .characters:
                return "字数"
            }
        }
    }

    struct Entry: Equatable {
        let dayKey: String
        let weekdayLabel: String
        let isToday: Bool
        let sessions: Int
        let characters: Int
    }

    static let preferredHeight: CGFloat = 96
    private static let days = 7
    private static let horizontalPadding: CGFloat = 6
    static let emptyText = "近 7 日暂无语音记录"

    private(set) var entries: [Entry] = []
    var metric: Metric = .sessions {
        didSet {
            guard metric != oldValue else {
                return
            }
            needsDisplay = true
            updateAccessibility()
        }
    }

    override var isFlipped: Bool {
        false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    /// 用使用统计中的每日趋势填充最近 7 天；缺失的日期补零。
    func update(
        dailyTrend: [VoiceDailyUsageStat],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let byKey = Dictionary(dailyTrend.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale.current
        formatter.dateFormat = "E"
        let todayKey = VoiceHistoryStore.dayKey(for: now, calendar: calendar)
        entries = (0 ..< Self.days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else {
                return nil
            }
            let key = VoiceHistoryStore.dayKey(for: date, calendar: calendar)
            let stat = byKey[key]
            return Entry(
                dayKey: key,
                weekdayLabel: formatter.string(from: date),
                isToday: key == todayKey,
                sessions: stat?.sessionCount ?? 0,
                characters: stat?.characterCount ?? 0
            )
        }
        needsDisplay = true
        updateAccessibility()
    }

    var isEmpty: Bool {
        entries.allSatisfy { $0.sessions == 0 && $0.characters == 0 }
    }

    private func value(for entry: Entry) -> Int {
        switch metric {
        case .sessions:
            return entry.sessions
        case .characters:
            return entry.characters
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isEmpty, !entries.isEmpty else {
            drawEmptyState()
            return
        }
        let width = bounds.width
        let height = bounds.height
        let topInset: CGFloat = 16
        let bottomInset: CGFloat = 18
        let plotHeight = max(0, height - topInset - bottomInset)
        let count = CGFloat(entries.count)
        let gap: CGFloat = 8
        let barWidth = max(
            8,
            (width - Self.horizontalPadding * 2 - gap * (count - 1)) / count
        )
        let maxValue = max(1, entries.map(value).max() ?? 1)

        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        for (index, entry) in entries.enumerated() {
            let barX = Self.horizontalPadding + CGFloat(index) * (barWidth + gap)
            let barHeight = plotHeight * CGFloat(value(for: entry)) / CGFloat(maxValue)
            let barRect = NSRect(
                x: barX,
                y: bottomInset,
                width: barWidth,
                height: max(barHeight.isZero ? 0 : 3, barHeight)
            )
            let path = NSBezierPath(
                roundedRect: barRect.insetBy(dx: 2, dy: 0),
                xRadius: 3,
                yRadius: 3
            )
            let accent = NSColor.controlAccentColor
            (entry.isToday ? accent : accent.withAlphaComponent(0.45)).setFill()
            path.fill()

            let valueText = "\(value(for: entry))"
            let valueSize = (valueText as NSString).size(withAttributes: valueAttributes)
            (valueText as NSString).draw(
                at: NSPoint(
                    x: barRect.midX - valueSize.width / 2,
                    y: bottomInset + barRect.height + 3
                ),
                withAttributes: valueAttributes
            )
            let label = entry.weekdayLabel as NSString
            let labelSize = label.size(withAttributes: labelAttributes)
            label.draw(
                at: NSPoint(
                    x: barRect.midX - labelSize.width / 2,
                    y: 3
                ),
                withAttributes: labelAttributes
            )
        }
    }

    private func drawEmptyState() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let text = Self.emptyText as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func updateAccessibility() {
        setAccessibilityLabel("近 7 日语音\(metric.title)柱状图")
        if isEmpty {
            setAccessibilityValue(Self.emptyText)
            return
        }
        setAccessibilityValue(
            entries
                .map { "\($0.weekdayLabel) \(value(for: $0))" }
                .joined(separator: "，")
        )
    }
}
