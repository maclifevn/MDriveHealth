/*
 * ATAParser.swift — parses raw ATA SMART / IDENTIFY structures.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public enum ATAParser {
    /// ATA SMART pages include a revision and an 8-bit checksum over all 512 bytes.
    public static func isValidSMARTPage(_ data: [UInt8]) -> Bool {
        data.count == 512 && (data[0] != 0 || data[1] != 0)
            && !(data[0] == 255 && data[1] == 255)
            && data.reduce(UInt8(0), &+) == 0
    }

    /// Parses the 512-byte SMART READ DATA structure (30 × 12-byte attribute
    /// entries at offsets 2...361) plus the optional 512-byte thresholds page.
    public static func parseAttributes(data: [UInt8], thresholds: [UInt8]?,
                                       specs: [UInt8: ATAAttributeSpec]) -> [ATAAttribute] {
        guard isValidSMARTPage(data) else { return [] }
        var thresholdByID: [UInt8: UInt8] = [:]
        if let thresholds, isValidSMARTPage(thresholds) {
            for slot in 0..<30 {
                let offset = 2 + slot * 12
                let id = thresholds[offset]
                guard id != 0 else { continue }
                guard thresholdByID[id] == nil else { thresholdByID.removeAll(); break }
                let threshold = thresholds[offset + 1]
                if threshold < 254 { thresholdByID[id] = threshold }
            }
        }

        var attributes: [ATAAttribute] = []
        for slot in 0..<30 {
            let offset = 2 + slot * 12
            let id = data[offset]
            guard id != 0 else { continue }
            let flags = UInt16(data[offset + 1]) | (UInt16(data[offset + 2]) << 8)
            let raw = Array(data[(offset + 5)...(offset + 10)])
            let spec = specs[id]
            let format = spec?.format ?? "raw48"
            let decoded = ATARawDecoder.decode(raw: raw, format: format,
                byteorder: spec?.byteorder, current: data[offset + 3],
                worst: data[offset + 4], reserved: data[offset + 11])
            guard !attributes.contains(where: { $0.attributeID == id }) else { return [] }
            attributes.append(ATAAttribute(
                attributeID: id,
                name: spec?.name ?? "Unknown_Attribute",
                flags: flags,
                current: data[offset + 3],
                worst: data[offset + 4],
                threshold: thresholdByID[id],
                rawBytes: raw,
                rawValue: decoded.value,
                rawDisplay: decoded.display, format: ATARawDecoder.canonicalFormat(format),
                nameSource: spec?.nameSource ?? .generic, rawIsValid: decoded.isValid,
                currentIsNormalized: decoded.currentIsNormalized,
                worstIsNormalized: decoded.worstIsNormalized,
                decodedTemperatureCelsius: decoded.temperatureCelsius
            ))
        }
        return attributes
    }

    /// Self-test execution status lives at byte 363 of SMART READ DATA.
    public static func parseSelfTestStatus(data: [UInt8], firmwareFixes: [String] = []) -> ATASelfTestStatus? {
        guard isValidSMARTPage(data) else { return nil }
        let status = firmwareFixes.contains("samsung3") && data[363] == 0xf0 ? 0 : data[363]
        guard status >> 4 <= 8 || (status >> 4 == 15 && status & 15 <= 9) else { return nil }
        return ATASelfTestStatus(rawByte: status)
    }

    /// Parses the 512-byte SMART self-test log (log address 0x06): 21
    /// descriptors of 24 bytes from offset 2, written as a ring buffer whose
    /// most-recent slot index (1-21, 0 = empty log) sits at byte 508.
    /// Returns entries newest-first.
    public static func parseSelfTestLog(_ bytes: [UInt8], firmwareFixes: [String] = []) -> [ATASelfTestLogEntry] {
        parseSelfTestLogSnapshot(bytes, firmwareFixes: firmwareFixes)?.entries ?? []
    }
    /// Nil means unavailable/invalid, while a revision-1 ring with head zero
    /// is a confirmed empty log. Slot identity survives chronological sorting.
    public static func parseSelfTestLogSnapshot(_ bytes: [UInt8], firmwareFixes: [String] = [],
                                               capturedAt: Date = Date()) -> ATASelfTestLog? {
        guard isValidSMARTPage(bytes), bytes[0] == 1, bytes[1] == 0 else { return nil }
        var data = bytes
        if firmwareFixes.contains("samsung") {
            data.swapAt(508, 509)
            for slot in 0..<21 { data.swapAt(2 + slot * 24, 3 + slot * 24) }
        }
        let mostRecent = Int(data[508])
        guard (0...21).contains(mostRecent) else { return nil }
        if mostRecent == 0 {
            guard (0..<21).allSatisfy({ slot in bytes[(2 + slot * 24)..<(6 + slot * 24)].allSatisfy { $0 == 0 } }) else { return nil }
            return try? .init(capturedAt: capturedAt, mostRecentSlot: 0, entries: [])
        }

        var entries: [ATASelfTestLogEntry] = []
        for back in 0..<21 {
            let slot = (mostRecent - 1 - back + 21) % 21
            let offset = 2 + slot * 24
            let testType = data[offset]
            let status = data[offset + 1]
            let hours = UInt64(data[offset + 2]) | (UInt64(data[offset + 3]) << 8)
            guard testType != 0 || status != 0 || hours != 0 else { continue }

            var lba: UInt64 = 0
            for byte in 0..<4 {
                lba |= UInt64(data[offset + 5 + byte]) << (8 * byte)
            }
            let readElementFailed = (status >> 4) == 7
            entries.append(ATASelfTestLogEntry(
                index: back + 1,
                testType: testType,
                statusByte: status,
                powerOnHours: hours,
                failingLBA: readElementFailed ? lba : nil, physicalSlot: slot + 1))
        }
        return try? .init(capturedAt: capturedAt, mostRecentSlot: mostRecent, entries: entries)
    }

    /// Parses ATA IDENTIFY DEVICE data (512 bytes, 256 little-endian words;
    /// string bytes are swapped within each word).
    public static func parseIdentify(_ data: [UInt8]) -> ATAIdentifyInfo? {
        guard data.count == 512, !data.allSatisfy({ $0 == 0 || $0 == 255 }) else { return nil }
        // IDENTIFY checksum is defined only when byte 510 carries signature A5h.
        guard data[510] != 0xa5 || data.reduce(UInt8(0), &+) == 0 else { return nil }
        let model = identifyString(data, firstWord: 27, wordCount: 20)
        guard !model.isEmpty, model.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else { return nil }
        return ATAIdentifyInfo(
            model: model,
            serialNumber: identifyString(data, firstWord: 10, wordCount: 10),
            firmwareRevision: identifyString(data, firstWord: 23, wordCount: 4),
            rotationRate: word(data, 217)
        )
    }

    private static func word(_ data: [UInt8], _ index: Int) -> UInt16 {
        UInt16(data[index * 2]) | (UInt16(data[index * 2 + 1]) << 8)
    }

    private static func identifyString(_ data: [UInt8], firstWord: Int, wordCount: Int) -> String {
        var bytes: [UInt8] = []
        for wordIndex in firstWord..<(firstWord + wordCount) {
            // ATA strings put the first character in the high byte of each word.
            bytes.append(data[wordIndex * 2 + 1])
            bytes.append(data[wordIndex * 2])
        }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }
}
