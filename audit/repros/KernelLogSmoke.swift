/* Read-only operational smoke; never prints kernel event messages.
 * MDriveHealth, GPL-3.0-or-later. */
import Foundation
import MDriveHealthCore

@main struct KernelLogSmoke {
    static func main() async throws {
        let started = Date()
        var summary: [String: Any]
        do {
            let scan = try await IOErrorWatcher.scan(withinMinutes: 1)
            summary = ["available": true, "complete": scan.isComplete, "events": scan.events.count,
                "malformedLines": scan.diagnostics.malformedLines, "invalidTimestamps": scan.diagnostics.invalidTimestamps,
                "outsideWindow": scan.diagnostics.outsideWindow]
        } catch {
            summary = ["available": false, "error": error.localizedDescription]
        }
        // Record shape only, to distinguish platform framing from event data.
        let predicate = "process == \"kernel\" AND (eventMessage CONTAINS[c] \"I/O error\" OR eventMessage CONTAINS[c] \"read error\" OR eventMessage CONTAINS[c] \"write error\")"
        let raw = try await BoundedProcess.run(ProcessCommand("/usr/bin/log", ["show", "--last", "1m", "--style", "ndjson", "--info", "--debug", "--predicate", predicate], timeout: 20, scope: "kernel-log-framing"))
        let lines = raw.stdout.split(separator: 10)
        summary["outputLineShapes"] = lines.prefix(4).map { line -> String in
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) {
                if let array = object as? [Any] { return "JSON array count=\(array.count)" }
                if let dict = object as? [String: Any] { return "JSON object keys=" + dict.keys.sorted().joined(separator: ",") }
                return "JSON scalar"
            }
            let text = String(decoding: line, as: UTF8.self)
            if text.hasPrefix("Filtering the log data using ") { return "Filtering the log data using <predicate>" }
            if text.hasPrefix("Filtering log data using ") { return "Filtering log data using <predicate>" }
            return "Non-JSON text bytes=\(line.count)"
        }
        if let last = lines.last,
           let control = (try? JSONSerialization.jsonObject(with: Data(last))) as? [String: Any],
           control.keys.sorted() == ["count", "finished"],
           control["count"] is NSNumber, control["finished"] is NSNumber {
            summary["terminalControl"] = control
        }
        summary["elapsedSeconds"] = Date().timeIntervalSince(started)
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .withoutOverwriting)
        print(String(decoding: data, as: UTF8.self))
    }
}
