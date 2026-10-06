import XCTest
@testable import OpenUsage

@MainActor
final class OpenCodexProviderTests: XCTestCase {
    func testHubSpendIsExcludedFromTotalSpendToAvoidDoubleCounting() {
        let suiteName = "OpenUsageTests.OpenCodexTotalSpend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LayoutStore(
            registry: .from([AntigravityProvider(), OpenCodexProvider()]),
            defaults: defaults, storageKey: "layout"
        )
        // The hub already includes the Antigravity requests that card counts locally.
        XCTAssertEqual(store.spendCapableProviders.map(\.id), ["antigravity"])
        XCTAssertTrue(store.placed.contains { $0.descriptorID == "opencodex.today" })
    }

    func testRefreshRequestsEndpointsAndPublishesAccountWideHistory() async throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12)))
        let provider = OpenCodexProvider(authStore: authStore(), usageClient: OpenCodexUsageClient(
            http: RoutingHTTPClient { request in
                XCTAssertEqual(request.method, "GET")
                XCTAssertEqual(request.headers["Authorization"], "Bearer test-token")
                XCTAssertEqual(request.url.host, "127.0.0.1")
                XCTAssertEqual(request.url.port, 10101)
                if request.url.path == "/hub/api/provider-quotas" {
                    XCTAssertNil(request.url.query)
                    return HTTPResponse(statusCode: 200, headers: [:], body: OpenCodexFixtures.quotas)
                }
                XCTAssertEqual(request.url.path, "/hub/api/usage")
                XCTAssertEqual(request.url.query, "days=30")
                return HTTPResponse(statusCode: 200, headers: [:], body: OpenCodexFixtures.usage)
            }
        ), now: { date })
        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.count, 12)
        XCTAssertNotNil(snapshot.usageHistory)
        XCTAssertEqual(snapshot.refreshedAt, date)
        let descriptor = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "opencodex.trend" })
        XCTAssertEqual(descriptor.historyResource?.scope, .accountWide)
        XCTAssertEqual(descriptor.historyResource?.estimatedCost, true)
        XCTAssertEqual(descriptor.historyResource?.sourceNote, "From your OpenCodex hub")
    }

    func testOptionalHistoryFailuresRetainQuotasAndLeaveSpendEmpty() async {
        // Auth, status, transport, and decoding failures are all additive-only for usage history.
        for mode in [401, 403, 500, 0, 200] {
            let provider = OpenCodexProvider(authStore: authStore(), usageClient: OpenCodexUsageClient(
                http: RoutingHTTPClient { request in
                    if request.url.path.hasSuffix("provider-quotas") {
                        return HTTPResponse(statusCode: 200, headers: [:], body: OpenCodexFixtures.quotas)
                    }
                    if mode == 0 { throw URLError(.cannotConnectToHost) }
                    return HTTPResponse(statusCode: mode, headers: [:], body: Data("{}".utf8))
                }
            ))
            let snapshot = await provider.refresh()
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.lines.count, 8)
            XCTAssertNotNil(snapshot.line(label: "Codex 5h"))
            XCTAssertNil(snapshot.line(label: "Today"))
            XCTAssertNil(snapshot.usageHistory)
        }
    }

    func testRequiredEndpointFailuresAreTyped() async {
        let cases: [(Int, ErrorCategory)] = [(401, .authInvalid), (403, .authInvalid), (500, .http5xx),
                                              (429, .rateLimited), (0, .network), (200, .decoding)]
        for (status, category) in cases {
            let provider = OpenCodexProvider(authStore: authStore(), usageClient: OpenCodexUsageClient(
                http: RoutingHTTPClient { _ in
                    if status == 0 { throw URLError(.cannotConnectToHost) }
                    return HTTPResponse(statusCode: status, headers: [:], body: Data("{}".utf8))
                }
            ))
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.errorCategory, category)
        }
    }

    func testDiscoveryAndRefreshUseSameLocalConfigurationWithoutNetwork() async {
        for files in [[:], [OpenCodexAuthStore.configPath: "invalid"]] {
            let provider = OpenCodexProvider(
                authStore: OpenCodexAuthStore(files: FakeFiles(files), environment: FakeEnvironment()),
                usageClient: OpenCodexUsageClient(http: RoutingHTTPClient { _ in
                    XCTFail("Invalid or missing config must not reach the network")
                    return HTTPResponse(statusCode: 500, headers: [:], body: Data())
                })
            )
            let found = await provider.hasLocalCredentials()
            XCTAssertFalse(found)
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.errorCategory, files.isEmpty ? .notLoggedIn : .authInvalid)
        }
        let configured = OpenCodexProvider(authStore: authStore(), usageClient: OpenCodexUsageClient(
            http: RoutingHTTPClient { _ in
                XCTFail("Local credential discovery must not contact the hub")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        ))
        let found = await configured.hasLocalCredentials()
        XCTAssertTrue(found)
    }

    func testDescriptorsAndAcceptedLayoutDefaults() {
        let provider = OpenCodexProvider()
        let ids = ["codexSession", "codexWeekly", "claudeSession", "claudeWeekly", "grokWeekly",
                   "geminiSession", "geminiWeekly", "kiroMonthly", "trend", "today", "yesterday", "last30"]
            .map { "opencodex.\($0)" }
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), ids)
        XCTAssertTrue(Set(ids).isSubset(of: Set(DefaultLayout.metricIDs)))
        XCTAssertTrue(DefaultLayout.pinnedMetricIDs.filter { $0.hasPrefix("opencodex.") }.isEmpty)
        XCTAssertEqual(DefaultLayout.expandedMetricIDs.filter { $0.hasPrefix("opencodex.") }, Array(ids.suffix(5)))
        XCTAssertTrue(provider.provider.links.isEmpty)
        XCTAssertEqual(provider.widgetDescriptors.prefix(8).flatMap(\.limitResources).count, 8)
    }

    private func authStore() -> OpenCodexAuthStore {
        OpenCodexAuthStore(files: FakeFiles([
            OpenCodexAuthStore.configPath: #"{"baseURL":"http://127.0.0.1:10101/hub/","adminToken":"test-token"}"#
        ]), environment: FakeEnvironment())
    }
}
