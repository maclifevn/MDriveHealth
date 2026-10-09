/* Streaming watchdog behavior with actual child processes. GPL-3.0-or-later. */
import XCTest
import Darwin
@testable import MDriveHealthCore

private final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock(); private var bytes = Data(); private var cancel = false
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    func trip() { lock.lock(); cancel = true; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancel }
}
final class ProcessStreamingTests: XCTestCase {
    private func command(_ script: String) -> ProcessCommand {
        var c = ProcessCommand("/bin/sh", ["-c",script], timeout: 2, scope: "stream-fixture-\(UUID())")
        c.terminateGrace = 0.05; c.killGrace = 0.2; return c
    }
    func testStreamDoesNotRetainStdoutAndHonorsLifetimeByteLimit() throws {
        let capture = StreamCapture()
        var c = command("printf abcdef"); c.stdoutLimit = 0
        c.streamingStdout = .init(byteLimit: 16, consume: { capture.append($0); return false })
        let output = try BoundedProcess.run(c)
        XCTAssertTrue(output.stdout.isEmpty); XCTAssertEqual(capture.value, Data("abcdef".utf8))
        c = command("exec /usr/bin/yes x"); c.streamingStdout = .init(byteLimit: 1024, consume: { _ in false })
        do { _ = try BoundedProcess.run(c); XCTFail("lifetime stream budget must stop producer") }
        catch let error as CommandError { XCTAssertEqual(error.reason, .outputLimit("stdout")); XCTAssertNil(error.pendingChild) }
    }
    func testArbitraryOutputCannotKeepIdleWorkerAlive() throws {
        var c = command("while :; do printf heartbeat; sleep 0.02; done")
        c.idleTimeout = 0.15; c.streamingStdout = .init(byteLimit: 65536, consume: { _ in false })
        let started = Date()
        do { _ = try BoundedProcess.run(c); XCTFail("heartbeat is not verified I/O") }
        catch let error as CommandError { XCTAssertEqual(error.reason, .idleTimedOut); XCTAssertLessThan(Date().timeIntervalSince(started), 2) }
    }
    func testVerifiedProgressExtendsIdleButNotHardDeadline() throws {
        var c = command("for n in 1 2 3 4 5; do printf progress; sleep 0.05; done")
        c.idleTimeout = 0.2; c.streamingStdout = .init(byteLimit: 65536, consume: { _ in true })
        XCTAssertTrue(try BoundedProcess.run(c).termination.succeeded)
        c = command("while :; do printf progress; sleep 0.02; done"); c.timeout = 0.2; c.idleTimeout = 0.15
        c.streamingStdout = .init(byteLimit: 65536, consume: { _ in true })
        do { _ = try BoundedProcess.run(c); XCTFail("verified progress must not evade absolute deadline") }
        catch let error as CommandError { XCTAssertEqual(error.reason, .timedOut) }
    }
    func testRejectedFrameKillsAndReapsProducerBeforeReturningError() throws {
        var c = command("printf bad; sleep 10")
        c.streamingStdout = .init(byteLimit: 65536, consume: { _ in throw MeasurementWorkerError.protocolViolation })
        do { _ = try BoundedProcess.run(c); XCTFail("invalid output must fail") }
        catch let error as CommandError {
            XCTAssertEqual(error.reason, .invalidOutput); XCTAssertNil(error.pendingChild)
            XCTAssertEqual(kill(try XCTUnwrap(error.processID), 0), -1); XCTAssertEqual(errno, ESRCH)
        }
    }
    func testCancellationStillCollectsCleanupTerminalOutput() throws {
        let capture = StreamCapture()
        var c = command("trap 'printf finished; exit 0' TERM; printf ready; while :; do sleep 0.05; done")
        c.terminateGrace = 0.5
        c.streamingStdout = .init(byteLimit: 65536, consume: { data in capture.append(data); if capture.value.contains(Data("ready".utf8)) { capture.trip() }; return false })
        do { _ = try BoundedProcess.run(c, isCancelled: { capture.cancelled }); XCTFail("cancel must remain the process outcome") }
        catch let error as CommandError { XCTAssertEqual(error.reason, .cancelled); XCTAssertTrue(String(decoding: capture.value, as: UTF8.self).contains("finished")) }
    }
    func testLongDeadlinesRequireBothStreamingBudgetAndFiniteIdleDeadline() throws {
        var c = command("exit 0"); c.timeout = 604800
        XCTAssertThrowsError(try c.validate())
        c.streamingStdout = .init(byteLimit: 16, consume: { _ in false }); XCTAssertThrowsError(try c.validate())
        c.idleTimeout = 30; XCTAssertNoThrow(try c.validate())
        c.timeout += 1; XCTAssertThrowsError(try c.validate())
        c.timeout = 604800; c.idleTimeout = .infinity; XCTAssertThrowsError(try c.validate())
        c.idleTimeout = 30; c.streamingStdout = .init(byteLimit: 1_073_741_825, consume: { _ in false }); XCTAssertThrowsError(try c.validate())
    }
    func testCleanupOutputAfterCancellationStillEnforcesBudgetAndParserRejection() throws {
        for reject in [false, true] {
            let capture = StreamCapture()
            var c = command("trap 'printf finished; exit 0' TERM; printf ready; while :; do sleep 0.05; done")
            c.terminateGrace = 0.5
            c.streamingStdout = .init(byteLimit: reject ? 65536 : 8, consume: { data in
                if reject && data.contains(Data("finished".utf8)) { throw MeasurementWorkerError.protocolViolation }
                capture.append(data); capture.trip(); return false
            })
            do { _ = try BoundedProcess.run(c, isCancelled: { capture.cancelled }); XCTFail("invalid cleanup output must not confirm cancellation") }
            catch let error as CommandError {
                XCTAssertEqual(error.reason, reject ? .invalidOutput : .outputLimit("stdout"))
                XCTAssertNil(error.pendingChild); XCTAssertEqual(capture.value, Data("ready".utf8))
            }
        }
    }
}
