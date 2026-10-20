import XCTest
@testable import OpenUsage

/// The Mixdog ledger scanner: recorded costs are summed as-is, rows without a cost use the user's model
/// price or are excluded and flagged, and an unreadable ledger fails loudly.
final class MixdogUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
    private let path = "/md/usage/ledger.sqlite"

    private func scanner(_ sqlite: MixdogFakeSQLite) -> MixdogUsageScanner {
        let path = self.path
        return MixdogUsageScanner(sqlite: sqlite, ledgerPath: { path }, readFailureWarning: { _ in })
    }

    private func totals(_ scan: MixdogUsageScan) -> (cost: Double, tokens: Int) {
        (scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +),
         scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens })
    }

    func testRecordedCostsAreSummedAsIs() async throws {
        let sqlite = MixdogFakeSQLite(data: "[" + [
            mixdogRow("2026-07-12T11:00:00.000Z", "claude-opus-5-5", 10, 20, 30, 40, cost: "1.5"),
            mixdogRow("2026-07-11T11:00:00.000Z", "gpt-6.1-sol", 100, 0, 0, 0, cost: "0.25"),
            "\"garbage\""
        ].joined(separator: ",") + "]")
        let scan = try await XCTUnwrapAsync(await scanner(sqlite).scan(now: now, prices: [:]))
        let (cost, tokens) = totals(scan)
        XCTAssertEqual(cost, 1.75, accuracy: 0.0001)
        XCTAssertEqual(tokens, 200)
        XCTAssertFalse(scan.usesCustomPrices)
        XCTAssertTrue(scan.logScan.unknownModelsByDay.isEmpty)
    }

    func testRowWithoutCostIsExcludedAndFlaggedWhenNoPriceIsSet() async throws {
        let sqlite = MixdogFakeSQLite(data: "[" + [
            mixdogRow("2026-07-12T11:00:00.000Z", "claude-opus-5-5", 10, 20, 0, 0, cost: "1.0"),
            mixdogRow("2026-07-12T10:00:00.000Z", "deepseek-v4.1-flash", 1000, 500, 0, 0, cost: "null")
        ].joined(separator: ",") + "]")
        let scan = try await XCTUnwrapAsync(await scanner(sqlite).scan(now: now, prices: [:]))
        let (cost, tokens) = totals(scan)
        XCTAssertEqual(cost, 1.0, accuracy: 0.0001)
        XCTAssertEqual(tokens, 30)
        XCTAssertEqual(scan.logScan.unknownModelsByDay.values.reduce(into: Set<String>()) { $0.formUnion($1) },
                       ["deepseek-v4.1-flash"])
    }

    func testUserPriceFillsOnlyRowsWithoutRecordedCost() async throws {
        let sqlite = MixdogFakeSQLite(data: "[" + [
            // Recorded cost wins even though the model has a user price.
            mixdogRow("2026-07-12T11:00:00.000Z", "deepseek-v4.1-flash", 1_000_000, 0, 0, 0, cost: "9.0"),
            mixdogRow("2026-07-12T10:00:00.000Z", "deepseek-v4.1-flash", 1_000_000, 1_000_000, 2_000_000, 1_000_000,
                      cost: "null")
        ].joined(separator: ",") + "]")
        let price = MixdogModelPrice(
            inputPerMillion: 0.5, outputPerMillion: 2, cacheReadPerMillion: 0.1, cacheWritePerMillion: 1
        )
        let scan = try await XCTUnwrapAsync(await scanner(sqlite).scan(
            now: now, prices: ["deepseek-v4.1-flash": price]
        ))
        let (cost, tokens) = totals(scan)
        // 9.0 recorded + (0.5 + 2 + 0.2 + 1) priced.
        XCTAssertEqual(cost, 12.7, accuracy: 0.0001)
        XCTAssertEqual(tokens, 6_000_000)
        XCTAssertTrue(scan.usesCustomPrices)
        XCTAssertTrue(scan.logScan.unknownModelsByDay.isEmpty)
    }

    func testMissingLedgerReturnsNil() async throws {
        let scan = try await scanner(MixdogFakeSQLite(data: nil)).scan(now: now, prices: [:])
        XCTAssertNil(scan)
    }

    func testEmptyLedgerYieldsEmptyScan() async throws {
        let scan = try await XCTUnwrapAsync(await scanner(MixdogFakeSQLite(data: "[]")).scan(now: now, prices: [:]))
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
    }

    func testUnreadableLedgerThrows() async {
        do {
            _ = try await scanner(MixdogFakeSQLite(failing: true)).scan(now: now, prices: [:])
            XCTFail("expected ledgerUnreadable")
        } catch {
            XCTAssertEqual(error as? MixdogUsageError, .ledgerUnreadable)
        }
    }

    func testSQLCutoffMatchesCalendarTileWindow() async throws {
        let sqlite = MixdogFakeSQLite(data: "[]")
        _ = try await scanner(sqlite).scan(now: now, prices: [:])
        let since = JSONLScanning.sinceDate(daysBack: 30, now: now)
        XCTAssertEqual(sqlite.lastDataSQL, MixdogUsageScanner.dataSQL(cutoffMs: Int(since.timeIntervalSince1970 * 1000)))
    }

    func testUnpricedModelsAndUsageProbe() throws {
        let sqlite = MixdogFakeSQLite(data: "[]", unpriced: #"["deepseek-v4.1-flash","glm-5.3"]"#)
        XCTAssertEqual(try scanner(sqlite).unpricedModels(), ["deepseek-v4.1-flash", "glm-5.3"])
        XCTAssertEqual(try scanner(MixdogFakeSQLite(data: nil)).unpricedModels(), [])

        XCTAssertTrue(scanner(MixdogFakeSQLite(data: "[]", hasEvents: true)).hasUsage())
        XCTAssertFalse(scanner(MixdogFakeSQLite(data: "[]")).hasUsage())
        XCTAssertTrue(scanner(MixdogFakeSQLite(failing: true)).hasUsage(), "an unreadable ledger is a Mixdog footprint")
    }

    func testModelPriceRoundTripsThroughDefaults() throws {
        let defaults = UserDefaults(suiteName: "MixdogUsageScannerTests.\(UUID().uuidString)")!
        let price = MixdogModelPrice(inputPerMillion: 0.27, outputPerMillion: 1.1, cacheReadPerMillion: 0, cacheWritePerMillion: 0)
        try MixdogModelPriceSetting.save(["m": price], defaults: defaults)
        XCTAssertEqual(MixdogModelPriceSetting.load(defaults: defaults), ["m": price])
        try MixdogModelPriceSetting.save([:], defaults: defaults)
        XCTAssertNil(defaults.object(forKey: MixdogModelPriceSetting.key))
    }
}

/// End-to-end provider behavior: detection, spend tiles + trend, and the missing/unreadable ledger paths.
@MainActor
final class MixdogProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func provider(_ sqlite: MixdogFakeSQLite, prices: [String: MixdogModelPrice] = [:]) -> MixdogProvider {
        let now = self.now
        return MixdogProvider(
            usageScanner: MixdogUsageScanner(sqlite: sqlite, ledgerPath: { "/md/usage/ledger.sqlite" },
                                             readFailureWarning: { _ in }),
            modelPrices: { prices },
            now: { now }
        )
    }

    func testRefreshProducesTilesAndTrend() async {
        let sqlite = MixdogFakeSQLite(data: "[" + [
            mixdogRow("2026-07-12T11:00:00.000Z", "claude-opus-5-5", 10, 20, 30, 40, cost: "1.5"),
            mixdogRow("2026-07-12T10:00:00.000Z", "custom-model", 1_000_000, 0, 0, 0, cost: "null")
        ].joined(separator: ",") + "]")
        let price = MixdogModelPrice(inputPerMillion: 1, outputPerMillion: 0, cacheReadPerMillion: 0, cacheWritePerMillion: 0)
        let snapshot = await provider(sqlite, prices: ["custom-model": price]).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Last 30 Days"))
        guard case let .chart(_, _, note)? = snapshot.line(label: "Usage Trend") else {
            return XCTFail("expected a Usage Trend chart")
        }
        XCTAssertEqual(note, "From your Mixdog usage ledger · Includes your model prices")
        let cost = snapshot.usageHistory?.series.daily.compactMap(\.costUSD).reduce(0, +)
        XCTAssertEqual(cost ?? 0, 2.5, accuracy: 0.0001)
    }

    func testMissingLedgerIsNotInstalled() async {
        let snapshot = await provider(MixdogFakeSQLite(data: nil)).refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        let has = await provider(MixdogFakeSQLite(data: nil)).hasLocalCredentials()
        XCTAssertFalse(has)
    }

    func testUnreadableLedgerSurfacesError() async {
        let snapshot = await provider(MixdogFakeSQLite(failing: true)).refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
    }

    func testHasLocalCredentialsWhenLedgerHasEvents() async {
        let has = await provider(MixdogFakeSQLite(data: "[]", hasEvents: true)).hasLocalCredentials()
        XCTAssertTrue(has)
    }

    /// Owner-confirmed placement: Usage Trend above the fold, the spend tiles below the caret, all
    /// enabled, nothing pinned.
    func testDefaultLayout() {
        let ids = provider(MixdogFakeSQLite(data: nil)).widgetDescriptors.map(\.id)
        XCTAssertEqual(ids, ["mixdog.trend", "mixdog.today", "mixdog.yesterday", "mixdog.last30"])
        for id in ids {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) should be enabled by default")
        }
        XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains("mixdog.trend"))
        for id in ["mixdog.today", "mixdog.yesterday", "mixdog.last30"] {
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should sit below the caret")
        }
        XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains { $0.hasPrefix("mixdog.") })
    }
}

/// One `[ts, model, input, output, cache_read, cache_write, cost_usd]` row in the ledger query's shape.
func mixdogRow(
    _ iso: String, _ model: String, _ input: Int, _ output: Int, _ cacheRead: Int, _ cacheWrite: Int, cost: String
) -> String {
    let epochMs = Int(OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
    return "[\(epochMs),\"\(model)\",\(input),\(output),\(cacheRead),\(cacheWrite),\(cost)]"
}

/// Stub ledger that answers each scanner query by SQL shape. `data == nil` models a missing ledger file
/// (the real accessor returns nil without launching sqlite3).
final class MixdogFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: String?
    var unpriced: String
    var hasEvents: Bool
    var failing: Bool
    var lastDataSQL: String?

    init(data: String? = nil, unpriced: String = "[]", hasEvents: Bool = false, failing: Bool = false) {
        self.data = data
        self.unpriced = unpriced
        self.hasEvents = hasEvents
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing { throw SQLiteError.queryFailed("database is locked") }
        guard data != nil else { return nil }
        if sql == MixdogUsageScanner.probeSQL { return hasEvents ? "1" : nil }
        if sql == MixdogUsageScanner.unpricedModelsSQL { return unpriced }
        lastDataSQL = sql
        return data
    }

    func execute(path: String, sql: String) throws {}
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
