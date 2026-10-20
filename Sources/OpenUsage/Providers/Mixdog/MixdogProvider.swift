import Foundation

/// Typed failures for the Mixdog provider, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum MixdogUsageError: Error, LocalizedError, Equatable {
    case notInstalled
    /// The ledger exists but couldn't be read this refresh. Failing loudly here beats rendering
    /// authoritative-looking $0 tiles from an empty scan.
    case ledgerUnreadable

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Mixdog not detected. Use Mixdog on this Mac first."
        case .ledgerUnreadable:
            return "Couldn't read Mixdog's usage ledger. Refresh again, or check the permissions on ~/.mixdog/data/usage."
        }
    }
}

/// Tracks Mixdog usage from its local usage ledger: spend tiles, a usage trend, and the per-model
/// breakdown across every model Mixdog routes to. Local-only; no network.
@MainActor
final class MixdogProvider: ProviderRuntime {
    let provider = Provider(
        id: "mixdog",
        displayName: "Mixdog",
        icon: .providerMark("mixdog")
    )

    let usageScanner: MixdogUsageScanner
    let modelPrices: @MainActor () -> [String: MixdogModelPrice]
    let now: @Sendable () -> Date

    /// Names the local source on hover. The dollars are this Mac only; Mixdog prices subscription
    /// usage at public API rates, so they are estimates rather than billed amounts.
    private let sourceNote = "From your Mixdog usage ledger"
    private let customPriceNote = "From your Mixdog usage ledger · Includes your model prices"

    init(
        usageScanner: MixdogUsageScanner = MixdogUsageScanner(),
        modelPrices: @escaping @MainActor () -> [String: MixdogModelPrice] = { MixdogModelPriceSetting.load() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.usageScanner = usageScanner
        self.modelPrices = modelPrices
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .usageTrend(provider: provider)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: sourceNote)
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: any request in the local ledger. Local-only, off the main actor.
        await loadOffMainActor { [usageScanner] in usageScanner.hasUsage() }
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp
        // can't straddle a midnight boundary.
        let refreshedAt = now()

        let scan: MixdogUsageScan?
        do {
            scan = try await usageScanner.scan(now: refreshedAt, prices: modelPrices())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let scan else {
            return ProviderSnapshot.error(provider: provider, error: MixdogUsageError.notInstalled)
        }

        let note = scan.usesCustomPrices ? customPriceNote : sourceNote
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.logScan.series, to: &lines, now: refreshedAt,
            estimated: true,
            unknownModelsByDay: scan.logScan.unknownModelsByDay,
            modelUsage: scan.logScan.modelUsage,
            modelSourceNote: note
        )
        SpendTileMapper.appendUsageTrend(scan.logScan.series, to: &lines, now: refreshedAt, note: note)
        MetricLine.appendNoDataIfNeeded(&lines)

        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: ProviderUsageHistory(
                series: scan.logScan.series,
                modelUsage: scan.logScan.modelUsage,
                unknownModelsByDay: scan.logScan.unknownModelsByDay
            )
        )
    }
}
