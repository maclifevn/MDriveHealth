/*
 * Canonical meanings, shared by scoring, history, alerts and exports.
 * ATA IDs alone do not define units or meaning; drivedb overrides take precedence.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */
import Foundation

public enum ATAMetric: Sendable, Equatable {
    case reallocated, reallocationEvents, pending, uncorrectable, reportedUncorrectable
    case spinRetry, endToEnd, commandTimeout, crc
}

public enum ATAMetrics {
    public static func meaning(of attribute: ATAAttribute, in reading: ATASMARTReading) -> ATAMetric? {
        guard trusted(attribute, in: reading), attribute.rawIsValid else { return nil }
        switch attribute.name.lowercased() {
        case "reallocated_sector_ct", "reallocated_sector_count": return .reallocated
        case "reallocated_event_count": return .reallocationEvents
        case "current_pending_sector", "current_pending_sector_count", "pending_sector_count": return .pending
        case "offline_uncorrectable", "offline_uncorrectable_sector_ct", "uncorrectable_sector_ct": return .uncorrectable
        case "reported_uncorrect", "reported_uncorr_errors", "reported_uncorrectable_errors": return .reportedUncorrectable
        case "spin_retry_count": return reading.identify?.rpm != nil ? .spinRetry : nil
        case "end-to-end_error", "end-to-end_error_count", "end_to_end_error": return .endToEnd
        case "command_timeout": return .commandTimeout
        case "udma_crc_error_count", "sata_crc_error_count", "sata_crc_error", "sata_fis_crc_errors", "crc_error_count": return .crc
        default: return nil
        }
    }

    public static func temperature(in reading: ATASMARTReading) -> Int? {
        for attribute in reading.attributes where trusted(attribute, in: reading) && attribute.rawIsValid {
            guard ["temperature_celsius", "airflow_temperature_cel"].contains(attribute.name.lowercased()) else { continue }
            if let decoded = attribute.decodedTemperatureCelsius, (-60...120).contains(decoded) { return decoded }
            // Only plain, explicitly temperature-labelled counters may use the integer directly.
            if attribute.format == nil || attribute.format == "raw48", attribute.rawValue <= 120 {
                return Int(attribute.rawValue)
            }
        }
        return nil
    }

    public static func powerOnHours(in reading: ATASMARTReading) -> UInt64? {
        quantity(names: ["power_on_hours", "power_on_hours_and_msec", "power_on_minutes", "power_on_seconds", "power_on_half_minutes"], in: reading)
    }
    public static func powerCycles(in reading: ATASMARTReading) -> UInt64? {
        quantity(names: ["power_cycle_count"], in: reading)
    }
    public static func hostBytesWritten(in reading: ATASMARTReading) -> UInt64? {
        for attribute in reading.attributes where trusted(attribute, in: reading) && attribute.rawIsValid {
            let scale: UInt64
            switch attribute.name.lowercased() {
            case "total_lbas_written", "total_host_lba_written", "host_writes_512b", "host_write_sectors", "total_sectors_written": scale = 512
            case "host_writes_gib", "host_writes_1gib", "host_writes_gib_total", "lifetime_writes_gib": scale = 1_073_741_824
            case "host_writes_32mib", "host_writes_32mib_total": scale = 33_554_432
            case "host_writes_gb", "host_writes_1gb", "lifetime_wts_frm_hst_gb": scale = 1_000_000_000
            default: continue
            }
            let product = attribute.rawValue.multipliedReportingOverflow(by: scale)
            return product.overflow ? nil : product.partialValue
        }
        return nil
    }

    public static func count(_ metric: ATAMetric, in reading: ATASMARTReading) -> UInt64? {
        reading.attributes.first { meaning(of: $0, in: reading) == metric }?.rawValue
    }

    /// A reported count, not unique physical damaged sectors. Overlapping vendor
    /// counters can count the same event, so this is only a monitoring signal.
    public static func defects(in reading: ATASMARTReading) -> UInt64? {
        checkedSum([count(.reallocated, in: reading), count(.reportedUncorrectable, in: reading), count(.uncorrectable, in: reading)])
    }
    public static func checkedSum(_ values: [UInt64?]) -> UInt64? {
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        var total: UInt64 = 0
        for value in known {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    public static func lifetimeLeft(in reading: ATASMARTReading) -> Int? {
        guard reading.identify?.isSolidState == true, let family = reading.driveFamily else { return nil }
        for attribute in reading.attributes where attribute.rawIsValid && attribute.currentIsNormalized && attribute.current <= 100 {
            let name = attribute.name.lowercased(), id = attribute.attributeID
            // Explicit family rules: normalized values are remaining endurance;
            // raw values may be erase counts or used percent and are not interchangeable.
            let samsung = family == "Samsung based SSDs" && (id == 177 || id == 173) && name == "wear_leveling_count"
            let intel = (family.hasPrefix("Intel ") || family.hasPrefix("Solidigm ")) && id == 233 && name == "media_wearout_indicator"
            let micron = (family.hasPrefix("Crucial/Micron ") || family.hasPrefix("Micron ")) && id == 202 && ["percent_lifetime_used", "perc_rated_life_used", "percent_lifetime_remain"].contains(name)
            let explicitlyRemaining = attribute.nameSource == .vendor && ["ssd_life_left", "lifetime_left"].contains(name)
            if samsung || intel || micron || explicitlyRemaining { return Int(attribute.current) }
        }
        return nil
    }

    static func trusted(_ attribute: ATAAttribute, in reading: ATASMARTReading) -> Bool {
        if attribute.nameSource == .explicit || attribute.nameSource == .vendor { return true }
        // Standard HDD meanings remain useful for unlisted rotational drives.
        // Generic SSD counters need a known model family; an unknown ID cannot certify health.
        return reading.identify?.rpm != nil || reading.driveFamily != nil
    }
    private static func quantity(names: [String], in reading: ATASMARTReading) -> UInt64? {
        reading.attributes.first { $0.rawIsValid && trusted($0, in: reading) && names.contains($0.name.lowercased()) }?.rawValue
    }
}
