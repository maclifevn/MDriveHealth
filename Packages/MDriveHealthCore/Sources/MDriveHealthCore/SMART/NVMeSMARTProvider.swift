/*
 * NVMeSMARTProvider.swift — reads NVMe identify + SMART data through CSMART.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import IOKit
import CSMART

public struct NVMeSMARTProvider: Sendable {
    public let registryEntryID: UInt64

    public init(registryEntryID: UInt64) {
        self.registryEntryID = registryEntryID
    }

    public init(drive: DriveInfo) {
        self.init(registryEntryID: drive.registryEntryID)
    }

    public func read() throws -> NVMeReading {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard service != 0 else { throw SMARTError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var sessionPtr: OpaquePointer?
        let created = MDNVMeSessionCreate(service, &sessionPtr)
        guard created == KERN_SUCCESS, let session = sessionPtr else {
            throw SMARTError.ioKit(created, "MDNVMeSessionCreate")
        }
        defer { MDNVMeSessionDestroy(session) }

        var rawLog = MDNVMeSMARTLog()
        let logResult = MDNVMeReadSMARTLog(session, &rawLog)
        guard logResult == KERN_SUCCESS else {
            throw SMARTError.ioKit(logResult, "MDNVMeReadSMARTLog")
        }

        // Identify is optional context. A valid log with known critical warnings
        // must remain visible even if the controller identification command fails.
        var rawIdentify = MDNVMeIdentifyController()
        let identifyResult = MDNVMeReadIdentify(session, &rawIdentify, 0)
        if identifyResult != KERN_SUCCESS { rawIdentify = MDNVMeIdentifyController() }
        let controller = Self.decode(identify: rawIdentify)
        let smart = Self.decode(log: rawLog)
        guard smart.hasUsableHealthData else {
            throw SMARTError.invalidPayload("NVMe identify or health log is empty/invalid")
        }
        return NVMeReading(controller: controller, smart: smart)
    }

    static func decode(identify id: MDNVMeIdentifyController) -> NVMeControllerInfo {
        let version: String?
        if id.ver != 0 {
            version = "\(id.ver >> 16).\((id.ver >> 8) & 0xFF).\(id.ver & 0xFF)"
        } else {
            version = nil
        }
        let oui = withUnsafeBytes(of: id.ieee) { raw in
            String(format: "%02X-%02X-%02X", raw[2], raw[1], raw[0])
        }
        return NVMeControllerInfo(
            model: fixedString(id.modelNumber),
            serialNumber: fixedString(id.serialNumber),
            firmwareRevision: fixedString(id.firmwareRevision),
            ieeeOUI: oui,
            controllerID: id.cntlid,
            specVersion: version,
            totalCapacityBytes: leUInt64(id.tnvmcap),
            unallocatedCapacityBytes: leUInt64(id.unvmcap),
            warningTempKelvin: id.wctemp,
            criticalTempKelvin: id.cctemp,
            namespaceCount: id.nn
        )
    }

    static func decode(log: MDNVMeSMARTLog) -> NVMeSMARTSnapshot {
        let sensors = withUnsafeBytes(of: log.temperatureSensor) { raw in
            (0..<8).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        }
        let temperature = withUnsafeBytes(of: log.temperature) { raw in
            UInt16(littleEndian: raw.loadUnaligned(as: UInt16.self))
        }
        let counters: [(String, Bool)] = [
            ("dataUnitsRead", highBitsSet(log.dataUnitsRead)), ("dataUnitsWritten", highBitsSet(log.dataUnitsWritten)),
            ("hostReadCommands", highBitsSet(log.hostReadCommands)), ("hostWriteCommands", highBitsSet(log.hostWriteCommands)),
            ("controllerBusyTimeMinutes", highBitsSet(log.controllerBusyTime)), ("powerCycles", highBitsSet(log.powerCycles)),
            ("powerOnHours", highBitsSet(log.powerOnHours)), ("unsafeShutdowns", highBitsSet(log.unsafeShutdowns)),
            ("mediaErrors", highBitsSet(log.mediaErrors)), ("errorLogEntries", highBitsSet(log.errorLogEntries))]
        return NVMeSMARTSnapshot(
            capturedAt: Date(),
            criticalWarning: NVMeCriticalWarning(rawValue: log.criticalWarning),
            temperatureKelvin: temperature,
            availableSpare: log.availableSpare,
            availableSpareThreshold: log.availableSpareThreshold,
            percentageUsed: log.percentageUsed,
            dataUnitsRead: leUInt64(log.dataUnitsRead),
            dataUnitsWritten: leUInt64(log.dataUnitsWritten),
            hostReadCommands: leUInt64(log.hostReadCommands),
            hostWriteCommands: leUInt64(log.hostWriteCommands),
            controllerBusyTimeMinutes: leUInt64(log.controllerBusyTime),
            powerCycles: leUInt64(log.powerCycles),
            powerOnHours: leUInt64(log.powerOnHours),
            unsafeShutdowns: leUInt64(log.unsafeShutdowns),
            mediaErrors: leUInt64(log.mediaErrors),
            errorLogEntries: leUInt64(log.errorLogEntries),
            warningTempTimeMinutes: log.warningTempTime,
            criticalTempTimeMinutes: log.criticalCompTime,
            temperatureSensorsKelvin: sensors, unavailableCounters: Set(counters.filter { $0.1 }.map { $0.0 })
        )
    }
}

/// Decodes a fixed-size C char array (imported as a tuple) holding a
/// space-padded ASCII string, as used in NVMe identify data.
func fixedString<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Reads the low 64 bits of a little-endian fixed-size byte array (imported as
/// a tuple), as used for the 128-bit counters in NVMe structures.
func leUInt64<T>(_ value: T) -> UInt64 {
    withUnsafeBytes(of: value) { raw in
        UInt64(littleEndian: raw.loadUnaligned(as: UInt64.self))
    }
}

/// A 128-bit value that does not fit UInt64 must not wrap to a smaller history counter.
private func highBitsSet<T>(_ value: T) -> Bool {
    withUnsafeBytes(of: value) { $0.dropFirst(8).contains { $0 != 0 } }
}
