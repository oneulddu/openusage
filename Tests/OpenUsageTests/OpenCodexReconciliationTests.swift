import XCTest
@testable import OpenUsage

final class OpenCodexReconciliationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_288_600)

    func testOnlyMatchingHubRequestIsRemovedAndDirectCostRemains() throws {
        let routed = event()
        var direct = routed
        direct.timestamp = now.addingTimeInterval(60)
        direct.input = 250
        direct.total = 270
        let request = try XCTUnwrap(OpenCodexUsageReconciler.Request(row()))
        let result = OpenCodexUsageReconciler.filter(events: [routed, direct], requests: [request])
        XCTAssertEqual(result.excluded, 1)
        XCTAssertEqual(result.events, [direct])
        XCTAssertEqual(result.warning, OpenCodexUsageReconciler.incompleteWarning)
        let scan = CodexLogUsageScanner.aggregate(events: result.events, since: now.addingTimeInterval(-60),
                                                  pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 270)
    }

    func testModelPrefixAloneNeverExcludesAnEvent() {
        var routedLooking = event()
        routedLooking.model = "main/gpt-6-astra"
        let result = OpenCodexUsageReconciler.filter(events: [routedLooking], requests: [])
        XCTAssertEqual(result.events, [routedLooking])
    }

    func testIdentityTokensModelAndTimeMustAllMatch() throws {
        let request = try XCTUnwrap(OpenCodexUsageReconciler.Request(row()))
        var variants = [CodexLogUsageScanner.Event]()
        var e = event(); e.sessionID = "another-thread"; variants.append(e)
        e = event(); e.sessionID = nil; variants.append(e)
        e = event(); e.input += 1; variants.append(e)
        e = event(); e.output += 1; variants.append(e)
        e = event(); e.model = "other-model"; variants.append(e)
        e = event(); e.timestamp = now.addingTimeInterval(60); variants.append(e)
        e = event(); e.timestamp = now.addingTimeInterval(-60); variants.append(e)
        XCTAssertEqual(OpenCodexUsageReconciler.filter(events: variants, requests: [request]).events, variants)
    }

    func testAmbiguousRequestsAndCompetingLocalEventsAreRetained() throws {
        let first = try XCTUnwrap(OpenCodexUsageReconciler.Request(row()))
        var secondRow = row(); secondRow["requestId"] = "ocx-second"
        let second = try XCTUnwrap(OpenCodexUsageReconciler.Request(secondRow))
        XCTAssertEqual(OpenCodexUsageReconciler.filter(events: [event()], requests: [first, second]).excluded, 0)
        var competing = event(); competing.timestamp = now.addingTimeInterval(1)
        XCTAssertEqual(OpenCodexUsageReconciler.filter(events: [event(), competing], requests: [first]).excluded, 0)
    }

    func testCopiedEventsAndDuplicateRequestRowsAreCountedOnce() throws {
        let request = try XCTUnwrap(OpenCodexUsageReconciler.Request(row()))
        let result = OpenCodexUsageReconciler.filter(events: [event(), event()], requests: [request, request])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.excluded, 1)
        XCTAssertNil(result.warning)
    }

    func testParentConversationCanMatchButReplayedMetadataCannotReplaceChildIdentity() throws {
        var child = event(); child.sessionID = "child"; child.parentSessionID = "thread"
        let request = try XCTUnwrap(OpenCodexUsageReconciler.Request(row()))
        XCTAssertEqual(OpenCodexUsageReconciler.filter(events: [child], requests: [request]).excluded, 1)
        let metadata = #"{"type":"session_meta","timestamp":"2026-10-06T12:00:00Z","payload":{"id":"child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#
        let replay = #"{"type":"session_meta","payload":{"id":"parent"}}"#
        let start = #"{"type":"event_msg","timestamp":"2026-10-06T12:00:01Z","payload":{"type":"task_started","started_at":1791288001}}"#
        let token = CodexLogFixture.tokenCount(timestamp: "2026-10-06T12:00:02Z",
                                              last: CodexLogFixture.usage(input: 100, output: 20))
        let events = CodexLogUsageScanner.parseFile(Data([metadata, replay, start, token].joined(separator: "\n").utf8))
        XCTAssertEqual(events.first?.sessionID, "child")
        XCTAssertEqual(events.first?.parentSessionID, "parent")
        XCTAssertEqual(OpenCodexUsageReconciler.digest("thread"), "39200d1e8a8dbbb6d7bcea51e02b99f0")
    }

    func testFailedRequestsAndInvalidUsageAreNotMatchEvidence() {
        var failed = row(); failed["status"] = 500
        XCTAssertNil(OpenCodexUsageReconciler.Request(failed))
        for input: Any in [-1, 1.5, true] {
            var invalid = row(); invalid["usage"] = ["inputTokens": input, "outputTokens": 20]
            XCTAssertNil(OpenCodexUsageReconciler.Request(invalid))
        }
    }

    func testPaginationFindsRequestOnSecondPage() async throws {
        let secondPage = Self.response(["entries": [row()], "hasMore": false, "index": ["lastError": ""]])
        let summary = Self.response(summary())
        let reconciler = configured { request in
            if request.url.path == "/api/usage" { return summary }
            XCTAssertEqual(request.url.path, "/api/request-history")
            XCTAssertEqual(request.headers["Authorization"], "Bearer fixture-token")
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "conversationId" }?.value, OpenCodexUsageReconciler.digest("thread"))
            if query.contains(where: { $0.name == "cursor" && $0.value == "page-two" }) {
                return secondPage
            }
            return Self.response(["entries": [], "hasMore": true, "nextCursor": "page-two"])
        }
        let result = await reconciler.reconcile(events: [event()], since: now.addingTimeInterval(-60), now: now)
        XCTAssertEqual(result.excluded, 1)
        XCTAssertNil(result.warning)
    }

    func testBrokenPaginationOrUnavailableHubPreservesLocalHistory() async {
        let summary = Self.response(summary())
        for kind in ["cursor", "transport", "index"] {
            let reconciler = configured { request in
                if request.url.path == "/api/usage" { return summary }
                if kind == "transport" { return HTTPResponse(statusCode: 503, headers: [:], body: Data()) }
                if kind == "index" { return Self.response(["entries": [], "hasMore": false, "index": ["lastError": "broken"]]) }
                return Self.response(["entries": [], "hasMore": true, "nextCursor": "same"])
            }
            let result = await reconciler.reconcile(events: [event()], since: now.addingTimeInterval(-60), now: now)
            XCTAssertEqual(result.events, [event()])
            XCTAssertEqual(result.excluded, 0)
            XCTAssertEqual(result.warning, OpenCodexUsageReconciler.unavailableWarning)
        }
    }

    func testNotConfiguredDoesNotContactNetwork() async {
        let reconciler = OpenCodexUsageReconciler(
            authStore: OpenCodexAuthStore(files: FakeFiles([:]), environment: FakeEnvironment()),
            client: OpenCodexUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("No configured hub")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }))
        let result = await reconciler.reconcile(events: [event()], since: now.addingTimeInterval(-60), now: now)
        XCTAssertEqual(result.events, [event()])
        XCTAssertNil(result.warning)
    }

    func testHubOutsideSpendWindowCannotRemoveLocalUsage() async {
        var summaryObject = summary()
        summaryObject["since"] = now.timeIntervalSince1970 * 1000
        let summaryResponse = Self.response(summaryObject)
        let historyResponse = Self.response(["entries": [row()], "hasMore": false])
        let reconciler = configured { request in
            request.url.path == "/api/usage" ? summaryResponse : historyResponse
        }
        let result = await reconciler.reconcile(events: [event()], since: now.addingTimeInterval(-60), now: now)
        XCTAssertEqual(result.events, [event()])
        XCTAssertEqual(result.excluded, 0)
    }

    func testTotalsDeltasAreCalculatedBeforeExcludingHubEvents() throws {
        let metadata = #"{"type":"session_meta","payload":{"id":"thread"}}"#
        let model = CodexLogFixture.turnContext(timestamp: "2026-10-06T12:09:00Z", model: "gpt-5.2")
        let first = CodexLogFixture.tokenCount(timestamp: "2026-10-06T12:10:00Z",
                                              totals: CodexLogFixture.usage(input: 100, output: 20))
        let next = CodexLogFixture.tokenCount(timestamp: "2026-10-06T12:11:00Z",
                                             totals: CodexLogFixture.usage(input: 350, output: 70))
        let parsed = CodexLogUsageScanner.parseFile(Data([metadata, model, first, next].joined(separator: "\n").utf8))
        let request = try XCTUnwrap(OpenCodexUsageReconciler.Request(row()))
        let result = OpenCodexUsageReconciler.filter(events: parsed, requests: [request])
        XCTAssertEqual(result.excluded, 1)
        XCTAssertEqual(result.events.map(\.input), [250])
        XCTAssertEqual(result.events.map(\.output), [50])
    }

    private func event() -> CodexLogUsageScanner.Event {
        .init(timestamp: now, model: "gpt-5.2", input: 100, cached: 0, output: 20, reasoning: 0,
              total: 120, sessionID: "thread")
    }

    private func row() -> [String: Any] {
        ["requestId": "ocx-test", "conversationId": OpenCodexUsageReconciler.digest("thread"),
         "timestamp": (now.timeIntervalSince1970 - 10) * 1000, "durationMs": 10000,
         "status": 200, "requestedModel": "gpt-5.2", "usage": ["inputTokens": 100, "outputTokens": 20]]
    }

    private func summary() -> [String: Any] {
        ["since": (now.timeIntervalSince1970 - 86400) * 1000,
         "generatedAt": now.timeIntervalSince1970 * 1000,
         "days": [["date": "2026-10-06", "totalTokens": 120, "estimatedCostUsd": 0.5]]]
    }

    private func configured(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) -> OpenCodexUsageReconciler {
        OpenCodexUsageReconciler(authStore: OpenCodexAuthStore(files: FakeFiles([
            OpenCodexAuthStore.configPath: #"{"baseURL":"http://127.0.0.1:10101","adminToken":"fixture-token"}"#
        ]), environment: FakeEnvironment()), client: OpenCodexUsageClient(http: RoutingHTTPClient(handler: handler)))
    }

    private static func response(_ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: object))
    }
}
