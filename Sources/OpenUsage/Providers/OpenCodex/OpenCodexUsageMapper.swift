import Foundation

/// Maps the hub's upstream quota summaries and already-aggregated daily spend without repricing.
enum OpenCodexUsageMapper {
    static let sourceNote = "From your OpenCodex hub"

    struct QuotaMetric: Sendable {
        let id: String
        let title: String
        let upstream: String
        let percentKey: String
        let resetKey: String
        let windowLabel: String?
        let periodMs: Int

        init(_ id: String, _ title: String, _ upstream: String, _ prefix: String,
             hours: Int, windowLabel: String? = nil) {
            self.id = id
            self.title = title
            self.upstream = upstream
            self.percentKey = windowLabel == nil ? prefix + "Percent" : "percent"
            self.resetKey = windowLabel == nil ? prefix + "ResetAt" : "resetAt"
            self.windowLabel = windowLabel
            self.periodMs = hours * 60 * 60 * 1000
        }
    }

    static let quotaMetrics: [QuotaMetric] = [
        .init("codexSession", "Codex 5h", "openai", "fiveHour", hours: 5),
        .init("codexWeekly", "Codex Weekly", "openai", "weekly", hours: 168),
        .init("claudeSession", "Claude 5h", "anthropic", "fiveHour", hours: 5),
        .init("claudeWeekly", "Claude Weekly", "anthropic", "weekly", hours: 168),
        .init("grokWeekly", "Grok Weekly", "xai", "weekly", hours: 168),
        .init("geminiSession", "Gemini 5h", "google-antigravity", "", hours: 5, windowLabel: "Gem"),
        .init("geminiWeekly", "Gemini Weekly", "google-antigravity", "", hours: 168, windowLabel: "Gem (Weekly)"),
        .init("kiroMonthly", "Kiro Monthly", "kiro", "monthly", hours: 30 * 24)
    ]

    static func mapQuotas(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body),
              let reports = root["reports"] as? [[String: Any]] else {
            throw OpenCodexUsageError.invalidResponse
        }
        return try quotaMetrics.compactMap { metric in
            guard let report = reports.first(where: { $0["provider"] as? String == metric.upstream }),
                  let rawQuota = report["quota"], !(rawQuota is NSNull) else { return nil }
            guard let quota = rawQuota as? [String: Any] else { throw OpenCodexUsageError.invalidResponse }
            let values: [String: Any]
            if let label = metric.windowLabel {
                guard let rawWindows = quota["customWindows"], !(rawWindows is NSNull) else { return nil }
                guard let windows = rawWindows as? [[String: Any]] else { throw OpenCodexUsageError.invalidResponse }
                guard let window = windows.first(where: { $0["label"] as? String == label }) else { return nil }
                values = window
            } else {
                values = quota
            }
            guard let percent = try optionalNumber(values[metric.percentKey]) else { return nil }
            var reset = try optionalNumber(values[metric.resetKey])
            // The combined weekly meter only borrows the current account's reset when it is the only
            // account in the aggregate; with several accounts their resets differ.
            if reset == nil, metric.id == "codexWeekly", singleWeeklyAccount(report) {
                let aggregation = report["aggregation"] as? [String: Any]
                let account = aggregation?["currentAccount"] as? [String: Any]
                let currentQuota = account?["quota"] as? [String: Any]
                reset = try optionalNumber(currentQuota?["weeklyResetAt"])
            }
            return .progress(
                label: metric.title, used: ProviderParse.clampPercent(percent), limit: 100, format: .percent,
                resetsAt: reset.map { Date(timeIntervalSince1970: $0 < 1e12 ? $0 : $0 / 1000) },
                periodDurationMs: metric.periodMs
            )
        }
    }

    static func appendSpendLines(_ body: Data, now: Date, to lines: inout [MetricLine]) throws -> ProviderUsageHistory {
        guard let root = ProviderParse.jsonObject(body), let days = root["days"] as? [[String: Any]] else {
            throw OpenCodexUsageError.invalidResponse
        }
        // The hub returns its own 30 local calendar days. Keep its window as-is (the latest 30 day
        // keys) instead of clipping it with this Mac's calendar, so a time-zone difference never drops
        // a hub day.
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        var seen: Set<String> = []
        var daily: [DailyUsageEntry] = []
        var totalTokens = 0
        var totalCost = 0.0
        for day in days {
            guard let date = day["date"] as? String,
                  let parsedDate = formatter.date(from: date), formatter.string(from: parsedDate) == date,
                  seen.insert(date).inserted,
                  let tokens = try optionalNumber(day["totalTokens"]), tokens >= 0,
                  tokens.rounded(.down) == tokens, tokens < Double(Int.max) else {
                throw OpenCodexUsageError.invalidResponse
            }
            let cost = try optionalNumber(day["estimatedCostUsd"])
            if let cost, cost < 0 { throw OpenCodexUsageError.invalidResponse }
            daily.append(DailyUsageEntry(date: date, totalTokens: Int(tokens), costUSD: cost))
        }
        daily = Array(daily.sorted { $0.date < $1.date }.suffix(30))
        for entry in daily {
            let (sum, overflow) = totalTokens.addingReportingOverflow(entry.totalTokens)
            totalTokens = sum
            totalCost += entry.costUSD ?? 0
            guard !overflow, totalCost.isFinite else { throw OpenCodexUsageError.invalidResponse }
        }
        let series = DailyUsageSeries(daily: daily)
        SpendTileMapper.appendUsageTrend(series, to: &lines, now: now, note: sourceNote)
        SpendTileMapper.appendTokenUsage(series, to: &lines, now: now, estimated: true)
        return ProviderUsageHistory(series: series)
    }

    private static func optionalNumber(_ raw: Any?) throws -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let number = ProviderParse.number(raw) else { throw OpenCodexUsageError.invalidResponse }
        return number
    }

    private static func singleWeeklyAccount(_ report: [String: Any]) -> Bool {
        guard let aggregation = report["aggregation"] as? [String: Any] else { return false }
        let weekly = aggregation["weekly"] as? [String: Any]
        guard let count = weekly?["includedAccounts"] ?? aggregation["includedAccounts"] else { return false }
        return ProviderParse.number(count) == 1
    }
}
