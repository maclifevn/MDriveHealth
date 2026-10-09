/*
 * IOErrorWatcher.swift — scans the unified log for kernel disk I/O errors.
 * Availability and malformed records are separate from a successful empty scan.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import CoreFoundation

public struct IOErrorEvent: Sendable, Codable, Hashable {
    public let date: Date
    public let message: String

    public init(date: Date, message: String) {
        self.date = date
        self.message = message
    }

    /// True when the message references the device itself or one of its
    /// partitions ("disk1", "disk1s2") — but not a longer device name that
    /// merely shares the prefix ("disk10"), nor a substring like "rdisk1".
    /// The single definition of "this log line concerns this BSD device",
    /// used both to narrow the log query and to count per device.
    public func mentions(_ bsdName: String) -> Bool {
        guard !bsdName.isEmpty else { return false }
        var search = message.startIndex..<message.endIndex
        while let found = message.range(of: bsdName, range: search) {
            let followedByDigit = found.upperBound < message.endIndex
                && message[found.upperBound].isNumber
            let precededByAlphanumeric = found.lowerBound > message.startIndex && {
                let previous = message[message.index(before: found.lowerBound)]
                return previous.isLetter || previous.isNumber
            }()
            if !followedByDigit, !precededByAlphanumeric { return true }
            search = found.upperBound..<message.endIndex
        }
        return false
    }
}

public struct IOErrorScanDiagnostics: Sendable, Equatable {
    public var malformedLines = 0
    public var invalidTimestamps = 0
    public var outsideWindow = 0
    public var isComplete: Bool { malformedLines == 0 && invalidTimestamps == 0 }
}
public struct IOErrorScan: Sendable {
    public let events: [IOErrorEvent]
    public let diagnostics: IOErrorScanDiagnostics
    public var isComplete: Bool { diagnostics.isComplete }
}
public enum IOErrorScanError: Error, LocalizedError, Sendable {
    case invalidRequest, lineLimit, eventLimit, rowLimit
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid kernel-log scan request"
        case .lineLimit: return "Kernel-log record exceeded the byte limit; scan is incomplete"
        case .eventLimit: return "Kernel-log event limit exceeded; scan is incomplete"
        case .rowLimit: return "Kernel-log row limit exceeded; scan is incomplete"
        }
    }
}
private final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public enum IOErrorWatcher {
    public static let maximumEvents = 10_000
    public static let maximumLineBytes = 256 * 1024
    public static let maximumRows = 20_000
    public static let maximumOutputBytes = 8 * 1_048_576

    public static func scan(withinMinutes minutes: Int, bsdName: String? = nil,
                            timeout: TimeInterval = 20) async throws -> IOErrorScan {
        let cancellation = ScanCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    continuation.resume(with: Result {
                        try scan(withinMinutes: minutes, bsdName: bsdName, timeout: timeout,
                                 isCancelled: { cancellation.value })
                    })
                }
                thread.name = "MDriveHealth.kernel-log"; thread.qualityOfService = .utility; thread.start()
            }
        } onCancel: { cancellation.cancel() }
    }
    public static func scan(withinMinutes minutes: Int, bsdName: String? = nil,
                            timeout: TimeInterval = 20,
                            isCancelled: @Sendable () -> Bool = { false }) throws -> IOErrorScan {
        let started = Date()
        let command = try makeCommand(withinMinutes: minutes, bsdName: bsdName, timeout: timeout)
        let data = try BoundedProcess.run(command, isCancelled: isCancelled).requireSuccess()
        if isCancelled() { throw CommandError(.cancelled) }
        return try parseNDJSON(data, since: started.addingTimeInterval(-Double(minutes) * 60),
                               through: Date(), bsdName: bsdName, isCancelled: isCancelled)
    }
    /// Compatibility API: incomplete/unavailable is never an empty success.
    public static func recentErrors(withinMinutes minutes: Int, bsdName: String? = nil,
                                    timeout: TimeInterval = 20) -> [IOErrorEvent]? {
        do {
            let result = try scan(withinMinutes: minutes, bsdName: bsdName, timeout: timeout)
            return result.isComplete ? result.events : nil
        } catch { return nil }
    }
    static func makeCommand(withinMinutes minutes: Int, bsdName: String?, timeout: TimeInterval) throws -> ProcessCommand {
        guard (1...1440).contains(minutes), bsdName.map({ $0.range(of: "^disk[0-9]+(s[0-9]+)*$", options: .regularExpression) != nil }) ?? true else { throw IOErrorScanError.invalidRequest }
        var predicate = "process == \"kernel\" AND (eventMessage CONTAINS[c] \"I/O error\" OR eventMessage CONTAINS[c] \"read error\" OR eventMessage CONTAINS[c] \"write error\")"
        if let bsdName { predicate += " AND eventMessage CONTAINS \"\(bsdName)\"" }
        var command = ProcessCommand("/usr/bin/log", ["show", "--last", "\(minutes)m", "--style", "ndjson", "--info", "--debug", "--predicate", predicate], timeout: timeout, scope: "kernel-log-scan")
        command.stdoutLimit = maximumOutputBytes
        return command
    }

    /// Parse one bounded record at a time. Unknown time is discarded with a
    /// diagnostic, never replaced with now. Limits throw instead of presenting
    /// the collected prefix as a complete scan.
    static func parseNDJSON(_ data: Data, since: Date, through: Date, bsdName: String? = nil,
                            maximumEvents: Int = maximumEvents, maximumLineBytes: Int = maximumLineBytes,
                            maximumRows: Int = maximumRows,
                            isCancelled: @Sendable () -> Bool = { false }) throws -> IOErrorScan {
        guard data.count <= maximumOutputBytes, maximumEvents > 0, maximumEvents <= Self.maximumEvents,
              maximumLineBytes > 0, maximumLineBytes <= Self.maximumLineBytes,
              maximumRows > 0, maximumRows <= Self.maximumRows,
              since.timeIntervalSince1970.isFinite, through.timeIntervalSince1970.isFinite, since <= through else { throw IOErrorScanError.invalidRequest }
        var events: [IOErrorEvent] = [], diagnostics = IOErrorScanDiagnostics(), rows = 0, eventRows = 0
        var finishedCount: Int?
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            for end in 0...bytes.count {
                if end - start > maximumLineBytes { throw IOErrorScanError.lineLimit }
                if end != bytes.count && bytes[end] != 10 { continue }
                if isCancelled() { throw CommandError(.cancelled) }
                if end == bytes.count && start == end { continue }
                rows += 1; guard rows <= maximumRows else { throw IOErrorScanError.rowLimit }
                defer { start = end + 1 }
                if end == start { continue }
                let line = Data(bytes[start..<end])
                guard let object = try? JSONSerialization.jsonObject(with: line), let dictionary = object as? [String: Any] else { diagnostics.malformedLines += 1; continue }
                guard finishedCount == nil else { diagnostics.malformedLines += 1; continue }
                // macOS log emits a terminal NDJSON control record. It is not
                // an event, and its count must agree with the event records.
                if dictionary.keys.sorted() == ["count", "finished"],
                   let finished = dictionary["finished"] as? NSNumber,
                   finished.doubleValue == 1,
                   let count = dictionary["count"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(),
                   count.doubleValue.isFinite, count.doubleValue == Double(count.int64Value),
                   count.int64Value >= 0, count.int64Value <= Int64(Self.maximumRows) {
                    finishedCount = count.intValue
                    continue
                }
                guard let message = dictionary["eventMessage"] as? String else { diagnostics.malformedLines += 1; continue }
                eventRows += 1
                guard let timestamp = dictionary["timestamp"] as? String, let date = parseTimestamp(timestamp) else {
                    diagnostics.invalidTimestamps += 1; continue
                }
                guard date >= since, date <= through else { diagnostics.outsideWindow += 1; continue }
                let event = IOErrorEvent(date: date, message: message)
                if let bsdName, !event.mentions(bsdName) { continue }
                guard events.count < maximumEvents else { throw IOErrorScanError.eventLimit }
                events.append(event)
            }
        }
        if let finishedCount, finishedCount != eventRows { diagnostics.malformedLines += 1 }
        return .init(events: events, diagnostics: diagnostics)
    }
    private static let timestampPattern = try! NSRegularExpression(pattern:
        "^([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\\.([0-9]{1,9}))?(Z|[+-][0-9]{2}:?[0-9]{2})$")
    static func parseTimestamp(_ text: String) -> Date? {
        guard text.utf8.count <= 40, let match = timestampPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func field(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        guard let year = field(1).flatMap(Int.init), let month = field(2).flatMap(Int.init), let day = field(3).flatMap(Int.init),
              let hour = field(4).flatMap(Int.init), let minute = field(5).flatMap(Int.init), let second = field(6).flatMap(Int.init),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second), let zone = field(8) else { return nil }
        var offset = 0
        if zone != "Z" {
            let digits = zone.dropFirst().filter { $0 != ":" }
            guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)), hours <= 23, minutes <= 59 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        guard let timezone = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        let normalized = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from: date)
        guard normalized.year == year, normalized.month == month, normalized.day == day,
              normalized.hour == hour, normalized.minute == minute, normalized.second == second else { return nil }
        let fraction = field(7).flatMap { Double("0." + $0) } ?? 0
        return date.addingTimeInterval(fraction)
    }
}
