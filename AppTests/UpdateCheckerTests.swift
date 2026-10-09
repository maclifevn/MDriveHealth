/* SemVer, untrusted release metadata and cancellable URLSession fixtures. GPL-3.0-or-later. */
import XCTest
import Foundation

private func updateMetadata(version: String = "1.2.3", assets: [[String: Any]]? = nil, changes: [String: Any] = [:]) throws -> Data {
    let tag = "v" + version
    var object: [String: Any] = ["tag_name": tag, "html_url": "https://github.com/maclifevn/MDriveHealth/releases/tag/\(tag)", "draft": false, "prerelease": false,
                               "assets": assets ?? [updateAsset(version: version)]]
    object.merge(changes) { _, new in new }
    return try JSONSerialization.data(withJSONObject: object)
}
private func updateAsset(version: String = "1.2.3", name: String? = nil, url: String? = nil) -> [String: Any] {
    let filename = name ?? "MDriveHealth-\(version).dmg"
    return ["name": filename, "browser_download_url": url ?? "https://github.com/maclifevn/MDriveHealth/releases/download/v\(version)/\(filename)", "state": "uploaded", "size": 1000]
}
private actor UpdateFetchFixture: UpdateFetching {
    let response: UpdateHTTPResponse
    let held: Bool
    let error: URLError?
    private(set) var calls = 0, cancellations = 0
    private(set) var request: URLRequest?
    init(data: Data = Data(), status: Int = 200, url: URL = UpdateChecker.endpoint, held: Bool = false, error: URLError? = nil) {
        response = .init(data: data, statusCode: status, url: url); self.held = held; self.error = error
    }
    func fetch(_ request: URLRequest, maximumBytes: Int) async throws -> UpdateHTTPResponse {
        calls += 1; self.request = request
        if held {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancellations += 1; throw error }
        }
        if let error { throw error }
        return response
    }
}
private actor UpdateHeldOperation {
    private var continuation: CheckedContinuation<UpdateChecker.CheckResult, Never>?
    private(set) var calls = 0
    func perform() async -> UpdateChecker.CheckResult {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ result: UpdateChecker.CheckResult) { continuation?.resume(returning: result); continuation = nil }
    var entered: Bool { continuation != nil }
}
private actor UpdateRetryOperation {
    private(set) var calls = 0
    func perform() -> UpdateChecker.CheckResult { calls += 1; return calls == 1 ? .failed(.network) : .upToDate }
}

// Only used in an injected ephemeral configuration; never installed globally.
private final class UpdateURLProtocolFixture: URLProtocol, @unchecked Sendable {
    enum Plan { case complete(Data), headers(Int?) }
    private static let lock = NSLock()
    private static var selected = Plan.complete(Data())
    private static var startCount = 0, stopCount = 0
    static func reset(_ plan: Plan) { lock.lock(); defer { lock.unlock() }; selected = plan; startCount = 0; stopCount = 0 }
    static var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (startCount, stopCount) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let plan = Self.selected; Self.startCount += 1; Self.lock.unlock()
        var headers = ["Content-Type": "application/json"]
        if case .headers(let size?) = plan { headers["Content-Length"] = String(size) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if case .complete(let data) = plan {
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.lock.lock(); Self.stopCount += 1; Self.lock.unlock() }
}

final class UpdateCheckerTests: XCTestCase {
    private func waitUntil(_ predicate: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await predicate()) {
            if ContinuousClock.now > deadline { throw NSError(domain: "Update fixture handshake timed out", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func assertFailure(_ data: Data, _ expected: UpdateChecker.Failure = .metadata, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try UpdateChecker.interpret(data, currentVersion: "1.0.0"), file: file, line: line) { error in
            XCTAssertEqual(error as? UpdateChecker.Failure, expected, file: file, line: line)
        }
    }
    func testSemVerPublishedPrecedenceExamplesAndBuildMetadata() throws {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "2.0.0", "2.1.0", "2.1.1"]
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            XCTAssertTrue(UpdateChecker.isNewer(right, than: left), "\(left) < \(right)")
            XCTAssertFalse(UpdateChecker.isNewer(left, than: right))
        }
        XCTAssertEqual(try XCTUnwrap(SemanticVersion("1.2.3+001")).compare(to: XCTUnwrap(SemanticVersion("1.2.3+different"))), .orderedSame)
        XCTAssertTrue(UpdateChecker.isNewer("1.2.1-beta", than: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.1-beta", than: "1.2.1"))
    }
    func testSemVerRejectsMalformedVersionsInsteadOfDroppingComponents() {
        for value in ["", "+build", "-alpha", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "v1.2.3", "1.2.3-", "1.2.3-alpha..1", "1.2.3-01", "1.2.3+a..b", "1.2.3+", "1.2.3++x", " 1.2.3", "1.2.3\n", "1.2.3-β", "１.２.３", String(repeating: "1", count: 257)] {
            XCTAssertNil(SemanticVersion(value), value)
            XCTAssertFalse(UpdateChecker.isNewer(value, than: "0.0.0"), value)
        }
    }
    func testSemVerNumericOverflowAndASCIIIdentifierOrdering() {
        XCTAssertTrue(UpdateChecker.isNewer("999999999999999999999999.0.0", than: "99999999999999999999999.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0-beta.999999999999999999999999", than: "1.0.0-beta.99999999999999999999999"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0-a", than: "1.0.0-Z"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0-a", than: "1.0.0-999999999999999999999999"))
        XCTAssertNotNil(SemanticVersion("1.0.0-x-y-z.--+001"))
    }
    func testExactDMGChosenAmongSourceUnsignedAndUnrelatedAssets() throws {
        let assets = [updateAsset(name: "MDriveHealth-1.2.3-source.zip"), updateAsset(name: "MDriveHealth-1.2.3-UNSIGNED.dmg"), updateAsset(version: "1.2.2"), updateAsset(name: "readme.txt"), updateAsset()]
        guard case .available(let release) = try UpdateChecker.interpret(updateMetadata(assets: assets), currentVersion: "1.0.0") else { return XCTFail("missing update") }
        XCTAssertEqual(release.version, "1.2.3")
        XCTAssertEqual(release.downloadURL?.lastPathComponent, "MDriveHealth-1.2.3.dmg")
    }
    func testNoInstallerOffersOnlyTheMatchingReleasePage() throws {
        guard case .available(let release) = try UpdateChecker.interpret(updateMetadata(assets: [updateAsset(name: "source.zip")]), currentVersion: "1.0.0") else { return XCTFail("missing update") }
        XCTAssertNil(release.downloadURL)
        XCTAssertEqual(release.url.absoluteString, "https://github.com/maclifevn/MDriveHealth/releases/tag/v1.2.3")
    }
    func testEqualOlderAndMetadataOnlyChangesDoNotSuggestUpgrade() throws {
        for current in ["1.2.3", "1.2.3+build.1", "1.2.4", "2.0.0"] {
            XCTAssertEqual(try UpdateChecker.interpret(updateMetadata(), currentVersion: current), .upToDate)
        }
    }
    func testStableChannelRejectsDraftFlagsAndPrereleaseTags() throws {
        assertFailure(try updateMetadata(changes: ["draft": true]), .unstableRelease)
        assertFailure(try updateMetadata(changes: ["prerelease": true]), .unstableRelease)
        assertFailure(try updateMetadata(version: "1.2.3-beta"), .unstableRelease)
    }
    func testMetadataTypesMalformedJSONAndAssetBudgetFailClosed() throws {
        for data in [Data("{".utf8), Data("[]".utf8), try updateMetadata(changes: ["draft": "false"]), try updateMetadata(version: "1.2"), try updateMetadata(assets: Array(repeating: updateAsset(), count: 101))] { assertFailure(data) }
        assertFailure(try updateMetadata(assets: [updateAsset(), updateAsset()]))
        var asset = updateAsset(); asset["size"] = 0; assertFailure(try updateMetadata(assets: [asset]))
        asset = updateAsset(); asset["state"] = "new"; assertFailure(try updateMetadata(assets: [asset]))
    }
    func testPageAndInstallerURLsMustBelongToExactRepositoryTagAndAsset() throws {
        let page = "https://github.com/maclifevn/MDriveHealth/releases/tag/v1.2.3"
        for invalid in [page.replacingOccurrences(of: "https:", with: "http:"), page.replacingOccurrences(of: "github.com", with: "github.com.attacker.test"), page + "?redirect=elsewhere", page + "#fragment", page.replacingOccurrences(of: "github.com", with: "user@github.com"), page.replacingOccurrences(of: "github.com", with: "github.com:443"), page.replacingOccurrences(of: "MDriveHealth", with: "Other"), page.replacingOccurrences(of: "v1.2.3", with: "v9.0.0")] {
            assertFailure(try updateMetadata(changes: ["html_url": invalid]))
        }
        for invalid in ["file:///tmp/installer.dmg", "https://example.test/installer.dmg", "https://github.com/maclifevn/MDriveHealth/releases/download/v1.2.2/MDriveHealth-1.2.3.dmg"] {
            assertFailure(try updateMetadata(assets: [updateAsset(url: invalid)]))
        }
    }
    func testNoVPrefixTagAlsoRequiresItsOwnMatchingURLs() throws {
        let asset = updateAsset(url: "https://github.com/maclifevn/MDriveHealth/releases/download/1.2.3/MDriveHealth-1.2.3.dmg")
        let result = try UpdateChecker.interpret(updateMetadata(assets: [asset], changes: ["tag_name": "1.2.3", "html_url": "https://github.com/maclifevn/MDriveHealth/releases/tag/1.2.3"]), currentVersion: "1.2.2")
        if case .available = result {} else { XCTFail("missing bare-tag update") }
    }
    func testNetworkRequestAndExplicitHTTPFailures() async throws {
        for (status, failure) in [(404, UpdateChecker.Failure.noRelease), (403, .rateLimited), (429, .rateLimited), (500, .http(500)), (302, .http(302))] {
            let fixture = UpdateFetchFixture(status: status)
            let result = await UpdateChecker.checkForUpdate(currentVersion: "1.0.0", fetcher: fixture)
            XCTAssertEqual(result, .failed(failure))
            let request = await fixture.request
            XCTAssertEqual(request?.url, UpdateChecker.endpoint)
            XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request?.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
            XCTAssertEqual(request?.timeoutInterval, 10)
        }
    }
    func testInvalidCurrentVersionFailsBeforeAnyRequest() async {
        let fixture = UpdateFetchFixture()
        let result = await UpdateChecker.checkForUpdate(currentVersion: "0", fetcher: fixture)
        XCTAssertEqual(result, .failed(.currentVersion))
        let calls = await fixture.calls; XCTAssertEqual(calls, 0)
    }
    func testOversizedAndUnexpectedFinalOriginFailClosed() async {
        let oversized = UpdateFetchFixture(data: Data(repeating: 65, count: UpdateChecker.maximumResponseBytes + 1))
        let oversizedResult = await UpdateChecker.checkForUpdate(currentVersion: "1.0.0", fetcher: oversized)
        XCTAssertEqual(oversizedResult, .failed(.tooLarge))
        let redirected = UpdateFetchFixture(url: URL(string: "https://example.test/release")!)
        let redirectedResult = await UpdateChecker.checkForUpdate(currentVersion: "1.0.0", fetcher: redirected)
        XCTAssertEqual(redirectedResult, .failed(.response))
    }
    func testTotalDeadlineCancelsTheInFlightFetcher() async {
        let fixture = UpdateFetchFixture(held: true)
        let result = await UpdateChecker.checkForUpdate(currentVersion: "1.0.0", fetcher: fixture, timeout: .milliseconds(60))
        XCTAssertEqual(result, .failed(.timeout))
        let cancellations = await fixture.cancellations; XCTAssertEqual(cancellations, 1)
    }
    func testUserCancellationDoesNotBecomeNetworkFailure() async throws {
        let fixture = UpdateFetchFixture(held: true)
        let task = Task { await UpdateChecker.checkForUpdate(currentVersion: "1.0.0", fetcher: fixture) }
        try await waitUntil { await fixture.calls == 1 }
        task.cancel()
        let result = await task.value; XCTAssertEqual(result, .cancelled)
        let cancellations = await fixture.cancellations; XCTAssertEqual(cancellations, 1)
    }
    func testURLErrorTimeoutHasAnActionableTypedFailure() async {
        let fixture = UpdateFetchFixture(error: .init(.timedOut))
        let result = await UpdateChecker.checkForUpdate(currentVersion: "1.0.0", fetcher: fixture)
        XCTAssertEqual(result, .failed(.timeout))
    }
    @MainActor func testControllerWaitsForCancelledOperationAndSuppressesItsLateResult() async throws {
        let held = UpdateHeldOperation()
        let controller = UpdateCheckController { await held.perform() }
        controller.check(); controller.check()
        try await waitUntil { await held.entered }
        controller.cancel(); controller.check()
        XCTAssertTrue(controller.isBusy); XCTAssertTrue(controller.isCancelling)
        let calls = await held.calls; XCTAssertEqual(calls, 1)
        await held.release(.available(.init(version: "1.2.3", url: URL(string: "https://github.com/maclifevn/MDriveHealth/releases/tag/v1.2.3")!, downloadURL: nil)))
        await controller.waitForCompletion()
        XCTAssertFalse(controller.isBusy); XCTAssertFalse(controller.isCancelling)
        XCTAssertEqual(controller.result, .cancelled); XCTAssertNil(controller.availableRelease)
    }
    @MainActor func testControllerManualRetryClearsFailureAndReissuesOnce() async {
        let operation = UpdateRetryOperation()
        let controller = UpdateCheckController { await operation.perform() }
        controller.check(); await controller.waitForCompletion()
        XCTAssertEqual(controller.result, .failed(.network))
        XCTAssertNotNil(controller.statusMessage)
        controller.check(); XCTAssertNil(controller.result); await controller.waitForCompletion()
        XCTAssertEqual(controller.result, .upToDate)
        let calls = await operation.calls; XCTAssertEqual(calls, 2)
    }
    @MainActor func testControllerPageLabelAndInterpolatedVersionMatchAction() async {
        let release = UpdateChecker.Release(version: "1.2.3", url: URL(string: "https://github.com/maclifevn/MDriveHealth/releases/tag/v1.2.3")!, downloadURL: nil)
        let controller = UpdateCheckController { .available(release) }
        controller.check(); await controller.waitForCompletion()
        XCTAssertTrue(controller.openReleaseLabel?.contains("1.2.3") == true)
        XCTAssertTrue(controller.statusMessage?.contains("1.2.3") == true)
        XCTAssertFalse(controller.statusMessage?.contains("%@") == true)
    }
    private func realFetcher(_ plan: UpdateURLProtocolFixture.Plan) -> UpdateHTTPFetcher {
        UpdateURLProtocolFixture.reset(plan)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UpdateURLProtocolFixture.self]
        return UpdateHTTPFetcher(configuration: config)
    }
    func testActualURLSessionTransportParsesAnInjectedResponseWithoutNetwork() async throws {
        let fetcher = realFetcher(.complete(try updateMetadata()))
        let result = await UpdateChecker.checkForUpdate(currentVersion: "1.0.0", fetcher: fetcher)
        guard case .available = result else { return XCTFail("unexpected \(result)") }
        XCTAssertEqual(UpdateURLProtocolFixture.counts.0, 1)
    }
    func testActualURLSessionRejectsOversizedHeadersAndCancelsTheRequest() async throws {
        let result = await UpdateChecker.checkForUpdate(currentVersion: "1.0.0", fetcher: realFetcher(.headers(UpdateChecker.maximumResponseBytes + 1)))
        XCTAssertEqual(result, .failed(.tooLarge))
        try await waitUntil { UpdateURLProtocolFixture.counts.1 == 1 }
    }
    func testActualURLSessionLimitsBodyEvenWithoutContentLength() async {
        let result = await UpdateChecker.checkForUpdate(currentVersion: "1.0.0", fetcher: realFetcher(.complete(Data(repeating: 65, count: UpdateChecker.maximumResponseBytes + 1))))
        XCTAssertEqual(result, .failed(.tooLarge))
    }
    func testActualURLSessionCancellationStopsAWaitingRequest() async throws {
        let fetcher = realFetcher(.headers(nil))
        let task = Task { await UpdateChecker.checkForUpdate(currentVersion: "1.0.0", fetcher: fetcher) }
        try await waitUntil { UpdateURLProtocolFixture.counts.0 == 1 }
        task.cancel()
        let result = await task.value; XCTAssertEqual(result, .cancelled)
        try await waitUntil { UpdateURLProtocolFixture.counts.1 == 1 }
    }
}
