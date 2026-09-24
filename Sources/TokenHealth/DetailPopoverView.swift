import SwiftUI

/// 钉住项的详情浮层。只展示，不可交互 —— 筛选、日期范围、下钻都留给厂商的控制台。
struct DetailPopoverView: View {
    let serviceName: String
    let detail: UsageDetail?
    let statusMessage: String?
    let updatedAt: Date?
    let onRefresh: () -> Void
    let onUnpin: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let detail, !detail.isEmpty {
                sections(detail)
            } else {
                Text(emptyStateText)
                    .font(.caption)
                    .foregroundStyle(statusMessage == nil ? Color.secondary : Color.red)
            }
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320)
    }

    /// 「还没有快照」与「快照不可用」是两回事：前者在等第一次取数，后者是取数失败了。
    private var emptyStateText: String {
        if let statusMessage {
            return statusMessage
        }
        return updatedAt == nil ? "Loading…" : "No usage to show"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(serviceName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let updatedAt {
                    Text(StatusMenuSummary.relativeAge(from: updatedAt, now: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh", action: onRefresh)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            // 有旧数据时的错误行：数字照常展示，错误挂在顶上。
            if let statusMessage, detail?.isEmpty == false {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func sections(_ detail: UsageDetail) -> some View {
        if !detail.headline.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(detail.headline) { stat in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(stat.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(stat.value)
                            .font(.title3.monospacedDigit())
                    }
                }
            }
        }

        ForEach(detail.groups) { group in
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 最后一个值是花费，靠右；其余依次横排，每个都带上自己的标签 ——
                    // 光有数字「6 · 240」是读不懂的。
                    ForEach(Array(group.values.dropLast().enumerated()), id: \.element.id) { index, stat in
                        if index > 0 {
                            Text("·").font(.caption).foregroundStyle(.tertiary)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(stat.label).font(.caption2).foregroundStyle(.secondary)
                            Text(stat.value).font(.caption.monospacedDigit())
                        }
                    }
                    Spacer(minLength: 8)
                    if let cost = group.values.last {
                        Text(cost.value).font(.caption.monospacedDigit())
                    }
                }
            }
        }

        if let series = detail.series {
            VStack(alignment: .leading, spacing: 4) {
                Text(series.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if DetailSeriesChart.maximum(of: series.points) == 0 {
                    Text("No usage this month")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    chart(series)
                    HStack {
                        Text(series.axisStart)
                        Spacer()
                        Text(series.axisEnd)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }

        if !detail.breakdown.isEmpty {
            HStack(alignment: .top, spacing: 14) {
                ForEach(detail.breakdown) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.label).font(.caption2).foregroundStyle(.secondary)
                        Text(stat.value).font(.caption.monospacedDigit())
                    }
                }
            }
        }

        if let table = detail.table {
            VStack(alignment: .leading, spacing: 4) {
                Text(table.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                // 列名：首列是模型名，其余与 cells 一一对应。没有它，
                // 「980 / 14.2M / 31.20 CNY」得靠读者自己猜哪列是次数。
                HStack(spacing: 8) {
                    Text(table.columns.first ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 6)
                    ForEach(Array(table.columns.dropFirst().enumerated()), id: \.offset) { _, column in
                        Text(column)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 46, alignment: .trailing)
                    }
                }
                ForEach(table.rows) { row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 46, alignment: .trailing)
                        }
                    }
                }
                if let footnote = table.footnote {
                    Text(footnote).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 自己画的迷你柱状图：柱高由纯计算的 `DetailSeriesChart` 给出。
    private func chart(_ series: DetailSeries) -> some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 1
            let count = max(series.points.count, 1)
            let barWidth = max(1, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let heights = DetailSeriesChart.heights(
                points: series.points,
                maxHeight: proxy.size.height,
                minimumVisibleHeight: 1.5
            )
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(zip(series.points, heights)), id: \.0.id) { _, height in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(height: 44)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Unpin", action: onUnpin)
            Button("Settings", action: onOpenSettings)
            Spacer()
            Button("Quit", action: onQuit)
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}
