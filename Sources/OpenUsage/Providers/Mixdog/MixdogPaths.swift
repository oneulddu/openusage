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

    /// Ledgers mirrored from other machines (for example by `script/pull_mixdog_remote.sh`), counted
    /// alongside this Mac's own: every visible `*.sqlite` under `~/.config/openusage/mixdog/remotes`, each
    /// exposing the same `events` shape. Sorted for a stable read order; empty when the folder is absent.
    static func remoteLedgerPaths(homeDirectory: URL) -> [String] {
        let directory = homeDirectory.appendingPathComponent(".config/openusage/mixdog/remotes").path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names
            .filter { $0.hasSuffix(".sqlite") && !$0.hasPrefix(".") }
            .sorted()
            .map { directory + "/" + $0 }
    }
}
