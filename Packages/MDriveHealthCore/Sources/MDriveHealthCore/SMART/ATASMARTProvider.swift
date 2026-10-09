/*
 * ATASMARTProvider.swift — reads ATA SMART data through CSMART/ATASMARTLib.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import IOKit
import CSMART

public struct ATASMARTProvider: Sendable {
    public let registryEntryID: UInt64

    public init(registryEntryID: UInt64) {
        self.registryEntryID = registryEntryID
    }

    public init(drive: DriveInfo) {
        self.init(registryEntryID: drive.registryEntryID)
    }

    public func read(driveDB: DriveDB = .shared) throws -> ATASMARTReading {
        try withSession { session in
            // Enabling SMART operations is idempotent and required before the
            // data reads succeed on some drives.
            _ = MDATASMARTEnable(session)

            var data = [UInt8](repeating: 0, count: 512)
            let dataResult = data.withUnsafeMutableBufferPointer {
                MDATAReadSMARTData(session, $0.baseAddress)
            }
            guard dataResult == KERN_SUCCESS else {
                throw SMARTError.ioKit(dataResult, "MDATAReadSMARTData")
            }

            guard ATAParser.isValidSMARTPage(data) else {
                throw SMARTError.invalidPayload("ATA SMART checksum/revision/size")
            }

            // Thresholds and identify are best-effort: some drives/bridges
            // reject the commands while still serving attribute data.
            var thresholds: [UInt8]? = [UInt8](repeating: 0, count: 512)
            let thresholdResult = thresholds!.withUnsafeMutableBufferPointer {
                MDATAReadSMARTThresholds(session, $0.baseAddress)
            }
            if thresholdResult != KERN_SUCCESS { thresholds = nil }

            var identify: ATAIdentifyInfo?
            var identifyData = [UInt8](repeating: 0, count: 512)
            let identifyResult = identifyData.withUnsafeMutableBufferPointer {
                MDATAReadIdentify(session, $0.baseAddress)
            }
            if identifyResult == KERN_SUCCESS {
                identify = ATAParser.parseIdentify(identifyData)
            }

            var failurePredicted: Bool?
            var exceeded = false
            if MDATAReturnStatus(session, &exceeded) == KERN_SUCCESS {
                failurePredicted = exceeded
            }

            let match = driveDB.match(
                model: identify?.model ?? "",
                firmware: identify?.firmwareRevision,
                isSSD: identify.map { $0.rotationRate == 1 ? true : $0.rpm != nil ? false : nil } ?? nil
            )
            return ATASMARTReading(
                capturedAt: Date(),
                identify: identify,
                attributes: ATAParser.parseAttributes(
                    data: data, thresholds: thresholds, specs: match.specs),
                overallFailurePredicted: failurePredicted,
                selfTest: ATAParser.parseSelfTestStatus(data: data, firmwareFixes: match.firmwareFixes),
                driveFamily: match.family,
                driveWarning: match.warning,
                selfTestSupported: data[367] & 0x10 != 0
            )
        }
    }

    /// Starts a short (~2 min) or extended offline self-test.
    public func startSelfTest(extended: Bool) throws {
        var issued = false
        do {
            try withSession { session in
                issued = true
                let result = MDATAExecuteSelfTest(session, extended)
                guard result == KERN_SUCCESS else {
                    throw SMARTError.ioKit(result, "MDATAExecuteSelfTest")
                }
            }
        } catch {
            if issued { throw SelfTestCommandError.uncertain(error.localizedDescription) }
            throw SelfTestCommandError.notIssued(error.localizedDescription)
        }
    }

    /// Reads the SMART self-test log (past results, newest first). Some
    /// drives/bridges reject READ LOG while serving attribute data — callers
    /// should treat failures as "history unavailable", not as a drive fault.
    public func readSelfTestLog() throws -> [ATASelfTestLogEntry] {
        try readSelfTestLogSnapshot().entries
    }
    public func readSelfTestLogSnapshot() throws -> ATASelfTestLog {
        try withSession { session in
            _ = MDATASMARTEnable(session)
            var data = [UInt8](repeating: 0, count: 512)
            let result = data.withUnsafeMutableBufferPointer {
                MDATAReadLogAtAddress(session, 0x06, $0.baseAddress, 512)
            }
            guard result == KERN_SUCCESS else {
                throw SMARTError.ioKit(result, "MDATAReadLogAtAddress")
            }
            guard ATAParser.isValidSMARTPage(data) else { throw SMARTError.invalidPayload("ATA self-test log checksum/revision/size") }
            var identifyBytes = [UInt8](repeating: 0, count: 512)
            let identifyResult = identifyBytes.withUnsafeMutableBufferPointer { MDATAReadIdentify(session, $0.baseAddress) }
            let identify = identifyResult == KERN_SUCCESS ? ATAParser.parseIdentify(identifyBytes) : nil
            let match = DriveDB.shared.match(model: identify?.model ?? "", firmware: identify?.firmwareRevision,
                                             isSSD: identify?.isSolidState)
            guard let log = ATAParser.parseSelfTestLogSnapshot(data, firmwareFixes: match.firmwareFixes) else {
                throw SMARTError.invalidPayload("ATA self-test log ring/revision")
            }
            return log
        }
    }

    private func withSession<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard service != 0 else { throw SMARTError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var sessionPtr: OpaquePointer?
        let created = MDATASessionCreate(service, &sessionPtr)
        guard created == KERN_SUCCESS, let session = sessionPtr else {
            throw SMARTError.ioKit(created, "MDATASessionCreate")
        }
        defer { MDATASessionDestroy(session) }
        return try body(session)
    }
}
