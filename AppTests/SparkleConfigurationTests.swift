/* Update trust boundary; no network or real updater installation. GPL-3.0-or-later. */
import XCTest

final class SparkleConfigurationTests: XCTestCase {
    @MainActor func testAcceptsHTTPSFeedWithEd25519PublicKey() throws {
        try SparkleUpdateController.validateConfiguration([
            "SUFeedURL": "https://github.com/maclifevn/MDriveHealth/releases/latest/download/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()
        ])
    }
    @MainActor func testRejectsMissingTrustKeyAndUnsafeFeed() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let cases: [[String: Any]] = [
            [:], ["SUFeedURL": "https://example.com/appcast.xml"],
            ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "invalid"],
            ["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": key],
            ["SUFeedURL": "https://user:password@example.com/appcast.xml", "SUPublicEDKey": key],
            ["SUFeedURL": "https://example.com/appcast.xml#fragment", "SUPublicEDKey": key]
        ]
        for info in cases {
            XCTAssertThrowsError(try SparkleUpdateController.validateConfiguration(info))
        }
    }
}
