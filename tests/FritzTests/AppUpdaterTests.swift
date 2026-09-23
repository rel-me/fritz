import XCTest
import Fritz
import FritzUpdates

final class AppUpdaterTests: XCTestCase {
    func testConfigurationRequiresHTTPSFeedAndPublicKey() {
        let configuration = AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://updates.example.test/appcast.xml",
            "SUPublicEDKey": "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=",
        ])

        XCTAssertTrue(configuration.isConfigured)
        XCTAssertEqual(configuration.feedURL?.absoluteString, "https://updates.example.test/appcast.xml")
        XCTAssertEqual(
            configuration.publicEDKey,
            "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="
        )
    }

    func testConfigurationRejectsIncompleteValues() {
        XCTAssertFalse(AppUpdateConfiguration(infoDictionary: nil).isConfigured)
        XCTAssertFalse(AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "http://updates.example.test/appcast.xml",
            "SUPublicEDKey": "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=",
        ]).isConfigured)
        XCTAssertFalse(AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://updates.example.test/appcast.xml",
            "SUPublicEDKey": "   ",
        ]).isConfigured)
        XCTAssertFalse(AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://updates.example.test/appcast.xml",
            "SUPublicEDKey": "not-a-valid-ed25519-key",
        ]).isConfigured)
    }

    func testStartupStateBlocksOnlyWhileCheckingOrForRequiredUpdate() {
        XCTAssertTrue(AppUpdateStartupState.notConfigured.hasCompletedCheck)
        XCTAssertTrue(AppUpdateStartupState.notConfigured.allowsAppUse)
        XCTAssertFalse(AppUpdateStartupState.pending.hasCompletedCheck)
        XCTAssertFalse(AppUpdateStartupState.pending.allowsAppUse)
        XCTAssertFalse(AppUpdateStartupState.checking.hasCompletedCheck)
        XCTAssertFalse(AppUpdateStartupState.checking.allowsAppUse)

        XCTAssertTrue(AppUpdateStartupState.current.hasCompletedCheck)
        XCTAssertTrue(AppUpdateStartupState.current.allowsAppUse)
        XCTAssertTrue(AppUpdateStartupState.failed.hasCompletedCheck)
        XCTAssertTrue(AppUpdateStartupState.failed.allowsAppUse)

        let optionalUpdate = AppUpdateStartupState.available(
            version: "2.0",
            requiresUpgrade: false
        )
        XCTAssertTrue(optionalUpdate.hasCompletedCheck)
        XCTAssertTrue(optionalUpdate.allowsAppUse)
        XCTAssertNil(optionalUpdate.requiredVersion)

        let requiredUpdate = AppUpdateStartupState.available(
            version: "2.0",
            requiresUpgrade: true
        )
        XCTAssertTrue(requiredUpdate.hasCompletedCheck)
        XCTAssertFalse(requiredUpdate.allowsAppUse)
        XCTAssertEqual(requiredUpdate.requiredVersion, "2.0")
    }

    func testUpdateChannelsMapToSparkleChannels() {
        XCTAssertEqual(AppUpdateChannel.release.allowedSparkleChannels, [])
        XCTAssertEqual(AppUpdateChannel.beta.allowedSparkleChannels, ["beta"])
        XCTAssertEqual(AppUpdateChannel.dev.allowedSparkleChannels, ["beta", "dev"])
    }

    @MainActor
    func testUpdaterExposesSparkleStartupCallbacks() {
        let updater = AppUpdater(bundle: Bundle(for: Self.self))

        XCTAssertTrue(
            updater.responds(to: NSSelectorFromString("updater:didFindValidUpdate:"))
        )
        XCTAssertTrue(
            updater.responds(to: NSSelectorFromString("updaterDidNotFindUpdate:error:"))
        )
        XCTAssertTrue(
            updater.responds(to: NSSelectorFromString("allowedChannelsForUpdater:"))
        )
        XCTAssertTrue(
            updater.responds(
                to: NSSelectorFromString(
                    "updater:didFinishUpdateCycleForUpdateCheck:error:"
                )
            )
        )
    }

    @MainActor
    func testUpdaterDoesNotInterceptSparkleWindowPresentation() {
        let updater = AppUpdater(bundle: Bundle(for: Self.self))

        XCTAssertFalse(
            updater.responds(to: NSSelectorFromString("standardUserDriverWillShowModalAlert"))
        )
    }
}
