import XCTest
@testable import OpenUsage

final class ICloudDriveSyncRootTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-sync-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    func testContainerWinsWhenTheBuildHasOne() throws {
        let container = URL(fileURLWithPath: "/tmp/container", isDirectory: true)
        XCTAssertEqual(try ICloudUsageHistoryFileStore.syncRoot(container: container, home: home), container)
    }

    func testFallsBackToICloudDriveWithoutAContainer() throws {
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        XCTAssertEqual(try ICloudUsageHistoryFileStore.syncRoot(container: nil, home: home).standardizedFileURL,
                       drive.standardizedFileURL)
    }

    func testUnavailableWithoutContainerOrICloudDrive() {
        XCTAssertThrowsError(try ICloudUsageHistoryFileStore.syncRoot(container: nil, home: home)) { error in
            guard case ICloudUsageSyncError.unavailable = error else {
                return XCTFail("expected .unavailable, got \(error)")
            }
        }
    }
}
