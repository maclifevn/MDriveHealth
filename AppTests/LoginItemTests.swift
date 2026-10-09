/* SDK state is authoritative; no real ServiceManagement mutation in tests. GPL-3.0-or-later. */
import XCTest

private struct LoginItemFixtureError: LocalizedError {
    var errorDescription: String? { "fixture registration failed" }
}
@MainActor final class LoginItemFixtureService: LoginItemManaging {
    var status: LoginItemStatus
    var nextStatus: LoginItemStatus?
    var failure: Error?
    var hold = false
    var requests: [Bool] = []
    var settingsOpens = 0
    private(set) var continuation: CheckedContinuation<Void, Never>?
    init(status: LoginItemStatus = .notRegistered) { self.status = status }
    func setEnabled(_ enabled: Bool) async throws {
        requests.append(enabled)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let nextStatus { status = nextStatus }
        else if failure == nil { status = enabled ? .enabled : .notRegistered }
        if let failure { throw failure }
    }
    func release() { continuation?.resume(); continuation = nil; hold = false }
    func openSettings() { settingsOpens += 1 }
    func fail() { failure = LoginItemFixtureError() }
}

final class LoginItemTests: XCTestCase {
    @MainActor func testInitialStatesDistinguishRegistrationFromApprovalWithoutMutatingSDK() {
        for status in [LoginItemStatus.notRegistered, .enabled, .requiresApproval, .notFound, .unknown] {
            let service = LoginItemFixtureService(status: status), controller = LoginItemController(service: service)
            XCTAssertEqual(controller.status, status)
            XCTAssertEqual(controller.status.isRequested, status == .enabled || status == .requiresApproval)
            XCTAssertEqual(controller.canChange, status != .notFound && status != .unknown)
            XCTAssertTrue(service.requests.isEmpty); XCTAssertEqual(service.settingsOpens, 0)
        }
    }
    @MainActor func testEnableThenDisableUsesActualSDKState() async {
        let service = LoginItemFixtureService(), controller = LoginItemController(service: service)
        controller.setRequested(true); await controller.waitForCompletion()
        XCTAssertEqual(controller.status, .enabled); XCTAssertNil(controller.errorMessage)
        controller.setRequested(false); await controller.waitForCompletion()
        XCTAssertEqual(controller.status, .notRegistered); XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(service.requests, [true, false]); XCTAssertFalse(controller.isBusy)
    }
    @MainActor func testPendingApprovalIsNeverReportedAsEnabledOrAutoOpened() async {
        let service = LoginItemFixtureService(); service.nextStatus = .requiresApproval
        let controller = LoginItemController(service: service)
        controller.setRequested(true); await controller.waitForCompletion()
        XCTAssertEqual(controller.status, .requiresApproval); XCTAssertTrue(controller.status.isRequested)
        XCTAssertNotEqual(controller.status, .enabled); XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(service.settingsOpens, 0)
        controller.openSettings(); XCTAssertEqual(service.settingsOpens, 1)
        controller.refresh(); XCTAssertEqual(service.requests, [true])
    }
    @MainActor func testRegistrationFailureKeepsToggleOffAndFormatsError() async {
        let service = LoginItemFixtureService(); service.fail()
        let controller = LoginItemController(service: service)
        controller.setRequested(true); await controller.waitForCompletion()
        XCTAssertEqual(controller.status, .notRegistered); XCTAssertFalse(controller.status.isRequested)
        XCTAssertTrue(controller.errorMessage?.contains("fixture registration failed") == true)
        XCTAssertFalse(controller.errorMessage?.contains("%@") == true); XCTAssertFalse(controller.isBusy)
    }
    @MainActor func testUnregisterFailureKeepsActualEnabledState() async {
        let service = LoginItemFixtureService(status: .enabled); service.fail()
        let controller = LoginItemController(service: service)
        controller.setRequested(false); await controller.waitForCompletion()
        XCTAssertEqual(controller.status, .enabled); XCTAssertNotNil(controller.errorMessage)
    }
    @MainActor func testErrorWithPendingApprovalPreservesDiagnosticAndAuthorizationAction() async {
        let service = LoginItemFixtureService(); service.fail(); service.nextStatus = .requiresApproval
        let controller = LoginItemController(service: service)
        controller.setRequested(true); await controller.waitForCompletion()
        XCTAssertEqual(controller.status, .requiresApproval); XCTAssertNotNil(controller.errorMessage)
        controller.openSettings(); XCTAssertEqual(service.settingsOpens, 1)
    }
    @MainActor func testAlreadyAppliedRaceUsesConfirmedStateInsteadOfFalseFailure() async {
        let service = LoginItemFixtureService(); service.fail(); service.nextStatus = .enabled
        let controller = LoginItemController(service: service)
        controller.setRequested(true); await controller.waitForCompletion()
        XCTAssertEqual(controller.status, .enabled); XCTAssertNil(controller.errorMessage)
    }
    @MainActor func testRepeatedCurrentChoiceNeverResubmitsRegistration() async {
        for status in [LoginItemStatus.notRegistered, .enabled, .requiresApproval] {
            let service = LoginItemFixtureService(status: status), controller = LoginItemController(service: service)
            controller.setRequested(status.isRequested); await controller.waitForCompletion()
            XCTAssertTrue(service.requests.isEmpty)
        }
    }
    @MainActor func testExternalRevocationAndApprovalOnlyRefreshWithoutMutation() {
        let service = LoginItemFixtureService(status: .enabled), controller = LoginItemController(service: service)
        service.status = .requiresApproval; controller.refresh(); XCTAssertEqual(controller.status, .requiresApproval)
        service.status = .enabled; controller.refresh(); XCTAssertEqual(controller.status, .enabled)
        service.status = .notRegistered; controller.refresh(); XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertTrue(service.requests.isEmpty); XCTAssertEqual(service.settingsOpens, 0)
    }
    @MainActor func testSuccessfulCallWithUnchangedStatusCannotClaimSuccess() async {
        let service = LoginItemFixtureService(); service.nextStatus = .notRegistered
        let controller = LoginItemController(service: service)
        controller.setRequested(true); await controller.waitForCompletion()
        XCTAssertFalse(controller.status.isRequested); XCTAssertNotNil(controller.errorMessage)
    }
    @MainActor func testUnavailableStatusBlocksSDKChangesUntilFreshStatusExists() async {
        for status in [LoginItemStatus.notFound, .unknown] {
            let service = LoginItemFixtureService(status: status), controller = LoginItemController(service: service)
            controller.setRequested(true); await controller.waitForCompletion(); XCTAssertTrue(service.requests.isEmpty)
            service.status = .notRegistered; controller.refresh()
            controller.setRequested(true); await controller.waitForCompletion(); XCTAssertEqual(service.requests, [true])
        }
    }
    @MainActor func testOwnedOperationBlocksDuplicatesAndShutdownWaitsWithoutCancellingSDK() async throws {
        let service = LoginItemFixtureService(); service.hold = true
        let controller = LoginItemController(service: service)
        defer { service.release() }
        controller.setRequested(true)
        for _ in 0..<1000 { if service.continuation != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(service.continuation); XCTAssertTrue(controller.isBusy)
        controller.setRequested(false); controller.refresh(); controller.beginShutdown(); controller.openSettings()
        XCTAssertEqual(service.requests, [true]); XCTAssertEqual(service.settingsOpens, 0)
        service.release(); await controller.waitForCompletion()
        XCTAssertEqual(controller.status, .enabled); XCTAssertTrue(controller.isShuttingDown)
        controller.setRequested(false); XCTAssertEqual(service.requests, [true])
        controller.resumeAfterShutdown(); controller.setRequested(false); await controller.waitForCompletion()
        XCTAssertEqual(service.requests, [true, false]); XCTAssertEqual(controller.status, .notRegistered)
    }
}
