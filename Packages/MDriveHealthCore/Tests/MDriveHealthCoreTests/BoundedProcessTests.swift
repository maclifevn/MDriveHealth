/* Real child process fault tests. MDriveHealth, GPL-3.0-or-later. */
import XCTest
import Darwin
@testable import MDriveHealthCore

final class BoundedProcessTests: XCTestCase {
    private func command(_ script: String, timeout: Double = 1) -> ProcessCommand {
        var result = ProcessCommand("/bin/sh", ["-c", script], timeout: timeout, scope: "process-test-\(UUID().uuidString)")
        result.terminateGrace = 0.05; result.killGrace = 0.2
        return result
    }
    private func expect(_ reason: CommandError.Reason, _ work: () throws -> CommandOutput) throws -> CommandError {
        do { _ = try work(); XCTFail("expected \(reason)"); throw CocoaError(.coderInvalidValue) }
        catch let error as CommandError { XCTAssertEqual(error.reason, reason); return error }
    }
    private func waitForReady(_ file: URL) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
        while !FileManager.default.fileExists(atPath: file.path) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("fixture child never confirmed launch"); throw CocoaError(.fileReadUnknown)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func readyCommand(_ file: URL) -> ProcessCommand {
        var request = command("trap '' TERM; printf ready > \"$1\"; while :; do :; done", timeout: 20)
        request.arguments += ["MDriveHealth-child-fixture", file.path]
        return request
    }
    func testCapturesBothPipesAndExactExitStatus() throws {
        let output = try BoundedProcess.run(command("printf out; printf err >&2; exit 7"))
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "out")
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "err")
        XCTAssertEqual(output.termination, .exited(7))
        XCTAssertThrowsError(try output.requireSuccess()) { XCTAssertTrue($0.localizedDescription.contains("err")) }
        XCTAssertEqual(kill(output.processID, 0), -1); XCTAssertEqual(errno, ESRCH, "completed child must be reaped")
    }
    func testArgumentsArePassedLiterallyWithoutShellInterpolation() throws {
        let literal = "$(touch should-not-exist) `whoami` ' \" $HOME"
        let output = try BoundedProcess.run(ProcessCommand("/usr/bin/printf", ["%s", literal], timeout: 1))
        XCTAssertEqual(String(decoding: try output.requireSuccess(), as: UTF8.self), literal)
    }
    func testLargeStdoutAndStderrAreDrainedWithoutDeadlock() throws {
        var request = command("/usr/bin/yes out | /usr/bin/head -c 131072; /usr/bin/yes err | /usr/bin/head -c 131072 >&2")
        request.stdoutLimit = 131072; request.stderrLimit = 131072
        let output = try BoundedProcess.run(request)
        XCTAssertTrue(output.termination.succeeded)
        XCTAssertEqual(output.stdout.count, 131072); XCTAssertEqual(output.stderr.count, 131072)
    }
    func testUnboundedOutputStopsAtByteLimitAndReapsChild() throws {
        var request = command("exec /usr/bin/yes flood", timeout: 5); request.stdoutLimit = 32768
        let started = Date(), error = try expect(.outputLimit("stdout")) { try BoundedProcess.run(request) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        if let pending = error.pendingChild { XCTAssertEqual(pending.processID, error.processID) }
        else { XCTAssertEqual(kill(try XCTUnwrap(error.processID), 0), -1); XCTAssertEqual(errno, ESRCH) }
    }
    func testUnboundedStderrAlsoHasItsOwnLimit() throws {
        var request = command("exec /usr/bin/yes flood >&2", timeout: 5); request.stderrLimit = 4096
        _ = try expect(.outputLimit("stderr")) { try BoundedProcess.run(request) }
    }
    func testSIGTERMIgnoredEscalatesToSIGKILLWithinBound() throws {
        let request = command("trap '' TERM; while :; do :; done", timeout: 0.1)
        let started = Date(), error = try expect(.timedOut) { try BoundedProcess.run(request) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNil(error.pendingChild)
        XCTAssertEqual(kill(try XCTUnwrap(error.processID), 0), -1); XCTAssertEqual(errno, ESRCH)
        // No old delayed timer can kill the next invocation using this scope.
        var recovered = ProcessCommand("/usr/bin/true", timeout: 1); recovered.scope = request.scope
        XCTAssertTrue(try BoundedProcess.run(recovered).termination.succeeded)
    }
    func testExitedParentWithDescendantHoldingPipeDoesNotHangDrain() throws {
        let started = Date()
        _ = try expect(.timedOut) { try BoundedProcess.run(command("/bin/sleep 10 & exit 0", timeout: 0.1)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
    func testCancellationBeforeLaunchDoesNotCreateChild() throws {
        let error = try expect(.cancelled) { try BoundedProcess.run(command("exit 0"), isCancelled: { true }) }
        XCTAssertNil(error.processID)
    }
    func testAsyncCancellationReachesWatchdogAndReapsChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mdrivehealth-child-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready"), request = readyCommand(ready)
        let task = Task { try await BoundedProcess.run(request) }
        defer { task.cancel() }
        try await waitForReady(ready)
        let started = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("cancelled process must throw") }
        catch let error as CommandError {
            XCTAssertEqual(error.reason, .cancelled); XCTAssertLessThan(Date().timeIntervalSince(started), 1)
            if let pending = error.pendingChild { await pending.waitForExit() }
            XCTAssertEqual(kill(try XCTUnwrap(error.processID), 0), -1); XCTAssertEqual(errno, ESRCH)
        }
    }
    func testZeroKillGraceTransfersToOwnedReaperAndThenAllowsRetry() async throws {
        var request = command("trap '' TERM; while :; do :; done", timeout: 0.08)
        request.terminateGrace = 0; request.killGrace = 0
        let error = try expect(.timedOut) { try BoundedProcess.run(request) }
        let pending = try XCTUnwrap(error.pendingChild)
        await pending.waitForExit(); XCTAssertTrue(pending.hasExited)
        var next = ProcessCommand("/usr/bin/true", timeout: 1); next.scope = request.scope
        let result = try await BoundedProcess.run(next); XCTAssertTrue(result.termination.succeeded)
    }
    func testInputIsWrittenWhileOutputIsDrained() throws {
        var request = command("exec /bin/cat")
        request.input = Data(repeating: 65, count: 131072)
        let output = try BoundedProcess.run(request)
        XCTAssertEqual(try output.requireSuccess(), request.input)
    }
    func testEarlyClosedStdinDoesNotSendSIGPIPEToParentOrReportSuccess() throws {
        var request = command("exec 0<&-; sleep 0.02; exit 0")
        request.input = Data(repeating: 65, count: 1_048_576)
        _ = try expect(.inputIncomplete) { try BoundedProcess.run(request) }
    }
    func testUnrelatedFileDescriptorIsNotInherited() throws {
        let fd = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        let output = try BoundedProcess.run(command("if /bin/test -e /dev/fd/\(fd); then exit 9; else exit 0; fi"))
        XCTAssertTrue(output.termination.succeeded)
    }
    func testExplicitFDDelegationAvoidsInternalPipeAlias() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mdrivehealth-fd-test-\(UUID())")
        try Data("delegated bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reserved = open("/dev/null", O_RDONLY), source = open(file.path, O_RDONLY | O_CLOEXEC)
        guard reserved >= 3, reserved <= 64, source >= 3 else { return XCTFail("fixture descriptors unavailable") }
        close(reserved); defer { close(source) }
        var request = command("/bin/cat <&\(reserved)")
        request.inheritedFileDescriptors[reserved] = source
        XCTAssertEqual(String(decoding: try BoundedProcess.run(request).requireSuccess(), as: UTF8.self), "delegated bytes")
    }
    func testLaunchFailureAndInvalidRequestsAreExplicit() throws {
        _ = try expect(.launch(ENOENT)) { try BoundedProcess.run(ProcessCommand("/does/not/exist", timeout: 1)) }
        for timeout in [0, -1, .infinity, .nan, 601] {
            _ = try expect(.invalidConfiguration) { try BoundedProcess.run(ProcessCommand("/usr/bin/true", timeout: timeout)) }
        }
        var request = ProcessCommand("/usr/bin/true", ["embedded\u{0}nul"], timeout: 1)
        _ = try expect(.invalidConfiguration) { try BoundedProcess.run(request) }
        request.arguments = []; request.stdoutLimit = -1
        _ = try expect(.invalidConfiguration) { try BoundedProcess.run(request) }
        request.stdoutLimit = 1024; request.inheritedFileDescriptors = [2: 3]
        _ = try expect(.invalidConfiguration) { try BoundedProcess.run(request) }
    }
    func testCrossedDescriptorSourcesKeepOriginalBytesAndClosePrivateCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mdrivehealth-crossed-fds-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
        try Data("first".utf8).write(to: one); try Data("second".utf8).write(to: two)
        let first = open(one.path, O_RDONLY | O_CLOEXEC), second = open(two.path, O_RDONLY | O_CLOEXEC)
        defer { close(first); close(second) }
        guard (3...64).contains(first), (3...64).contains(second) else { return XCTFail("fixture descriptors unavailable") }
        let before = Set((0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 })
        var request = command("/bin/cat /dev/fd/\(first) /dev/fd/\(second)")
        request.inheritedFileDescriptors = [first: second, second: first]
        XCTAssertEqual(String(decoding: try BoundedProcess.run(request).requireSuccess(), as: UTF8.self), "secondfirst")
        XCTAssertEqual(Set((0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }), before)
    }
    func testConcurrentSameScopeIsRejectedAndCancellationReleasesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mdrivehealth-child-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready"), first = readyCommand(ready)
        let task = Task { try await BoundedProcess.run(first) }
        defer { task.cancel() }
        try await waitForReady(ready)
        var next = ProcessCommand("/usr/bin/true", timeout: 1); next.scope = first.scope
        _ = try expect(.busy) { try BoundedProcess.run(next) }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch let error as CommandError { if let pending = error.pendingChild { await pending.waitForExit() } }
        let recovered = try await BoundedProcess.run(next)
        XCTAssertTrue(recovered.termination.succeeded)
    }
    func testRepeatedInvocationsDoNotLeakPipeDescriptors() throws {
        func descriptors() -> Set<Int32> { Set((0..<1024).compactMap { fcntl(Int32($0), F_GETFD) < 0 ? nil : Int32($0) }) }
        _ = try BoundedProcess.run(command("exit 0"))
        let before = descriptors()
        for _ in 0..<40 { XCTAssertTrue(try BoundedProcess.run(command("printf out; printf err >&2")).termination.succeeded) }
        XCTAssertEqual(descriptors(), before)
    }
    func testBackgroundDescendantIgnoringTERMIsStoppedAfterParentExits() async throws {
        let script = "(trap '' TERM; exec 0</dev/null 1>/dev/null 2>/dev/null; while :; do :; done) & printf '%s' \"$!\"; exit 0"
        let output = try await BoundedProcess.run(command(script))
        XCTAssertTrue(output.termination.succeeded)
        let child = try XCTUnwrap(Int32(String(decoding: output.stdout, as: UTF8.self)))
        for _ in 0..<100 {
            if kill(child, 0) < 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("owned background descendant remained after parent exited")
    }
}
