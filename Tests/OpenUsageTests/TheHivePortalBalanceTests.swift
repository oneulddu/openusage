import XCTest
@testable import OpenUsage

final class TheHivePortalBalanceTests: XCTestCase {
    func testReadsUSDAndPreservesZeroAndNegativeBalances() throws {
        for (raw, expected): (Any, Double) in [(12.34, 12.34), ("0.00", 0), (" -0.15 ", -0.15)] {
            XCTAssertEqual(try TheHivePortalBalance.parse(response(raw)), expected)
        }
    }

    func testRejectsMissingMalformedAndNonDollarBalances() {
        for raw: Any in [NSNull(), true, "unknown", "NaN", "Infinity", [1, 2]] {
            XCTAssertThrowsError(try TheHivePortalBalance.parse(response(raw)))
        }
        XCTAssertThrowsError(try TheHivePortalBalance.parse(response(10, currency: "EUR")))
        XCTAssertThrowsError(try TheHivePortalBalance.parse(["status": 200, "body": ["data": [:]]]))
    }

    func testExpiredLoginIsDistinctFromBadResponse() {
        for status in [401, 403] {
            XCTAssertThrowsError(try TheHivePortalBalance.parse(["status": status])) { error in
                guard case TheHivePortalBalance.Failure.signInRequired = error else { return XCTFail("Expected login requirement") }
            }
        }
        XCTAssertThrowsError(try TheHivePortalBalance.parse(["status": 500]))
    }

    func testOrganizationMustComeFromExactPortalAndSafePath() {
        XCTAssertEqual(TheHivePortalBalance.organization(in: URL(string: "https://portal.thehive.ai/organization/123/dashboard")), "123")
        for raw in ["https://evil.example/organization/123/dashboard",
                    "https://portal.thehive.ai.evil.example/organization/123/dashboard",
                    "http://portal.thehive.ai/organization/123/dashboard",
                    "https://portal.thehive.ai:8443/organization/123/dashboard",
                    "https://portal.thehive.ai/organization/a%2Fb/dashboard",
                    "https://portal.thehive.ai/login"] {
            XCTAssertNil(TheHivePortalBalance.organization(in: URL(string: raw)), raw)
        }
        XCTAssertFalse(TheHivePortalBalance.validOrganization("../billing"))
        XCTAssertFalse(TheHivePortalBalance.validOrganization(String(repeating: "a", count: 129)))
    }

    func testTopLevelNavigationIsRestrictedToHiveAndLoginProviders() {
        for url in ["https://portal.thehive.ai/login", "https://accounts.google.com", "https://github.com/login"] {
            XCTAssertTrue(TheHivePortalBalance.allowedNavigation(URL(string: url)!))
        }
        for url in ["http://portal.thehive.ai", "https://thehive.ai.evil.example", "file:///etc/passwd",
                    "https://portal.thehive.ai:8443", "https://secret@portal.thehive.ai"] {
            XCTAssertFalse(TheHivePortalBalance.allowedNavigation(URL(string: url)!))
        }
    }

    @MainActor
    func testUnconnectedSessionShowsSignInWithoutOpeningWebKit() async throws {
        let name = "OpenUsageTests.TheHive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = TheHivePortalSession(defaults: defaults)
        let line = await session.creditLine()
        guard case .badge(let label, let text, _, _) = line else { return XCTFail("Expected sign-in state") }
        XCTAssertEqual(label, "TheHive Credits")
        XCTAssertEqual(text, "Sign In Required")
        XCTAssertNil(session.balance)
    }

    private func response(_ balance: Any, currency: String = "USD") -> [String: Any] {
        ["status": 200, "body": ["data": ["billing_info": ["balance": balance, "currency": currency]]]]
    }
}
