import XCTest
@testable import OpenUsage

/// The display-edge translator: English stays untouched without a table (the test runner and
/// `swift run`), and the shipped Korean table rebuilds value phrases in Korean word order.
final class L10nTests: XCTestCase {
    private var savedBundle: Bundle!

    override func setUp() {
        super.setUp()
        savedBundle = L10n.bundle
    }

    override func tearDown() {
        L10n.bundle = savedBundle
        super.tearDown()
    }

    func testWithoutTranslationsEverythingStaysEnglish() {
        L10n.bundle = Bundle(for: L10nTests.self)
        for value in ["65% left", "Resets in 3d 10h", "Resets today at 5:30 PM", "Today", "No data",
                      "$4.08 · 1.2M tokens", "Limit soon", "Claude"] {
            XCTAssertEqual(L10n.display(value), value)
        }
    }

    func testShippedKoreanTableTranslatesValuePhrases() throws {
        L10n.bundle = try koreanBundle()
        XCTAssertEqual(L10n.display("Today"), "오늘")
        XCTAssertEqual(L10n.display("65% left"), "65% 남음")
        XCTAssertEqual(L10n.display("Resets in 3d 10h"), "3일 10시간 후 초기화")
        XCTAssertEqual(L10n.display("Limit in 52m"), "52분 후 한도 도달")
        XCTAssertEqual(L10n.display("Resets today at 오전 5:30"), "오늘 오전 5:30 초기화")
        XCTAssertEqual(L10n.display("Resets 10월 10일 at 오전 6:30"), "10월 10일 오전 6:30 초기화")
        XCTAssertEqual(L10n.display("Limit soon"), "곧 한도 도달")
        XCTAssertEqual(L10n.display("$4.08 · 1.2M tokens"), "$4.08 · 1.2M 토큰")
        XCTAssertEqual(L10n.display("~338% over limit at reset"), "초기화 시 한도 약 338% 초과")
        XCTAssertEqual(L10n.display("Next update in 4m"), "4분 후 새로고침")
        XCTAssertEqual(L10n.display("Copy Cost Screenshot"), "비용 스크린샷 복사")
        XCTAssertEqual(L10n.duration("12d 18h"), "12일 18시간")
        // Positional placeholders keep the English capture order.
        XCTAssertEqual(L10n.format("Total cost %@ across %@ providers", "$12.34", "3"), "총비용 $12.34, 서비스 3개")
        XCTAssertEqual(L10n.display("Total cost $12.34 across 3 providers"), "총비용 $12.34, 서비스 3개")
        XCTAssertEqual(L10n.display("Total tokens 1.2M across 3 providers"), "총 토큰 1.2M, 서비스 3개")
        XCTAssertEqual(L10n.display("Blended cost per megatoken $2.50 across 3 providers"), "100만 토큰당 평균 비용 $2.50, 서비스 3개")
        // Proper names and unknown text pass through.
        XCTAssertEqual(L10n.display("Claude"), "Claude")
        XCTAssertEqual(L10n.display("gpt-6-astra"), "gpt-6-astra")
    }

    func testShippedTableKeepsFormatPlaceholdersBalanced() throws {
        let url = Self.stringsURL
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        XCTAssertFalse(table.isEmpty)
        for (key, value) in table {
            XCTAssertFalse(value.isEmpty, key)
            for token in ["%@", "%lld"] {
                XCTAssertEqual(key.components(separatedBy: token).count, value.components(separatedBy: token).count, key)
            }
        }
    }

    private static var stringsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/Localization/ko.lproj/Localizable.strings")
    }

    /// A throwaway bundle whose only localization is the shipped Korean table.
    private func koreanBundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-l10n-\(UUID().uuidString).bundle", isDirectory: true)
        let lproj = root.appendingPathComponent("ko.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.stringsURL, to: lproj.appendingPathComponent("Localizable.strings"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try XCTUnwrap(Bundle(url: root))
    }
}
