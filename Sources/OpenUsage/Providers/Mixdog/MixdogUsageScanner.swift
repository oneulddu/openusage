import Foundation

/// The result of a Mixdog ledger scan: the daily series for the spend tiles + trend, and whether any
/// counted request was priced with a user-entered model price.
struct MixdogUsageScan: Sendable {
    var logScan: LogUsageScan
    var usesCustomPrices: Bool
}

/// Reads Mixdog's usage ledger (`~/.mixdog/data/usage/ledger.sqlite`) through its `events` view: one
/// row per model request with the token buckets and the cost Mixdog recorded. Ledgers mirrored from
/// other machines (`MixdogPaths.remoteLedgerPaths`) are read the same way and counted together.
/// Recorded costs are summed as-is; a row without one is priced from the user's model prices, or else
/// excluded and flagged as an unknown model.
///
/// A `Sendable` struct, `async` and nonisolated, so the SQLite reads run off the main actor when the
/// `@MainActor` provider `await`s it.
struct MixdogUsageScanner: Sendable {
    var sqlite: SQLiteAccessing
    var ledgerPaths: @Sendable () -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        ledgerPaths: @escaping @Sendable () -> [String] = MixdogUsageScanner.defaultLedgerPaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.ledgerPaths = ledgerPaths
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("mixdog"),
            warning: readFailureWarning
        )
    }

    static let defaultLedgerPaths: @Sendable () -> [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let local = MixdogPaths.ledgerPath(dataDirectory: MixdogPaths.dataDirectory(
            environment: ProcessEnvironmentReader(),
            homeDirectory: home
        ))
        return [local] + MixdogPaths.remoteLedgerPaths(homeDirectory: home)
    }

    /// Scan the last `daysBack` days across every ledger. Returns `nil` only when no ledger exists; an
    /// empty ledger yields an empty scan. Throws `ledgerUnreadable` when any existing ledger can't be read.
    func scan(now: Date, prices: [String: MixdogModelPrice], daysBack: Int = 30) async throws -> MixdogUsageScan? {
        // Same calendar bound the tiles/trend use, so morning rows on the oldest day aren't cut off.
        let tileSince = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(tileSince.timeIntervalSince1970 * 1000)

        var rows: [Row] = []
        var checkedPaths: Set<String> = []
        var failures: [String: Error] = [:]
        for path in ledgerPaths() {
            do {
                // `json_group_array` always yields at least `[]`, so nil means the ledger file is absent.
                guard let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) else {
                    continue
                }
                checkedPaths.insert(path)
                rows += try Self.parseRows(json)
            } catch {
                checkedPaths.insert(path)
                failures[path] = error
            }
        }
        // Edge-triggered so a persistently locked ledger warns once, not on every refresh.
        let newlyFailing = await readFailureReporter.update(
            checkedPaths: checkedPaths, failingPaths: Set(failures.keys)
        )
        for path in newlyFailing.sorted() {
            let message = failures[path]?.localizedDescription ?? "unknown error"
            AppLog.warn(LogTag.plugin("mixdog"), "ledger query failed for \(path): \(message)")
        }
        guard failures.isEmpty else { throw MixdogUsageError.ledgerUnreadable }
        guard !checkedPaths.isEmpty else { return nil }

        var accumulator = DailyUsageAccumulator()
        var usesCustomPrices = false
        for row in rows {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= tileSince else { continue }
            let day = DailyUsageAccumulator.dayKey(from: date)
            let cost: Double
            if let recorded = row.cost {
                cost = recorded
            } else if let price = prices[row.model] {
                cost = price.cost(row.tokens)
                usesCustomPrices = true
            } else {
                if row.tokens.total > 0 { accumulator.addUnknownModel(day: day, model: row.model) }
                continue
            }
            accumulator.add(day: day, tokens: row.tokens.total, cost: cost, model: row.model)
        }
        return MixdogUsageScan(logScan: accumulator.build(), usesCustomPrices: usesCustomPrices)
    }

    /// Distinct models with at least one request recorded without a cost in any ledger — the ones a
    /// user price can fill. Empty when no ledger exists.
    func unpricedModels() throws -> [String] {
        var models: Set<String> = []
        for path in ledgerPaths() {
            guard let json = try sqlite.queryValue(path: path, sql: Self.unpricedModelsSQL) else { continue }
            guard let data = json.data(using: .utf8),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
            else { throw MixdogUsageError.ledgerUnreadable }
            models.formUnion(parsed.compactMap { ($0 as? String)?.nilIfEmpty })
        }
        return models.sorted()
    }

    /// Cheap local probe for `hasLocalCredentials()`: does any ledger hold at least one request?
    /// Read-only, no network. An unreadable ledger counts as a Mixdog footprint so `refresh()` gets to
    /// surface the real error.
    func hasUsage() -> Bool {
        for path in ledgerPaths() {
            do {
                if try sqlite.queryValue(path: path, sql: Self.probeSQL) != nil { return true }
            } catch {
                AppLog.warn(LogTag.plugin("mixdog"), "usage probe failed: \(error.localizedDescription)")
                return true
            }
        }
        return false
    }

    // MARK: - Parsing

    private struct Row {
        var ms: Double
        var model: String
        var tokens: MixdogTokens
        var cost: Double?
    }

    /// Parse the `json_group_array(json_array(...))` payload: an array of
    /// `[ts, model, input, output, cache_read, cache_write, cost_usd]`. Rows without a timestamp or model
    /// are skipped at this boundary; a non-JSON payload means the ledger couldn't be read.
    private static func parseRows(_ json: String) throws -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { throw MixdogUsageError.ledgerUnreadable }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 7,
                  let ms = ProviderParse.number(entry[0]),
                  let model = (entry[1] as? String)?.nilIfEmpty
            else { continue }
            let tokens = MixdogTokens(
                input: tokenCount(entry[2]),
                output: tokenCount(entry[3]),
                cacheRead: tokenCount(entry[4]),
                cacheWrite: tokenCount(entry[5])
            )
            let cost = ProviderParse.number(entry[6]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            rows.append(Row(ms: ms, model: model, tokens: tokens, cost: cost))
        }
        return rows
    }

    /// Clamp before the Int conversion so a corrupt, absurdly large count can't trap (Int(Double)
    /// crashes above Int.max). 1e15 is far above any real token total.
    private static func tokenCount(_ value: Any) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1e15))
    }

    // MARK: - SQL

    static func dataSQL(cutoffMs: Int) -> String {
        """
        SELECT json_group_array(json_array(ts, model, input, output, cache_read, cache_write, cost_usd))
        FROM events WHERE ts >= \(cutoffMs);
        """
    }

    static let unpricedModelsSQL = """
        SELECT json_group_array(model) FROM (
          SELECT DISTINCT model FROM events WHERE cost_usd IS NULL AND model IS NOT NULL ORDER BY model
        );
        """

    static let probeSQL = "SELECT 1 FROM events LIMIT 1;"
}
