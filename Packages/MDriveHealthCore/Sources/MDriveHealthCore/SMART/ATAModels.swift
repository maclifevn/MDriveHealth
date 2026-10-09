/*
 * ATAModels.swift — Swift models for ATA SMART data.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

/// One decoded ATA SMART attribute (12-byte entry from SMART READ DATA).
public struct ATAAttribute: Sendable, Codable, Hashable, Identifiable {
    public let attributeID: UInt8
    public let name: String
    public let flags: UInt16
    /// Normalized value, typically 1...253 (higher is better).
    public let current: UInt8
    /// Worst normalized value seen over the drive's life.
    public let worst: UInt8
    /// Failure threshold from SMART READ THRESHOLDS; nil when unavailable.
    public let threshold: UInt8?
    /// The 6 vendor raw bytes, little-endian (index 0 = LSB).
    public let rawBytes: [UInt8]
    /// Primary numeric value decoded per the drivedb format.
    public let rawValue: UInt64
    /// Human-readable raw value, e.g. "34 (Min/Max 21/45)".
    public let rawDisplay: String

    public let format: String?
    public let nameSource: ATANameSource
    public let rawIsValid: Bool
    public let currentIsNormalized: Bool
    public let worstIsNormalized: Bool
    public let decodedTemperatureCelsius: Int?

    public init(attributeID: UInt8, name: String, flags: UInt16, current: UInt8,
                worst: UInt8, threshold: UInt8?, rawBytes: [UInt8], rawValue: UInt64,
                rawDisplay: String, format: String? = nil, nameSource: ATANameSource = .explicit,
                rawIsValid: Bool = true, currentIsNormalized: Bool = true,
                worstIsNormalized: Bool = true, decodedTemperatureCelsius: Int? = nil) {
        self.attributeID = attributeID; self.name = name; self.flags = flags
        self.current = current; self.worst = worst; self.threshold = threshold
        self.rawBytes = rawBytes; self.rawValue = rawValue; self.rawDisplay = rawDisplay
        self.format = format; self.nameSource = nameSource; self.rawIsValid = rawIsValid
        self.currentIsNormalized = currentIsNormalized; self.worstIsNormalized = worstIsNormalized
        self.decodedTemperatureCelsius = decodedTemperatureCelsius
    }

    public var hasComparableCurrent: Bool { currentIsNormalized && (1...253).contains(current) }
    public var hasComparableWorst: Bool { worstIsNormalized && (1...253).contains(worst) }
    public var id: UInt8 { attributeID }
    /// Pre-fail attribute: crossing the threshold predicts imminent failure.
    public var isPrefail: Bool { flags & 0x0001 != 0 }
    /// Updated during online operation (vs. offline data collection only).
    public var isOnline: Bool { flags & 0x0002 != 0 }
    /// Currently at/below threshold — the drive is failing this attribute.
    public var failedNow: Bool {
        guard hasComparableCurrent, let threshold, threshold > 0, threshold < 254 else { return false }
        return current <= threshold
    }
    /// Was at/below threshold at some point in the past.
    public var failedEver: Bool {
        guard hasComparableWorst, let threshold, threshold > 0, threshold < 254 else { return false }
        return worst <= threshold
    }
}

/// Decoded self-test execution status (byte 363 of SMART READ DATA).
public struct ATASelfTestStatus: Sendable, Codable, Hashable {
    public let rawByte: UInt8

    public var inProgress: Bool { rawByte >> 4 == 0xF }
    /// Remaining share of the running self-test, 0-90 percent, tens only.
    public var percentRemaining: Int? {
        guard inProgress, rawByte & 0x0F <= 9 else { return nil }
        return Int(rawByte & 0x0F) * 10
    }
    public var statusCode: UInt8 { rawByte >> 4 }
    /// Same status-nibble semantics as ATASelfTestLogEntry.
    public var passed: Bool { statusCode == 0 }
    /// Aborted by host or interrupted by reset — not a drive fault.
    public var wasAborted: Bool { statusCode == 1 || statusCode == 2 }
}

/// One entry of the SMART self-test log (log address 0x06), newest first.
public struct ATASelfTestLogEntry: Sendable, Codable, Hashable, Identifiable {
    /// 1 = most recent. Stable within one log read.
    public let index: Int
    /// Self-test number: 1 = short offline, 2 = extended offline,
    /// 0x81/0x82 = captive variants.
    public let testType: UInt8
    /// Raw status: high nibble = result code, low nibble = remaining %/10.
    public let statusByte: UInt8
    /// Drive power-on hours when the test finished (16-bit lifetime stamp,
    /// wraps at 65 536 h).
    public let powerOnHours: UInt64
    /// First failing LBA — only meaningful when the read element failed.
    public let failingLBA: UInt64?
    /// Physical descriptor slot (1...21), separate from newest-first index.
    public let physicalSlot: Int?
    public init(index: Int, testType: UInt8, statusByte: UInt8, powerOnHours: UInt64,
                failingLBA: UInt64?, physicalSlot: Int? = nil) {
        self.index = index; self.testType = testType; self.statusByte = statusByte
        self.powerOnHours = powerOnHours; self.failingLBA = failingLBA; self.physicalSlot = physicalSlot
    }

    public var id: Int { index }
    public var statusCode: UInt8 { statusByte >> 4 }
    public var passed: Bool { statusCode == 0 }
    public var inProgress: Bool { statusCode == 0xF }
    /// Remaining share when still running, 0-90 percent in tens.
    public var percentRemaining: Int { Int(statusByte & 0x0F) * 10 }
    /// Aborted by host or interrupted by reset.
    public var wasAborted: Bool { statusCode == 1 || statusCode == 2 }
    public var isExtended: Bool { testType & 0x7F == 2 }
}

/// Decoded ATA IDENTIFY DEVICE data (the subset MDriveHealth uses).
public struct ATAIdentifyInfo: Sendable, Codable, Hashable {
    public let model: String
    public let serialNumber: String
    public let firmwareRevision: String
    /// Word 217: 1 = non-rotating (SSD), 0x401...0xFFFE = RPM, else unknown.
    public let rotationRate: UInt16

    public var isSolidState: Bool { rotationRate == 1 }
    public var rpm: Int? { (0x401...0xFFFE).contains(rotationRate) ? Int(rotationRate) : nil }
}

/// A complete ATA probe result.
public struct ATASMARTReading: Sendable, Codable, Hashable {
    public let capturedAt: Date
    public let identify: ATAIdentifyInfo?
    public let attributes: [ATAAttribute]
    /// SMART RETURN STATUS verdict: true = thresholds exceeded (failing).
    /// nil when the command failed.
    public let overallFailurePredicted: Bool?
    public let selfTest: ATASelfTestStatus?
    /// nil for legacy/imported readings; true only when SMART explicitly
    /// advertises offline self-test support (byte 367, bit 4).
    public let selfTestSupported: Bool?
    /// Model family from drivedb, when matched.
    public let driveFamily: String?
    /// drivedb warning for known-problematic drives/firmware.
    public let driveWarning: String?

    public init(capturedAt: Date, identify: ATAIdentifyInfo?, attributes: [ATAAttribute],
                overallFailurePredicted: Bool?, selfTest: ATASelfTestStatus?,
                driveFamily: String?, driveWarning: String?, selfTestSupported: Bool? = nil) {
        self.capturedAt = capturedAt; self.identify = identify; self.attributes = attributes
        self.overallFailurePredicted = overallFailurePredicted; self.selfTest = selfTest
        self.driveFamily = driveFamily; self.driveWarning = driveWarning; self.selfTestSupported = selfTestSupported
    }

    public func attribute(_ id: UInt8) -> ATAAttribute? {
        attributes.first { $0.attributeID == id }
    }
}
