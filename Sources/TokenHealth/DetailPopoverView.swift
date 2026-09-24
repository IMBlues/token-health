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

        // 「Today」「This month」排成一张表：行是时间范围，列是 Requests / Tokens / Cost，
        // 同一列在所有行里对齐。做成流水式的一行行文字，两行的数字会各自起头、读起来像散句。
        if let firstGroup = detail.groups.first, !firstGroup.values.isEmpty {
            // 显式 .leading：Grid 不给对齐参数时是居中，去掉对齐覆盖并不会回到左对齐。
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    ForEach(firstGroup.values) { stat in
                        Text(stat.label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                ForEach(detail.groups) { group in
                    GridRow {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.values) { stat in
                            Text(stat.value)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
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
                // 用 Grid 而不是手拼 HStack：同一列在所有行里会按最宽的那个单元格对齐。
                // 用固定的 minWidth 各撑各的，表头与数值就会错开。
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text(table.columns.first ?? "")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        ForEach(Array(table.columns.dropFirst().enumerated()), id: \.offset) { _, column in
                            Text(column)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    ForEach(table.rows) { row in
                        GridRow {
                            Text(row.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
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
            ZStack(alignment: .bottomLeading) {
                // 基线：没有用量的日子是空着的（柱高 0）。缺了这条线，整片空白会被读成
                // 「图没画出来」，而不是「那几天没有用量」。
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 1)

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(zip(series.points, heights)), id: \.0.id) { _, height in
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: barWidth, height: height)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
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
