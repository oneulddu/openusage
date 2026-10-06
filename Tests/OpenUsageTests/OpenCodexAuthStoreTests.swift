import XCTest
@testable import OpenUsage

final class OpenCodexAuthStoreTests: XCTestCase {
    func testExplicitConfigWinsAndTrimsValues() throws {
        let auth = try OpenCodexAuthStore(files: FakeFiles([
            OpenCodexAuthStore.configPath: #"{"baseURL":" http://127.0.0.1:10101/ ","adminToken":" configured \n"}"#,
            "/hub/admin-api-token": "fallback"
        ]), environment: FakeEnvironment(["OPENCODEX_HOME": "/hub"])).load()
        XCTAssertEqual(auth.baseURL.absoluteString, "http://127.0.0.1:10101")
        XCTAssertEqual(auth.adminToken, "configured")
    }

    func testTokenFileAndInlineTokenPrecedence() throws {
        for (inline, expected) in [("", "file-token"), (#", "adminToken":"inline-token""#, "inline-token")] {
            let config = #"{"baseURL":"http://localhost:10101","adminTokenFile":" ~/private/token ""# + inline + "}"
            let auth = try OpenCodexAuthStore(files: FakeFiles([
                OpenCodexAuthStore.configPath: config, "~/private/token": " file-token\n"
            ]), environment: FakeEnvironment()).load()
            XCTAssertEqual(auth.adminToken, expected)
        }
    }

    func testLocalHubHomeOverrideAndDefault() throws {
        for (environment, path) in [(["OPENCODEX_HOME": " /custom/hub/ "], "/custom/hub/admin-api-token"),
                                     ([:], "~/.opencodex/admin-api-token")] {
            let auth = try OpenCodexAuthStore(files: FakeFiles([path: " local-token\n"]),
                                             environment: FakeEnvironment(environment)).load()
            XCTAssertEqual(auth.adminToken, "local-token")
            XCTAssertEqual(auth.baseURL.absoluteString, "http://127.0.0.1:10100")
        }
    }

    func testBrokenExplicitConfigurationDoesNotFallBack() {
        for config in ["not JSON", #"{"baseURL":"file:///tmp/hub","adminToken":"private"}"#,
                       #"{"baseURL":"http://localhost:10101?secret=private","adminToken":"private"}"#] {
            let store = OpenCodexAuthStore(files: FakeFiles([
                OpenCodexAuthStore.configPath: config, "~/.opencodex/admin-api-token": "fallback"
            ]), environment: FakeEnvironment())
            XCTAssertThrowsError(try store.load()) {
                XCTAssertEqual($0 as? OpenCodexAuthError, .invalidConfiguration)
                XCTAssertFalse($0.localizedDescription.contains("private"))
            }
        }
    }

    func testMissingAndBlankTokensAreNotConfigured() {
        for files in [[:], ["~/.opencodex/admin-api-token": " \n"],
                      [OpenCodexAuthStore.configPath: #"{"baseURL":"http://localhost:10101","adminTokenFile":"~/missing"}"#,
                       "~/.opencodex/admin-api-token": "fallback"]] {
            XCTAssertThrowsError(try OpenCodexAuthStore(files: FakeFiles(files), environment: FakeEnvironment()).load()) {
                XCTAssertEqual($0 as? OpenCodexAuthError, .notConfigured)
            }
        }
    }

    func testUnreadableFilesHaveCredentialAccessError() {
        XCTAssertThrowsError(try OpenCodexAuthStore(files: UnreadableOpenCodexFiles(), environment: FakeEnvironment()).load()) {
            XCTAssertEqual($0 as? OpenCodexAuthError, .credentialAccess)
        }
    }
}

private struct UnreadableOpenCodexFiles: TextFileAccessing {
    func exists(_ path: String) -> Bool { true }
    func readText(_ path: String) throws -> String { throw CocoaError(.fileReadNoPermission) }
    func writeText(_ path: String, _ text: String) throws { XCTFail("Unexpected write") }
    func remove(_ path: String) throws { XCTFail("Unexpected removal") }
}
