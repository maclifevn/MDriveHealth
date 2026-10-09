/*
 * DriveReading.swift — transport-agnostic probe result + prober.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

/// A complete SMART probe of one drive, regardless of transport.
public enum DriveReading: Sendable, Codable, Hashable {
    case nvme(NVMeReading)
    case ata(ATASMARTReading)

    public func evaluateHealth() -> HealthReport {
        switch self {
        case .nvme(let reading): return HealthEvaluator.evaluate(nvme: reading)
        case .ata(let reading): return HealthEvaluator.evaluate(ata: reading)
        }
    }

    public var temperatureCelsius: Int? {
        switch self {
        case .nvme(let reading):
            return reading.smart.temperatureCelsius
        case .ata(let reading):
            return ATAMetrics.temperature(in: reading)
        }
    }

    public var powerOnHours: UInt64? {
        switch self {
        case .nvme(let reading): return reading.smart.counterValue("powerOnHours")
        case .ata(let reading): return ATAMetrics.powerOnHours(in: reading)
        }
    }

    public var powerCycles: UInt64? {
        switch self {
        case .nvme(let reading): return reading.smart.counterValue("powerCycles")
        case .ata(let reading): return ATAMetrics.powerCycles(in: reading)
        }
    }

    /// Total bytes written by the host, when the drive reports it.
    public var bytesWritten: UInt64? {
        switch self {
        case .nvme(let reading):
            return reading.smart.bytesWritten
        case .ata(let reading):
            return ATAMetrics.hostBytesWritten(in: reading)
        }
    }

    public var capturedAt: Date {
        switch self {
        case .nvme(let reading): return reading.smart.capturedAt
        case .ata(let reading): return reading.capturedAt
        }
    }

    /// Reported media defect/error counters. ATA counters may overlap or reset;
    /// this is a monitoring signal, not a count of unique physical damaged sectors.
    /// Nil when no counter meaning is known or the sum cannot be represented.
    public var defectCount: UInt64? {
        switch self {
        case .nvme(let reading):
            return reading.smart.hasUsableHealthData ? reading.smart.knownMediaErrors : nil
        case .ata(let reading):
            return ATAMetrics.defects(in: reading)
        }
    }

    /// Sectors awaiting reallocation (ATA attribute 197); nil for NVMe.
    public var pendingSectors: UInt64? {
        switch self {
        case .nvme: return nil
        case .ata(let reading): return ATAMetrics.count(.pending, in: reading)
        }
    }

    /// The "growing defects" signal used by alerts and risk assessment:
    /// reported defect/error counters plus known pending sectors.
    public var dangerousDefectTotal: UInt64? {
        ATAMetrics.checkedSum([defectCount, pendingSectors])
    }

    /// Self-test execution status; nil for NVMe (macOS cannot run NVMe
    /// self-tests) and for ATA drives that did not report one.
    public var ataSelfTest: ATASelfTestStatus? {
        if case .ata(let reading) = self { return reading.selfTest }
        return nil
    }

    public var selfTestInProgress: Bool {
        ataSelfTest?.inProgress == true
    }
}

/// Outcome of a power-aware probe.
public enum DriveProbeResult: Sendable {
    case reading(DriveReading)
    /// A rotational drive was left spun down instead of being woken.
    case skippedAsleep
}

/// Probes a drive using whichever SMART transport it supports.
public enum DriveProber {
    public static func read(drive: DriveInfo) throws -> DriveReading {
        switch drive.smartInterface {
        case .nvme:
            return .nvme(try NVMeSMARTProvider(drive: drive).read())
        case .ata:
            return .ata(try ATASMARTProvider(drive: drive).read())
        case .unsupported:
            throw SMARTError.unsupportedTransport
        }
    }

    /// Probes honoring a power policy. When `avoidWakingIdle` is true, a
    /// rotational (non-SSD) drive that IOKit reports as spun down is left
    /// asleep rather than being woken by a SMART command — reading the
    /// registry power state never wakes the device, unlike a SMART read.
    /// SSDs and drives of unknown power state are always read.
    public static func probe(drive: DriveInfo,
                             avoidWakingIdle: Bool) throws -> DriveProbeResult {
        if avoidWakingIdle, !drive.isSolidState,
           DrivePower.isLikelyAsleep(registryEntryID: drive.registryEntryID) == true {
            return .skippedAsleep
        }
        return .reading(try read(drive: drive))
    }
}
