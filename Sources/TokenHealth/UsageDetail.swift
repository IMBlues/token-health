import Foundation

/// 详情浮层要展示的内容。与 Provider 无关，浮层只认这个类型。
///
/// 不变量：`DetailStat.id` 取 `label`、`DetailTableRow.id` 取 `name`，
/// 因此同一个集合内 label / name 必须唯一 —— 填充方要先聚合去重，否则 `ForEach` 会出问题。
struct UsageDetail: Equatable, Sendable {
    var headline: [DetailStat] = []
    var groups: [DetailGroup] = []
    var series: DetailSeries? = nil
    var breakdown: [DetailStat] = []
    var table: DetailTable? = nil

    /// 一个区块都没有时，浮层没必要画数据区。
    var isEmpty: Bool {
        headline.isEmpty && groups.isEmpty && breakdown.isEmpty && table == nil
    }
}

struct DetailStat: Equatable, Sendable, Identifiable {
    var label: String
    var value: String

    var id: String { label }
}

struct DetailGroup: Equatable, Sendable, Identifiable {
    var title: String
    var values: [DetailStat]

    var id: String { title }
}

struct DetailSeries: Equatable, Sendable {
    var title: String
    var points: [DetailSeriesPoint]
    var axisStart: String
    var axisEnd: String
}

struct DetailSeriesPoint: Equatable, Sendable, Identifiable {
    var date: Date
    var value: Double

    var id: Date { date }
}

struct DetailTable: Equatable, Sendable {
    var title: String
    var columns: [String]
    var rows: [DetailTableRow]
    var footnote: String?
}

struct DetailTableRow: Equatable, Sendable, Identifiable {
    var name: String
    /// 对应 `columns` 去掉首列后的其余列，即 `cells.count == columns.count - 1`。
    var cells: [String]

    var id: String { name }
}
