/*
 * DriveIdentity.swift — identity confidence for history and notification routing.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */
import Foundation
import CryptoKit

public struct DriveIdentity: Sendable, Codable, Hashable {
    public enum Source: String, Sendable, Codable { case smartSerial, discoverySerial, mediaUUID, session, ambiguous }
    public let key: String
    public let source: Source
    public var isPersistent: Bool { source != .session && source != .ambiguous }
    public static let processSession = UUID().uuidString

    public static func resolve(for drive: DriveInfo, reading: DriveReading? = nil,
                               session: String = processSession) -> DriveIdentity {
        let smartModel: String?
        let smartSerial: String?
        switch reading {
        case .ata(let value): smartModel = value.identify?.model; smartSerial = value.identify?.serialNumber
        case .nvme(let value): smartModel = value.controller.model; smartSerial = value.controller.serialNumber
        case nil: smartModel = nil; smartSerial = nil
        }
        let model = clean(smartModel) ?? clean(drive.model) ?? "unknown-model"
        if let serial = validSerial(smartSerial) {
            return .init(key: digest(kind: "serial", values: [model, serial]), source: .smartSerial)
        }
        if let serial = validSerial(drive.serialNumber) {
            return .init(key: digest(kind: "serial", values: [model, serial]), source: .discoverySerial)
        }
        if let raw = clean(drive.mediaUUID), let uuid = UUID(uuidString: raw), uuid != UUID(uuidString: "00000000-0000-0000-0000-000000000000") {
            return .init(key: digest(kind: "media", values: [uuid.uuidString]), source: .mediaUUID)
        }
        return sessionIdentity(for: drive, session: session)
    }

    public static func sessionIdentity(for drive: DriveInfo, session: String = processSession,
                                       ambiguous: Bool = false) -> DriveIdentity {
        .init(key: digest(kind: "session", values: [session, String(drive.registryEntryID), drive.model, String(drive.sizeBytes)]),
              source: ambiguous ? .ambiguous : .session)
    }

    /// Duplicate purportedly stable identities in one fleet cannot be used to
    /// merge history. Resolve every participant to its separate session key.
    public static func isolatedFleet(_ candidates: [(DriveInfo, DriveIdentity)],
                                     session: String = processSession,
                                     knownAmbiguousKeys: Set<String> = []) -> [UInt64: DriveIdentity] {
        let grouped = Dictionary(grouping: candidates, by: { $0.1.key })
        var result: [UInt64: DriveIdentity] = [:]
        for group in grouped.values {
            for (drive, identity) in group {
                result[drive.id] = (group.count > 1 || knownAmbiguousKeys.contains(identity.key))
                    ? sessionIdentity(for: drive, session: session, ambiguous: true) : identity
            }
        }
        return result
    }

    public static func notificationURL(forKey key: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mdrivehealth"; components.host = "drive"
        components.queryItems = [.init(name: "key", value: key)]
        return components.url
    }
    public static func notificationKey(from url: URL) -> String? {
        guard url.scheme == "mdrivehealth", url.host == "drive",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "key", let key = items[0].value,
              key.hasPrefix("drive:v2:"), key.count <= 100 else { return nil }
        return key
    }
    public static func matchingRegistryID(forKey key: String, in identities: [(UInt64, DriveIdentity)]) -> UInt64? {
        let matches = identities.filter { $0.1.key == key }
        return matches.count == 1 ? matches[0].0 : nil
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.utf8.count <= 256,
              !cleaned.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return cleaned
    }
    static func validSerial(_ value: String?) -> String? {
        guard let value = clean(value) else { return nil }
        let lower = value.lowercased()
        guard !["unknown", "none", "null", "n/a", "not available", "default", "serial number", "to be filled by o.e.m.", "0123456789", "123456789"].contains(lower),
              !lower.allSatisfy({ $0 == "0" }), !lower.allSatisfy({ $0 == "f" }) else { return nil }
        return value
    }
    private static func digest(kind: String, values: [String]) -> String {
        // Length-prefix each value: model/serial delimiters cannot collide.
        let bytes = values.map { "\($0.utf8.count):\($0)" }.joined()
        let hash = SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
        return "drive:v2:\(kind):\(hash)"
    }
}
