/*
 * RiskAdvisor.swift — human-readable risk summaries and next actions.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

enum DriveRiskLevel: Int, Comparable {
    case healthy, watch, backupSoon, backupNow

    static func < (lhs: DriveRiskLevel, rhs: DriveRiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: Color {
        switch self {
        case .healthy: return StatusPalette.positive.foreground
        case .watch: return StatusPalette.information.foreground
        case .backupSoon: return StatusPalette.caution.foreground
        case .backupNow: return StatusPalette.danger.foreground
        }
    }

    var systemImage: String {
        switch self {
        case .healthy: return "checkmark.seal.fill"
        case .watch: return "eye.fill"
        case .backupSoon: return "externaldrive.badge.timemachine"
        case .backupNow: return "exclamationmark.triangle.fill"
        }
    }
}

struct DriveRiskAdvice {
    let level: DriveRiskLevel
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actions: [LocalizedStringKey]
}

enum RiskAdvisor {
    static func advice(for snapshot: DriveSnapshot) -> DriveRiskAdvice {
        guard let health = snapshot.health else {
            if snapshot.drive.smartInterface == .unsupported {
                return DriveRiskAdvice(
                    level: .watch,
                    title: "risk.unsupported.title",
                    message: "risk.unsupported.message",
                    actions: [
                        "risk.unsupported.action.backup",
                        "risk.unsupported.action.passthrough",
                        "risk.unsupported.action.io",
                    ])
            }
            return DriveRiskAdvice(
                level: .watch,
                title: "risk.noSmart.title",
                message: "risk.noSmart.message",
                actions: ["risk.noSmart.action.refresh", "risk.noSmart.action.permission"])
        }

        if health.rating >= .failing || hasCriticalMediaIssue(snapshot) {
            return DriveRiskAdvice(
                level: .backupNow,
                title: "risk.backupNow.title",
                message: "risk.backupNow.message",
                actions: [
                    "risk.backupNow.action.backup",
                    "risk.backupNow.action.limitWrites",
                    "risk.backupNow.action.replace",
                ])
        }

        if health.rating >= .warning || hasGrowingDefects(snapshot) {
            return DriveRiskAdvice(
                level: .backupSoon,
                title: "risk.backupSoon.title",
                message: "risk.backupSoon.message",
                actions: [
                    "risk.backupSoon.action.backup",
                    "risk.backupSoon.action.watch",
                    "risk.backupSoon.action.replace",
                ])
        }

        if let temp = snapshot.reading?.temperatureCelsius, temp >= 55 {
            return DriveRiskAdvice(
                level: .watch,
                title: "risk.temperature.title",
                message: "risk.temperature.message",
                actions: [
                    "risk.temperature.action.airflow",
                    "risk.temperature.action.recheck",
                ])
        }

        if health.coverage != .complete {
            return DriveRiskAdvice(level: .watch, title: "risk.unknown.title",
                                   message: "risk.unknown.message", actions: ["risk.unsupported.action.backup"])
        }
        return DriveRiskAdvice(
            level: .healthy,
            title: "risk.healthy.title",
            message: "risk.healthy.message",
            actions: [])
    }

    private static func hasCriticalMediaIssue(_ snapshot: DriveSnapshot) -> Bool {
        guard let reading = snapshot.reading else { return false }
        switch reading {
        case .nvme(let nvme):
            return nvme.smart.criticalWarning.contains(.mediaReadOnly)
                || nvme.smart.criticalWarning.contains(.reliabilityDegraded)
                || nvme.smart.mediaErrors > 10
        case .ata(let ata):
            return (ata.overallFailurePredicted == true)
                || (ata.attribute(197)?.rawValue ?? 0) >= 5
                || (ata.attribute(198)?.rawValue ?? 0) >= 10
        }
    }

    private static func hasGrowingDefects(_ snapshot: DriveSnapshot) -> Bool {
        (snapshot.reading?.dangerousDefectTotal ?? 0) > 0
    }
}
