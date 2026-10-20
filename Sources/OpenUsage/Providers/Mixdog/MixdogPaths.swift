import Foundation

/// Where Mixdog keeps its usage ledger on this machine. Resolution mirrors Mixdog itself: an explicit
/// `MIXDOG_DATA_DIR` wins, then the default `~/.mixdog/data`.
enum MixdogPaths {
    static func dataDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let override = environment.value(for: "MIXDOG_DATA_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(override).trimmingTrailingSlashes
        }
        return homeDirectory.appendingPathComponent(".mixdog/data").path
    }

    /// The SQLite ledger Mixdog writes one row to per model request.
    static func ledgerPath(dataDirectory: String) -> String {
        dataDirectory.trimmingTrailingSlashes + "/usage/ledger.sqlite"
    }
}
