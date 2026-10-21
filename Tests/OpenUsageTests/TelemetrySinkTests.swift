import XCTest
@testable import OpenUsage

/// Crash reporting remains mandatory even when optional provider analytics are disabled.
final class TelemetrySinkTests: XCTestCase {
    func testErrorAutocaptureStaysEnabledRegardlessOfOptionalAnalytics() {
        XCTAssertTrue(
            PostHogTelemetrySink.errorAutocaptureEnabled(optionalAnalyticsEnabled: true),
            "crash autocapture must stay on when optional analytics are enabled"
        )
        XCTAssertTrue(
            PostHogTelemetrySink.errorAutocaptureEnabled(optionalAnalyticsEnabled: false),
            "crash autocapture must stay on when optional analytics are disabled"
        )
    }

    /// This fork ships no PostHog token, so the sink stays inert and nothing reaches the upstream project.
    func testForkBuildShipsNoTelemetryToken() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OPENUSAGE_POSTHOG_TOKEN"] != nil,
                      "a local telemetry override is set")
        XCTAssertEqual(TelemetryConfig.token, TelemetryConfig.placeholderToken)
    }
}
