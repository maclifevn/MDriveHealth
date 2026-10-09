/*
 * DriveDB.swift — drive-specific ATA attribute database, generated from
 * smartmontools drivedb.h (GPL-2.0-or-later) by tools/convert_drivedb.py.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

/// How to decode and label one ATA SMART attribute for a matched drive.
public enum ATANameSource: String, Codable, Sendable { case generic, vendor, explicit }

public struct ATAAttributeSpec: Codable, Sendable, Hashable {
    public let format: String
    public let byteorder: String?
    public let name: String?
    /// "HDD" or "SSD" when the override only applies to that medium.
    public let onlyFor: String?
    public let nameSource: ATANameSource?

    public init(format: String, byteorder: String? = nil, name: String? = nil,
                onlyFor: String? = nil, nameSource: ATANameSource? = nil) {
        self.format = format
        self.byteorder = byteorder
        self.name = name
        self.onlyFor = onlyFor
        self.nameSource = nameSource
    }
}

public struct DriveDBEntry: Codable, Sendable {
    public let family: String
    public let model: String
    public let firmware: String?
    public let warning: String?
    public let attrs: [String: ATAAttributeSpec]?
    public let firmwareFixes: [String]?
}

/// Result of matching a drive against the database: merged attribute specs
/// (defaults overlaid with the entry's vendor-specific presets).
public struct DriveDBMatch: Sendable {
    public let family: String?
    public let warning: String?
    public let specs: [UInt8: ATAAttributeSpec]
    /// samsung/samsung3 apply to the self-test structures this app reads.
    /// samsung2/xerrorlba/nologdir concern error logs/log directories, which
    /// are not read here; preserve them for future readers rather than applying
    /// unrelated transformations to attributes.
    public let firmwareFixes: [String]
}

public final class DriveDB: @unchecked Sendable {
    public static let shared: DriveDB = {
        do { return try DriveDB() } catch {
            fatalError("drivedb.json bundled resource is invalid: \(error)")
        }
    }()

    public let version: String
    public let entries: [DriveDBEntry]
    private let defaults: [UInt8: ATAAttributeSpec]

    private let lock = NSLock()
    private var regexCache: [Int: NSRegularExpression?] = [:]

    private struct File: Codable {
        let drivedbVersion: String
        let defaults: [String: ATAAttributeSpec]
        let entries: [DriveDBEntry]
    }

    public init() throws {
        guard let url = Bundle.module.url(forResource: "drivedb", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        self.version = file.drivedbVersion
        self.entries = file.entries
        self.defaults = Self.byAttributeID(file.defaults)
    }

    /// Matches like smartmontools: first entry whose model regex (and firmware
    /// regex, when present) full-matches wins.
    public func match(model: String, firmware: String?, isSSD: Bool?) -> DriveDBMatch {
        var merged = defaultSpecs(isSSD: isSSD)
        for (index, entry) in entries.enumerated() {
            guard let modelRegex = regex(for: index * 2, pattern: entry.model),
                  fullMatch(modelRegex, model) else { continue }
            if let firmwarePattern = entry.firmware, !firmwarePattern.isEmpty {
                guard let firmware,
                      let fwRegex = regex(for: index * 2 + 1, pattern: firmwarePattern),
                      fullMatch(fwRegex, firmware) else { continue }
            }
            for (id, spec) in Self.byAttributeID(entry.attrs ?? [:]) {
                if let only = spec.onlyFor, isSSD == nil || (only == "SSD") != isSSD { continue }
                let inherited = merged[id]
                let aliasName: String? = ["unknown": "Unknown_Attribute", "emergencyretractcyclect": "Emerg_Retract_Cycle_Ct", "offlinescanuncsectorct": "Offline_Scan_UNC_SectCt", "writeerrorcount": "Write_Error_Count", "detectedtacount": "Detected_TA_Count"][spec.format]
                let increasingName = spec.format == "increasing" ? (id == 197 ? "Total_Pending_Sectors" : id == 198 ? "Total_Offl_Uncorrectabl" : nil) : nil
                merged[id] = ATAAttributeSpec(format: spec.format, byteorder: spec.byteorder,
                    name: spec.name ?? aliasName ?? increasingName ?? inherited?.name,
                    onlyFor: spec.onlyFor, nameSource: spec.name != nil || aliasName != nil || increasingName != nil ? .vendor : inherited?.nameSource)
            }
            return DriveDBMatch(family: entry.family, warning: entry.warning, specs: merged, firmwareFixes: entry.firmwareFixes ?? [])
        }
        return DriveDBMatch(family: nil, warning: nil, specs: merged, firmwareFixes: [])
    }

    /// Default attribute table (no model match), still medium-aware.
    public func defaultSpecs(isSSD: Bool? = nil) -> [UInt8: ATAAttributeSpec] {
        defaults.compactMapValues { spec in
            if let only = spec.onlyFor {
                guard let isSSD, (only == "SSD") == isSSD else { return nil }
            }
            return ATAAttributeSpec(format: spec.format, byteorder: spec.byteorder,
                name: spec.name, onlyFor: spec.onlyFor, nameSource: .generic)
        }
    }

    private static func byAttributeID(_ raw: [String: ATAAttributeSpec]) -> [UInt8: ATAAttributeSpec] {
        var result: [UInt8: ATAAttributeSpec] = [:]
        for (key, spec) in raw {
            if let id = UInt8(key) { result[id] = spec }
        }
        return result
    }

    private func regex(for key: Int, pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = regexCache[key] { return cached }
        // drivedb regexes are POSIX ERE that must match the full string.
        let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$", options: [])
        regexCache[key] = regex
        return regex
    }

    private func fullMatch(_ regex: NSRegularExpression, _ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
}
