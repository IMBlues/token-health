import SwiftUI

struct StatusMenuView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token Health")
                        .font(.headline)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task {
                        await appState.refreshAll()
                    }
                } label: {
                    Image(systemName: appState.isRefreshing ? "arrow.triangle.2.circlepath.circle" : "arrow.clockwise.circle")
                }
                .buttonStyle(.borderless)
                .help("Refresh")

                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }

            if appState.configs.isEmpty {
                EmptyStateView()
            } else {
                VStack(spacing: 10) {
                    ForEach(appState.configs.filter(\.isEnabled)) { config in
                        UsageCard(config: config, snapshot: appState.snapshots[config.id])
                    }
                }
            }

            Divider()

            HStack {
                Button("Add Provider") {
                    appState.settingsSelectedID = appState.addConfig()
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .onAppear {
            Task {
                await appState.refreshAll()
            }
        }
    }

    private var summaryText: String {
        guard !appState.configs.isEmpty else {
            return "No plans"
        }
        if appState.isRefreshing {
            return "Refreshing"
        }
        let ready = appState.snapshots.values.filter { $0.state == .ready }.count
        return "\(ready)/\(appState.configs.filter(\.isEnabled).count) updated"
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No plans configured")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Add a provider to start tracking usage.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

private struct UsageCard: View {
    let config: ServiceConfig
    let snapshot: ProviderUsageSnapshot?
    @State private var showsDetails = false
    @State private var revealsSensitiveAmounts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }

            if let snapshot, snapshot.state == .ready {
                ForEach(primaryUsages(from: snapshot.usages)) { usage in
                    UsageLine(
                        usage: usage,
                        isSensitiveAmount: isSensitiveAmount(usage),
                        revealsSensitiveAmount: $revealsSensitiveAmounts
                    )
                }

                let details = detailUsages(from: snapshot.usages)
                if !details.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showsDetails.toggle()
                        }
                    } label: {
                        Label(showsDetails ? "Hide details" : "Show details", systemImage: showsDetails ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(showsDetails ? "Hide usage details" : "Show usage details")

                    if showsDetails {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(details) { usage in
                                UsageLine(
                                    usage: usage,
                                    isSensitiveAmount: isSensitiveAmount(usage),
                                    revealsSensitiveAmount: $revealsSensitiveAmounts
                                )
                            }
                        }
                    }
                }
            } else {
                Text(snapshot?.statusMessage ?? "Waiting for refresh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: String {
        guard let snapshot else {
            return "Pending"
        }
        switch snapshot.state {
        case .ready:
            return "OK"
        case .needsConfiguration:
            return "Config"
        case .unavailable:
            return "Unavailable"
        }
    }

    private var statusColor: Color {
        guard let snapshot else {
            return .secondary
        }
        return snapshot.state == .ready ? .green : .orange
    }

    private var subtitle: String {
        let providerTitle = snapshot?.providerTitle ?? config.providerKind.title
        guard let planName = snapshot?.planName, !planName.isEmpty else {
            return providerTitle
        }
        return "\(providerTitle) · \(planName)"
    }

    private func primaryUsages(from usages: [TokenUsage]) -> [TokenUsage] {
        usages.filter { usage in
            switch usage.window {
            case .sevenDaysTokens:
                return isTokenTotal(usage)
            case .sevenDaysTools:
                return false
            case .balance:
                return true
            case .todayCost, .todayTokens, .todayRequests:
                return isTodayTotal(usage)
            case .fiveHours, .week, .mcpMonth:
                return true
            }
        }
        .sorted(by: usageSort)
    }

    private func detailUsages(from usages: [TokenUsage]) -> [TokenUsage] {
        usages.filter { usage in
            switch usage.window {
            case .sevenDaysTokens:
                return !isTokenTotal(usage)
            case .sevenDaysTools:
                return true
            case .balance:
                return false
            case .todayCost, .todayTokens, .todayRequests:
                return !isTodayTotal(usage)
            case .fiveHours, .week, .mcpMonth:
                return false
            }
        }
        .sorted(by: usageSort)
    }

    private func isTokenTotal(_ usage: TokenUsage) -> Bool {
        (usage.label ?? "").lowercased().contains("total")
    }

    private func isTodayTotal(_ usage: TokenUsage) -> Bool {
        (usage.label ?? "").lowercased().contains("total")
    }

    private func isSensitiveAmount(_ usage: TokenUsage) -> Bool {
        guard config.providerKind == .deepSeek else {
            return false
        }
        return usage.window == .balance || usage.window == .todayCost
    }

    private func usageSort(_ lhs: TokenUsage, _ rhs: TokenUsage) -> Bool {
        let leftRank = usageRank(lhs)
        let rightRank = usageRank(rhs)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        return (lhs.label ?? lhs.window.title) < (rhs.label ?? rhs.window.title)
    }

    private func usageRank(_ usage: TokenUsage) -> Int {
        switch usage.window {
        case .balance:
            0
        case .todayCost:
            1
        case .todayTokens:
            2
        case .todayRequests:
            3
        case .fiveHours:
            10
        case .week:
            11
        case .mcpMonth:
            12
        case .sevenDaysTokens:
            isTokenTotal(usage) ? 13 : 20
        case .sevenDaysTools:
            30
        }
    }
}

private struct UsageLine: View {
    let usage: TokenUsage
    let isSensitiveAmount: Bool
    @Binding var revealsSensitiveAmount: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(usage.label ?? usage.window.title)
                    .font(.caption.weight(.medium))
                Spacer()
                HStack(spacing: 6) {
                    Text(amountText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if isSensitiveAmount {
                        Button {
                            revealsSensitiveAmount.toggle()
                        } label: {
                            Image(systemName: revealsSensitiveAmount ? "eye.slash" : "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(revealsSensitiveAmount ? "Hide amount" : "Show amount")
                    }
                }
            }

            if usage.limit != nil {
                ProgressView(value: usage.ratio ?? 0)
                    .tint(tint)
                    .help(resetText)
            }

            if usage.resetDate != nil {
                TimelineView(.periodic(from: Date(), by: 30)) { timeline in
                    Label(resetText(now: timeline.date), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private var amountText: String {
        if isSensitiveAmount && !revealsSensitiveAmount {
            return "¥¥¥"
        }
        if let displayValue = usage.displayValue, !displayValue.isEmpty {
            return displayValue
        }
        if usage.unit == "%" {
            return "\(usage.used)%"
        }
        let used = formatAmount(usage.used)
        guard let limit = usage.limit else {
            return unitText.map { "\(used) \($0)" } ?? used
        }
        let amount = "\(used) / \(formatAmount(limit))"
        return unitText.map { "\(amount) \($0)" } ?? amount
    }

    private var unitText: String? {
        usage.unit?.isEmpty == false ? usage.unit : nil
    }

    private func formatAmount(_ value: Int) -> String {
        let number = Double(value)
        if abs(value) >= 1_000_000 {
            return String(format: "%.2fM", number / 1_000_000)
        }
        if abs(value) >= 10_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return value.formatted()
    }

    private var tint: Color {
        guard let ratio = usage.ratio else {
            return .accentColor
        }
        if ratio >= 0.9 {
            return .red
        }
        if ratio >= 0.7 {
            return .orange
        }
        return .green
    }

    private var resetText: String {
        guard let resetDate = usage.resetDate else {
            return "Reset time unavailable"
        }
        return "Resets \(resetDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private func resetText(now: Date) -> String {
        guard let resetDate = usage.resetDate else {
            return "Reset time unavailable"
        }

        let remaining = Int(resetDate.timeIntervalSince(now).rounded(.up))
        if remaining <= 0 {
            return "Reset due · \(absoluteResetText(resetDate, now: now))"
        }
        return "Resets in \(durationText(seconds: remaining)) · \(absoluteResetText(resetDate, now: now))"
    }

    private func durationText(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
        }

        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }

    private func absoluteResetText(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
