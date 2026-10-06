import XCTest
@testable import OpenUsage

final class OpenCodexUsageMapperTests: XCTestCase {
    func testFixtureMapsEveryQuotaAndMixedTimestampUnits() throws {
        let lines = try OpenCodexUsageMapper.mapQuotas(OpenCodexFixtures.quotas)
        let expected: [(String, Double, Double?)] = [
            ("Codex 5h", 52, nil),
            // The fixture's weekly aggregate spans two accounts, so no single-account reset is borrowed.
            ("Codex Weekly", 34.38095238095238, nil),
            ("Claude 5h", 93, 1791284999.839),
            ("Claude Weekly", 13, 1791842399.839),
            ("Grok Weekly", 18, 1791390713.092),
            ("Gemini 5h", 3.7477500000000106, 1791288414),
            ("Gemini Weekly", 3.9112149999999986, 1791487096),
            ("Kiro Monthly", 0, 1793491200)
        ]
        XCTAssertEqual(lines.map(\.label), expected.map { $0.0 })
        for (line, entry) in zip(lines, expected) {
            guard case let .progress(_, used, limit, format, resetsAt, _, _) = line else {
                return XCTFail("Expected a quota meter")
            }
            XCTAssertEqual(used, entry.1, accuracy: 0.000001)
            XCTAssertEqual(limit, 100)
            XCTAssertEqual(format, .percent)
            if let reset = entry.2 {
                XCTAssertEqual(try XCTUnwrap(resetsAt).timeIntervalSince1970, reset, accuracy: 0.001)
            } else {
                XCTAssertNil(resetsAt)
            }
        }
    }

    func testMissingDataIsOmittedAndUnknownProvidersAreIgnored() throws {
        let body = Data(#"""
        {"reports":[
          {"provider":"future","quota":"unknown schema"},
          {"provider":"openai","quota":{"weeklyPercent":null}},
          {"provider":"anthropic"},
          {"provider":"google-antigravity","quota":{"customWindows":[{"label":"Cla","percent":99}]}},
          {"provider":"kiro","quota":{"monthlyPercent":0}}
        ]}
        """#.utf8)
        let lines = try OpenCodexUsageMapper.mapQuotas(body)
        XCTAssertEqual(lines.map(\.label), ["Kiro Monthly"])
        XCTAssertEqual(try OpenCodexUsageMapper.mapQuotas(Data(#"{"reports":[]}"#.utf8)), [])
    }

    func testClampAndExplicitWeeklyResetTakesPrecedence() throws {
        let body = Data(#"""
        {"reports":[{"provider":"openai","quota":{
          "fiveHourPercent":-5.2,"fiveHourResetAt":1791284999.839,
          "weeklyPercent":110.3,"weeklyResetAt":1791842399839
        },"aggregation":{"currentAccount":{"quota":{"weeklyResetAt":1791581420}}}}]}
        """#.utf8)
        let lines = try OpenCodexUsageMapper.mapQuotas(body)
        guard case let .progress(_, session, _, _, sessionReset, _, _) = lines[0],
              case let .progress(_, weekly, _, _, weeklyReset, _, _) = lines[1] else {
            return XCTFail("Expected quotas")
        }
        XCTAssertEqual(session, 0)
        XCTAssertEqual(weekly, 100)
        XCTAssertEqual(try XCTUnwrap(sessionReset).timeIntervalSince1970, 1791284999.839, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(weeklyReset).timeIntervalSince1970, 1791842399.839, accuracy: 0.001)
    }

    func testWeeklyResetFallbackOnlyForSingleAccountAggregate() throws {
        func weeklyReset(includedAccounts: Int) throws -> Date? {
            let body = Data(#"""
            {"reports":[{"provider":"openai","quota":{"weeklyPercent":40},
              "aggregation":{"weekly":{"includedAccounts":\#(includedAccounts)},
                             "currentAccount":{"quota":{"weeklyResetAt":1791581420}}}}]}
            """#.utf8)
            guard case let .progress(_, _, _, _, reset, _, _) = try XCTUnwrap(
                OpenCodexUsageMapper.mapQuotas(body).first
            ) else { XCTFail("Expected a quota meter"); return nil }
            return reset
        }
        XCTAssertEqual(try XCTUnwrap(weeklyReset(includedAccounts: 1)).timeIntervalSince1970, 1791581420)
        XCTAssertNil(try weeklyReset(includedAccounts: 2))
    }

    func testMalformedQuotasFailLoudly() {
        for json in ["{}", #"{"reports":{}}"#,
                     #"{"reports":[{"provider":"openai","quota":{"fiveHourPercent":true}}]}"#] {
            XCTAssertThrowsError(try OpenCodexUsageMapper.mapQuotas(Data(json.utf8))) {
                XCTAssertEqual($0 as? OpenCodexUsageError, .invalidResponse)
            }
        }
    }

    func testSpendFixtureUsesCalendarDaysAndEstimatedCosts() throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 0, minute: 15)))
        var lines: [MetricLine] = []
        let history = try OpenCodexUsageMapper.appendSpendLines(OpenCodexFixtures.usage, now: now, to: &lines)
        XCTAssertEqual(history.series.daily.map(\.date), ["2026-10-04", "2026-10-05", "2026-10-06"])
        XCTAssertEqual(lines.map(\.label), ["Usage Trend", "Today", "Yesterday", "Last 30 Days"])
        XCTAssertEqual(history.series.daily.last?.totalTokens, 116650385)
        XCTAssertEqual(try XCTUnwrap(history.series.daily.last?.costUSD), 185.00324317, accuracy: 0.000001)
        // The shared spend mapper carries both units and marks costs as estimates.
        var expected: [MetricLine] = []
        let series = DailyUsageSeries(daily: [
            .init(date: "2026-10-04", totalTokens: 10288188, costUSD: 14.868494250000005),
            .init(date: "2026-10-05", totalTokens: 126822541, costUSD: 367.54341261999934),
            .init(date: "2026-10-06", totalTokens: 116650385, costUSD: 185.00324317)
        ])
        SpendTileMapper.appendUsageTrend(series, to: &expected, now: now, note: "From your OpenCodex hub")
        SpendTileMapper.appendTokenUsage(series, to: &expected, now: now, estimated: true)
        XCTAssertEqual(lines, expected)
    }

    func testSpendKeepsHubWindowRegardlessOfMacCalendarAndDoesNotInventCost() throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 6)))
        // A hub one day ahead of this Mac still keeps its newest day; only its latest 30 keys are used.
        let days = (0..<31).map { offset -> String in
            let date = Calendar.current.date(byAdding: .day, value: offset - 29, to: now)!
            return DailyUsageAccumulator.dayKey(from: date, calendar: Calendar.current)
        }
        let entries = days.enumerated().map { index, day in
            index == 30 ? #"{"date":"\#(day)","totalTokens":3}"# : #"{"date":"\#(day)","totalTokens":1,"estimatedCostUsd":1}"#
        }
        let body = Data(#"{"days":[\#(entries.joined(separator: ","))]}"#.utf8)
        var lines: [MetricLine] = []
        let history = try OpenCodexUsageMapper.appendSpendLines(body, now: now, to: &lines)
        XCTAssertEqual(history.series.daily.map(\.date), Array(days.suffix(30)))
        XCTAssertEqual(history.series.daily.last?.date, "2026-10-07")
        XCTAssertNil(history.series.daily.last?.costUSD)
    }

    func testInvalidUsageDoesNotAppendPartialSpend() {
        for json in ["{}", #"{"days":[{"date":"2026-02-30","totalTokens":1}]}"#,
                     #"{"days":[{"date":"2026-10-06","totalTokens":-1}]}"#,
                     #"{"days":[{"date":"2026-10-06","totalTokens":1,"estimatedCostUsd":-1}]}"#] {
            var lines: [MetricLine] = []
            XCTAssertThrowsError(try OpenCodexUsageMapper.appendSpendLines(Data(json.utf8), now: Date(), to: &lines))
            XCTAssertTrue(lines.isEmpty)
        }
    }
}
