import Foundation

/// One ledger request's token buckets. Mixdog records them separately, so each bucket prices at its own rate.
struct MixdogTokens: Sendable, Equatable {
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int

    var total: Int { input + output + cacheRead + cacheWrite }
}

/// User-entered USD rates per million tokens for a model Mixdog recorded without a cost (for example a
/// custom endpoint whose model is missing from Mixdog's price catalog).
struct MixdogModelPrice: Codable, Sendable, Equatable {
    var inputPerMillion: Double
    var outputPerMillion: Double
    var cacheReadPerMillion: Double
    var cacheWritePerMillion: Double

    func cost(_ tokens: MixdogTokens) -> Double {
        (Double(tokens.input) * inputPerMillion
            + Double(tokens.output) * outputPerMillion
            + Double(tokens.cacheRead) * cacheReadPerMillion
            + Double(tokens.cacheWrite) * cacheWritePerMillion) / 1_000_000
    }
}

/// The saved model prices, keyed by the ledger's model ID. Only rows without a recorded cost use them.
enum MixdogModelPriceSetting {
    static let key = "openusage.mixdog.modelPrices"

    static func load(defaults: UserDefaults = .standard) -> [String: MixdogModelPrice] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: MixdogModelPrice].self, from: data)
        } catch {
            AppLog.error(LogTag.plugin("mixdog"), "saved model prices unreadable: \(error.localizedDescription)")
            return [:]
        }
    }

    static func save(_ prices: [String: MixdogModelPrice], defaults: UserDefaults = .standard) throws {
        guard !prices.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(try JSONEncoder().encode(prices), forKey: key)
    }
}
