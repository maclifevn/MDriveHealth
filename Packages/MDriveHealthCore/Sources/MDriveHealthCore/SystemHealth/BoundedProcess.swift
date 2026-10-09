/*
 * BoundedProcess.swift — supervised child processes with bounded pipes.
 * MDriveHealth, GPL-3.0-or-later.
 */
import Foundation
import Darwin

public struct ProcessOutputStream: Sendable {
    public let byteLimit: UInt64
    /// Called on the supervisor thread. Return true only for verified progress;
    /// arbitrary output/heartbeats must not extend the idle deadline.
    public let consume: @Sendable (Data) throws -> Bool
    public init(byteLimit: UInt64, consume: @escaping @Sendable (Data) throws -> Bool) {
        self.byteLimit = byteLimit; self.consume = consume
    }
}
public struct ProcessCommand: Sendable {
    public let executable: String
    public var arguments: [String]
    public var input = Data()
    public var timeout: TimeInterval
    public var terminateGrace: TimeInterval = 0.5
    public var killGrace: TimeInterval = 1
    public var stdoutLimit = 8 * 1_048_576
    public var stderrLimit = 64 * 1024
    public var streamingStdout: ProcessOutputStream?
    public var idleTimeout: TimeInterval?
    /// A pending/unreaped child keeps this scope unavailable for retries.
    public var scope: String
    /// Explicitly delegated descriptors only; map child FD to parent FD.
    public var inheritedFileDescriptors: [Int32: Int32] = [:]
    public init(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval,
                scope: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout
        self.scope = scope ?? executable
    }
    func validate() throws {
        guard executable.hasPrefix("/"), !executable.utf8.contains(0),
              arguments.count <= 256, arguments.allSatisfy({ !$0.utf8.contains(0) }),
              executable.utf8.count + arguments.reduce(0, { $0 + $1.utf8.count }) <= 131_072,
              !scope.isEmpty, scope.utf8.count <= 512,
              timeout.isFinite, timeout > 0,
              timeout <= (streamingStdout != nil && idleTimeout != nil ? 604_800 : 600),
              idleTimeout.map({ streamingStdout != nil && $0.isFinite && $0 > 0 && $0 <= 120 }) ?? true,
              streamingStdout.map({ (1...1_073_741_824).contains($0.byteLimit) }) ?? true,
              terminateGrace.isFinite, (0...10).contains(terminateGrace),
              killGrace.isFinite, (0...10).contains(killGrace),
              (0...16 * 1_048_576).contains(stdoutLimit), (0...1_048_576).contains(stderrLimit),
              input.count <= 1_048_576,
              inheritedFileDescriptors.count <= 8,
              inheritedFileDescriptors.allSatisfy({ (3...64).contains($0.key) && $0.value >= 3 && fcntl($0.value, F_GETFD) >= 0 })
        else { throw CommandError(.invalidConfiguration) }
    }
}

public enum CommandTermination: Sendable, Equatable {
    case exited(Int32), signalled(Int32)
    public var succeeded: Bool { self == .exited(0) }
}
public struct CommandOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let termination: CommandTermination
    public let processID: Int32
    public func requireSuccess() throws -> Data {
        guard termination.succeeded else {
            throw CommandError(.unsuccessful(termination), processID: processID,
                               diagnostic: String(decoding: stderr.prefix(2048), as: UTF8.self))
        }
        return stdout
    }
}
public struct CommandError: Error, LocalizedError, Sendable {
    public enum Reason: Sendable, Equatable {
        case invalidConfiguration, launch(Int32), io(Int32), busy, timedOut, idleTimedOut, cancelled
        case invalidOutput
        case outputLimit(String), inputIncomplete, unsuccessful(CommandTermination)
    }
    public let reason: Reason
    public let processID: Int32?
    public let pendingChild: PendingChild?
    public let diagnostic: String?
    init(_ reason: Reason, processID: Int32? = nil, pendingChild: PendingChild? = nil,
         diagnostic: String? = nil) {
        self.reason = reason; self.processID = processID; self.pendingChild = pendingChild; self.diagnostic = diagnostic
    }
    public var errorDescription: String? {
        let message: String
        switch reason {
        case .invalidConfiguration: message = "Invalid process configuration"
        case .launch(let code): message = "Process launch failed (\(code)): \(String(cString: strerror(code)))"
        case .io(let code): message = "Process I/O failed (\(code)): \(String(cString: strerror(code)))"
        case .busy: message = "This operation is already running or its previous child has not exited"
        case .timedOut: message = "Process deadline exceeded"
        case .idleTimedOut: message = "Process stopped reporting verified I/O progress"
        case .invalidOutput: message = "Process returned invalid streaming output"
        case .cancelled: message = "Process cancelled"
        case .outputLimit(let stream): message = "Process \(stream) exceeded its byte limit"
        case .inputIncomplete: message = "Process closed stdin before consuming the request"
        case .unsuccessful(let status): message = "Process failed: \(status)"
        }
        return message + (pendingChild == nil ? "" : ". Child exit is still pending; retries are blocked until reaped.")
            + (diagnostic.flatMap { $0.isEmpty ? nil : ": " + $0 } ?? "")
    }
}

/// A SIGKILL request is not proof of exit. Own the PID until waitpid confirms
/// termination, and retain the operation scope while that confirmation is pending.
public final class PendingChild: @unchecked Sendable {
    public let processID: Int32
    private let lock = NSLock()
    private var exited = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public var hasExited: Bool { lock.lock(); defer { lock.unlock() }; return exited }
    init(processID: Int32) {
        self.processID = processID
        let thread = Thread { [self] in
            var status: Int32 = 0
            while true {
                let result = waitpid(processID, &status, 0)
                if result == processID || (result < 0 && errno == ECHILD) { break }
                if errno != EINTR { Thread.sleep(forTimeInterval: 0.1) }
            }
            lock.lock(); exited = true; let callbacks = waiters; waiters.removeAll(); lock.unlock()
            for callback in callbacks { callback.resume() }
        }
        thread.name = "MDriveHealth.child-reaper"; thread.qualityOfService = .utility; thread.start()
    }
    public func waitForExit() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exited { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}

private final class CommandScopes: @unchecked Sendable {
    static let shared = CommandScopes()
    private struct Entry { let token: UUID; var pending: PendingChild? }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    func acquire(_ scope: String) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.pending?.hasExited != true }
        guard entries[scope] == nil, entries.count < 8 else { throw CommandError(.busy) }
        let token = UUID(); entries[scope] = Entry(token: token); return token
    }
    func release(_ scope: String, token: UUID, pending: PendingChild?) {
        lock.lock(); defer { lock.unlock() }
        guard entries[scope]?.token == token else { return }
        if let pending { entries[scope]?.pending = pending }
        else { entries.removeValue(forKey: scope) }
    }
}
private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

public enum BoundedProcess {
    /// Runs on a dedicated thread; Task cancellation reaches the watchdog.
    public static func run(_ command: ProcessCommand, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> CommandOutput {
        try command.validate()
        if Task.isCancelled { throw CommandError(.cancelled) }
        let token = try CommandScopes.shared.acquire(command.scope)
        let cancellation = CommandCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    continuation.resume(with: Result { try runOwned(command, token: token, isCancelled: { cancellation.cancelled || isCancelled() }) })
                }
                thread.name = "MDriveHealth.process"; thread.qualityOfService = .utility; thread.start()
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Blocking API for a dedicated worker/CLI. Never call from a UI action.
    public static func run(_ command: ProcessCommand,
                           isCancelled: @Sendable () -> Bool = { false }) throws -> CommandOutput {
        try command.validate()
        if isCancelled() { throw CommandError(.cancelled) }
        let token = try CommandScopes.shared.acquire(command.scope)
        return try runOwned(command, token: token, isCancelled: isCancelled)
    }
    private static func runOwned(_ command: ProcessCommand, token: UUID,
                                 isCancelled: @Sendable () -> Bool) throws -> CommandOutput {
        var pending: PendingChild?
        defer { CommandScopes.shared.release(command.scope, token: token, pending: pending) }
        if isCancelled() { throw CommandError(.cancelled) }
        var ownedFDs = Set<Int32>()
        defer { for fd in ownedFDs { Darwin.close(fd) } }
        // Preserve every source before any dup2 action can overwrite a source
        // that happens to be another destination. Cycles and low FD allocation
        // are both valid; private copies retain their original OFDs/locks.
        var inheritedCopies: [Int32: Int32] = [:]
        let firstPrivateFD = max(3, (command.inheritedFileDescriptors.keys.max() ?? 2) + 1)
        for (destination, source) in command.inheritedFileDescriptors {
            let copy = fcntl(source, F_DUPFD_CLOEXEC, firstPrivateFD)
            guard copy >= 0 else { throw CommandError(.io(errno)) }
            ownedFDs.insert(copy); inheritedCopies[destination] = copy
        }
        func closeFD(_ fd: inout Int32) { if fd >= 0 { Darwin.close(fd); ownedFDs.remove(fd); fd = -1 } }
        func makePipe() throws -> [Int32] {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw CommandError(.io(errno)) }
            ownedFDs.formUnion(fds)
            for index in fds.indices {
                // Internal endpoints must not alias 0/1/2 in file actions.
                if fds[index] <= 2 || command.inheritedFileDescriptors[fds[index]] != nil {
                    let replacement = fcntl(fds[index], F_DUPFD_CLOEXEC, max(3, (command.inheritedFileDescriptors.keys.max() ?? 2) + 1))
                    guard replacement >= 0 else { throw CommandError(.io(errno)) }
                    var old = fds[index]; closeFD(&old); fds[index] = replacement; ownedFDs.insert(replacement)
                }
                guard fcntl(fds[index], F_SETFD, FD_CLOEXEC) == 0 else { throw CommandError(.io(errno)) }
            }
            return fds
        }
        var inputPipe = try makePipe(), outputPipe = try makePipe(), errorPipe = try makePipe()
        for fd in [inputPipe[1], outputPipe[0], errorPipe[0]] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CommandError(.io(errno)) }
        }
        guard fcntl(inputPipe[1], F_SETNOSIGPIPE, 1) == 0 else { throw CommandError(.io(errno)) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ code: Int32) throws { guard code == 0 else { throw CommandError(.launch(code)) } }
        try check(posix_spawn_file_actions_init(&actions)); defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes)); defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var signals = sigset_t(); sigemptyset(&signals)
        try check(posix_spawnattr_setsigmask(&attributes, &signals))
        sigaddset(&signals, SIGTERM); sigaddset(&signals, SIGPIPE); sigaddset(&signals, SIGINT)
        try check(posix_spawnattr_setsigdefault(&attributes, &signals))
        for (source, destination) in [(inputPipe[0], STDIN_FILENO), (outputPipe[1], STDOUT_FILENO), (errorPipe[1], STDERR_FILENO)] {
            try check(posix_spawn_file_actions_adddup2(&actions, source, destination))
        }
        for (destination, source) in inheritedCopies {
            try check(posix_spawn_file_actions_adddup2(&actions, source, destination))
        }
        for fd in ownedFDs { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        let argv = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }) else { throw CommandError(.launch(ENOMEM)) }
        var pid: pid_t = 0
        let started = DispatchTime.now().uptimeNanoseconds
        let launched = command.executable.withCString { executable in
            argv.withUnsafeBufferPointer { posix_spawn(&pid, executable, &actions, &attributes, $0.baseAddress, environ) }
        }
        try check(launched)
        func signalChild(_ signal: Int32) {
            Darwin.kill(-pid, signal)
            // The unreaped child PID remains owned even if the executable
            // changes process group. Never derive and signal its new group.
            Darwin.kill(pid, signal)
        }
        closeFD(&inputPipe[0]); closeFD(&outputPipe[1]); closeFD(&errorPipe[1])
        var inputFD = inputPipe[1], stdoutFD = outputPipe[0], stderrFD = errorPipe[0]
        var inputOffset = 0, stdout = Data(), stderr = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        var failure: CommandError.Reason?, terminateAt: UInt64?, killAt: UInt64?
        var killed = false
        var streamedBytes: UInt64 = 0, lastActivity = started
        var streamDiagnostic: String?
        let deadline = started + UInt64(command.timeout * 1_000_000_000)
        if command.input.isEmpty { closeFD(&inputFD) }
        func drain(_ fd: inout Int32, into data: inout Data, limit: Int, name: String) {
            // A continuous producer must not prevent deadline/cancel checks.
            for _ in 0..<8 where fd >= 0 {
                let readCount = Darwin.read(fd, &buffer, buffer.count)
                if readCount > 0 {
                    if name == "stdout", let stream = command.streamingStdout {
                        streamedBytes += UInt64(readCount)
                        if streamedBytes > stream.byteLimit {
                            if failure == nil || failure == .cancelled || failure == .idleTimedOut || failure == .timedOut { failure = .outputLimit("stdout") }
                            continue
                        }
                        if failure == nil || failure == .cancelled || failure == .idleTimedOut || failure == .timedOut {
                            do {
                                if try stream.consume(Data(buffer.prefix(readCount))) { lastActivity = DispatchTime.now().uptimeNanoseconds }
                            } catch {
                                // Malformed cleanup output cannot become a
                                // confirmed cancel merely because TERM came first.
                                failure = .invalidOutput
                                streamDiagnostic = String(decoding: Data(error.localizedDescription.utf8.prefix(2045)), as: UTF8.self)
                            }
                        }
                        continue
                    }
                    let room = max(0, limit - data.count)
                    data.append(contentsOf: buffer.prefix(min(room, readCount)))
                    if readCount > room && failure == nil { failure = .outputLimit(name) }
                } else if readCount == 0 { closeFD(&fd); return }
                else if errno == EINTR { continue }
                else if errno == EAGAIN { return }
                else { if failure == nil { failure = .io(errno) }; closeFD(&fd); return }
            }
        }
        while true {
            drain(&stdoutFD, into: &stdout, limit: command.stdoutLimit, name: "stdout")
            drain(&stderrFD, into: &stderr, limit: command.stderrLimit, name: "stderr")
            if inputFD >= 0 {
                let count = command.input.withUnsafeBytes { bytes in
                    Darwin.write(inputFD, bytes.baseAddress!.advanced(by: inputOffset), min(16384, command.input.count - inputOffset))
                }
                if count > 0 { inputOffset += count; if inputOffset == command.input.count { closeFD(&inputFD) } }
                else if count < 0 && errno != EAGAIN && errno != EINTR {
                    if failure == nil { failure = errno == EPIPE ? .inputIncomplete : .io(errno) }; closeFD(&inputFD)
                }
            }
            var info = siginfo_t()
            let observed = waitid(P_PID, UInt32(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if observed < 0 && errno != EINTR {
                // ECHILD means another owner reaped it: never signal a PID that
                // might already have been reused. Do not manufacture success.
                if errno == ECHILD { throw CommandError(.io(errno), processID: pid) }
                if failure == nil { failure = .io(errno) }
            }
            if info.si_pid == pid && stdoutFD < 0 && stderrFD < 0 {
                // Keep the zombie PID reserved while stopping any descendants.
                signalChild(SIGKILL)
                var status: Int32 = 0
                var reaped: pid_t
                repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
                guard reaped == pid else { throw CommandError(.io(errno), processID: pid) }
                if inputOffset < command.input.count && failure == nil { failure = .inputIncomplete }
                if let failure { throw CommandError(failure, processID: pid, diagnostic: streamDiagnostic ?? String(decoding: stderr.prefix(2048), as: UTF8.self)) }
                let termination: CommandTermination = status & 0x7f == 0 ? .exited((status >> 8) & 0xff) : .signalled(status & 0x7f)
                return CommandOutput(stdout: stdout, stderr: stderr, termination: termination, processID: pid)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if failure == nil {
                if isCancelled() { failure = .cancelled }
                else if now >= deadline { failure = .timedOut }
                else if let idle = command.idleTimeout, now - lastActivity >= UInt64(idle * 1_000_000_000) { failure = .idleTimedOut }
            }
            if failure != nil && terminateAt == nil {
                signalChild(SIGTERM); terminateAt = now + UInt64(command.terminateGrace * 1_000_000_000)
                closeFD(&inputFD)
            }
            if let terminateAt, now >= terminateAt && !killed {
                signalChild(SIGKILL); killed = true; killAt = now + UInt64(command.killGrace * 1_000_000_000)
            }
            if let killAt, now >= killAt {
                // Return control to the UI even if the OS has not completed
                // SIGKILL yet. One bounded reaper retains ownership and scope.
                pending = PendingChild(processID: pid)
                throw CommandError(failure ?? .timedOut, processID: pid, pendingChild: pending,
                                   diagnostic: streamDiagnostic ?? String(decoding: stderr.prefix(2048), as: UTF8.self))
            }
            var descriptors = [pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: stderrFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)]
            if poll(&descriptors, nfds_t(descriptors.count), 20) < 0 && errno != EINTR && failure == nil { failure = .io(errno) }
        }
    }
}
