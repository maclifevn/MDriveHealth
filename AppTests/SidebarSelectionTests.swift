/* Discovery, disconnect and explicit navigation contracts. GPL-3.0-or-later. */
import XCTest

final class SidebarSelectionTests: XCTestCase {
    func testStartupWaitsForDiscoveryThenChoosesFleet() {
        var selection = SidebarSelection()
        selection.reconcile(driveIDs: [], batteryAvailable: false, discoverySettled: false)
        XCTAssertNil(selection.item)
        selection.reconcile(driveIDs: [11], batteryAvailable: false, discoverySettled: true)
        XCTAssertEqual(selection.item, .allDrives)
    }

    func testAutomaticEmptyFleetDefaultChangesAfterDriveAppears() {
        var selection = SidebarSelection()
        selection.reconcile(driveIDs: [], batteryAvailable: false, discoverySettled: true)
        XCTAssertEqual(selection.item, .memory)
        selection.reconcile(driveIDs: [11], batteryAvailable: false, discoverySettled: false)
        XCTAssertEqual(selection.item, .memory)
        selection.reconcile(driveIDs: [11], batteryAvailable: false, discoverySettled: true)
        XCTAssertEqual(selection.item, .allDrives)
    }

    func testExplicitSystemAndOverviewChoicesSurviveFleetChanges() {
        for item in [SidebarItem.memory, .sensors, .allDrives] {
            var selection = SidebarSelection(); selection.choose(item)
            selection.reconcile(driveIDs: [11], batteryAvailable: true, discoverySettled: true)
            selection.reconcile(driveIDs: [], batteryAvailable: false, discoverySettled: true)
            XCTAssertEqual(selection.item, item); XCTAssertTrue(selection.isExplicit)
        }
    }

    func testIntermediateRefreshDoesNotInvalidateDriveButDisconnectDoes() {
        var selection = SidebarSelection(); selection.choose(.drive(11))
        selection.reconcile(driveIDs: [], batteryAvailable: false, discoverySettled: false)
        XCTAssertEqual(selection.item, .drive(11))
        selection.reconcile(driveIDs: [12], batteryAvailable: false, discoverySettled: true)
        XCTAssertEqual(selection.item, .allDrives); XCTAssertFalse(selection.isExplicit)
        selection.choose(.drive(12))
        selection.reconcile(driveIDs: [], batteryAvailable: false, discoverySettled: true)
        XCTAssertEqual(selection.item, .memory)
    }

    func testRetainedFleetAfterScanFailurePreservesSelection() {
        var selection = SidebarSelection(); selection.choose(.drive(11))
        selection.reconcile(driveIDs: [11], batteryAvailable: false, discoverySettled: true)
        XCTAssertEqual(selection.item, .drive(11))
    }

    func testUnavailableBatteryFallsBackAfterSettledDiscovery() {
        var selection = SidebarSelection(); selection.choose(.battery)
        selection.reconcile(driveIDs: [11], batteryAvailable: true, discoverySettled: true)
        XCTAssertEqual(selection.item, .battery)
        selection.reconcile(driveIDs: [11], batteryAvailable: false, discoverySettled: true)
        XCTAssertEqual(selection.item, .allDrives)
    }

    func testRequestedIDWaitsAndNeverMapsToAnotherDrive() {
        var selection = SidebarSelection()
        XCTAssertEqual(selection.requestDrive(11, driveIDs: [11], discoverySettled: false), .waiting)
        XCTAssertNil(selection.item)
        XCTAssertEqual(selection.requestDrive(11, driveIDs: [12], discoverySettled: true), .unavailable)
        XCTAssertNil(selection.item)
        XCTAssertEqual(selection.requestDrive(11, driveIDs: [11, 12], discoverySettled: true), .selected)
        selection.reconcile(driveIDs: [11, 12], batteryAvailable: false, discoverySettled: true)
        XCTAssertEqual(selection.item, .drive(11)); XCTAssertTrue(selection.isExplicit)
    }
}
