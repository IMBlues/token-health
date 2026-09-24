import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TokenHealth

/// 浮层的无窗口渲染冒烟：给定完整/空白/全零三种输入都能光栅化出合理的尺寸。
/// 像素级外观不在这里断言 —— 那要靠人工看。
@MainActor
struct DetailPopoverRenderTests {
    @Test
    func rendersAFullDetail() throws {
        let image = try render(fullDetail)
        #expect(image.width == 640, "320pt @2x")
        #expect(image.height > 200, "五个区块都非空时应该有这么高")
    }

    @Test
    func rendersAnEmptyDetailWithoutCrashing() throws {
        let image = try render(UsageDetail())
        #expect(image.height > 0)
    }

    @Test
    func rendersANoUsageMonth() throws {
        let points = (0..<24).map { index in
            DetailSeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(index) * 86_400), value: 0)
        }
        let detail = UsageDetail(
            headline: [DetailStat(label: "CNY", value: "1,284.60")],
            series: DetailSeries(title: "Tokens this month", points: points, axisStart: "9/1", axisEnd: "9/24")
        )
        let image = try render(detail)
        #expect(image.height > 0, "全零的月份不该崩")
    }

    @Test
    func rendersTheLoadingState() throws {
        let image = try render(nil, statusMessage: nil, updatedAt: nil)
        #expect(image.height > 0)
    }

    @Test
    func rendersAnErrorOverStaleData() throws {
        let loading = try render(nil, statusMessage: nil, updatedAt: nil)
        let failed = try render(fullDetail, statusMessage: "HTTP 503", updatedAt: Date())

        #expect(failed.height > loading.height, "错误行挂在顶部，不该顶掉数据")
    }

    private var fullDetail: UsageDetail {
        UsageDetail(
            headline: [
                DetailStat(label: "CNY", value: "1,284.60"),
                DetailStat(label: "USD", value: "3.00")
            ],
            groups: [
                DetailGroup(title: "Today", values: [
                    DetailStat(label: "Requests", value: "12"),
                    DetailStat(label: "Tokens", value: "184K"),
                    DetailStat(label: "Cost", value: "0.42 CNY")
                ]),
                DetailGroup(title: "This month", values: [
                    DetailStat(label: "Requests", value: "1.2K"),
                    DetailStat(label: "Tokens", value: "18.2M"),
                    DetailStat(label: "Cost", value: "41.80 CNY")
                ])
            ],
            series: DetailSeries(
                title: "Tokens this month",
                points: (0..<24).map { index in
                    DetailSeriesPoint(
                        date: Date(timeIntervalSince1970: TimeInterval(index) * 86_400),
                        value: Double((index * 37) % 900 + 100)
                    )
                },
                axisStart: "9/1",
                axisEnd: "9/24"
            ),
            breakdown: [
                DetailStat(label: "Output", value: "8.1M"),
                DetailStat(label: "Cache hit", value: "9.4M"),
                DetailStat(label: "Cache miss", value: "0.7M")
            ],
            table: DetailTable(
                title: "By model · this month",
                columns: ["Model", "Requests", "Tokens", "Cost"],
                rows: [
                    DetailTableRow(name: "deepseek-chat", cells: ["980", "14.2M", "31.20 CNY"]),
                    DetailTableRow(name: "deepseek-reasoner", cells: ["224", "4.0M", "10.60 CNY"])
                ],
                footnote: "+2 more models"
            )
        )
    }

    private func render(
        _ detail: UsageDetail?,
        statusMessage: String? = nil,
        updatedAt: Date? = Date()
    ) throws -> (width: Int, height: Int) {
        let renderer = ImageRenderer(
            content: DetailPopoverView(
                serviceName: "DeepSeek",
                detail: detail,
                statusMessage: statusMessage,
                updatedAt: updatedAt,
                onRefresh: {}, onUnpin: {}, onOpenSettings: {}, onQuit: {}
            )
        )
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return (image.width, image.height)
    }
}
