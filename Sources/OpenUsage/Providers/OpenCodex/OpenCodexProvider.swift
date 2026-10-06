import Foundation

@MainActor
final class OpenCodexProvider: ProviderRuntime {
    let provider = Provider(id: "opencodex", displayName: "OpenCodex", icon: .providerMark("opencodex"))
    let authStore: OpenCodexAuthStore
    let usageClient: OpenCodexUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OpenCodexAuthStore = OpenCodexAuthStore(),
        usageClient: OpenCodexUsageClient = OpenCodexUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        OpenCodexUsageMapper.quotaMetrics.map { metric in
            WidgetDescriptor.percent(id: "opencodex.\(metric.id)", provider: provider, title: metric.title)
                .exportingLimit(metric.id, unit: "percent")
        } + [
            .usageTrend(provider: provider)
                .exportingHistory(scope: .accountWide, estimatedCost: true, sourceNote: OpenCodexUsageMapper.sourceNote)
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in
            do {
                _ = try authStore.load()
                return true
            } catch {
                if (error as? OpenCodexAuthError) != .notConfigured {
                    AppLog.warn(LogTag.auth("opencodex"), "local configuration could not be loaded")
                }
                return false
            }
        }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            let auth = try await loadOffMainActor { [authStore] in try authStore.load() }
            let body = try await usageClient.fetchQuotas(auth: auth)
            var lines = try OpenCodexUsageMapper.mapQuotas(body)
            let refreshedAt = now()
            var history: ProviderUsageHistory?
            do {
                let usage = try await usageClient.fetchUsage(auth: auth)
                history = try OpenCodexUsageMapper.appendSpendLines(usage, now: refreshedAt, to: &lines)
            } catch {
                // Only a stable category is logged; never interpolate a token, URL or response body.
                let category = (error as? CategorizedError)?.errorCategory ?? .other
                AppLog.warn(LogTag.plugin("opencodex"), "optional usage history failed (\(category.rawValue)); quota meters retained")
            }
            return .make(provider: provider, plan: nil, lines: lines, refreshedAt: refreshedAt, usageHistory: history)
        } catch {
            let category = (error as? CategorizedError)?.errorCategory ?? .other
            AppLog.error(LogTag.plugin("opencodex"), "refresh failed (\(category.rawValue))")
            return .error(provider: provider, error: error)
        }
    }
}
