/*
 * HealthEvaluator.swift — deterministic drive health scoring.
 * Issue titles/details are localized (vi default, en) via the package catalog.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public enum HealthEvaluator {

    // MARK: - NVMe

    public static func evaluate(nvme reading: NVMeReading) -> HealthReport {
        var issues: [HealthIssue] = []
        var deduction = 0
        var ratingCap = HealthRating.good
        let smart = reading.smart
        let warning = smart.criticalWarning
        guard smart.hasUsableHealthData else {
            return report(deduction: 0, ratingCap: .unknown, issues: [], lifetimeLeft: nil,
                          capturedAt: smart.capturedAt, coverage: .unavailable)
        }
        let coverage: HealthCoverage = !reading.controller.model.isEmpty && smart.unavailableCounters.isEmpty ? .complete : .partial

        if warning.contains(.mediaReadOnly) {
            issues.append(.init(
                id: "nvme.readonly", severity: .critical,
                title: String(localized: "issue.nvme.readonly.title",
                              defaultValue: "Media đã chuyển sang chế độ chỉ đọc",
                              bundle: .module),
                detail: String(localized: "issue.nvme.readonly.detail",
                               defaultValue: "Controller đã khoá media ở chế độ chỉ đọc. Hãy sao lưu ngay lập tức và thay ổ.",
                               bundle: .module)))
            deduction += 60
            ratingCap = .failed
        }
        if warning.contains(.reliabilityDegraded) {
            issues.append(.init(
                id: "nvme.reliability", severity: .critical,
                title: String(localized: "issue.nvme.reliability.title",
                              defaultValue: "Độ tin cậy NVM suy giảm",
                              bundle: .module),
                detail: String(localized: "issue.nvme.reliability.detail",
                               defaultValue: "Controller báo độ tin cậy suy giảm do lỗi media hoặc lỗi nội bộ.",
                               bundle: .module)))
            deduction += 50
            ratingCap = HealthRating.worst(ratingCap, .failing)
        }
        let spareLow = warning.contains(.spareBelowThreshold)
            || (smart.availableSpareThreshold > 0
                && smart.availableSpare < smart.availableSpareThreshold)
        if spareLow {
            issues.append(.init(
                id: "nvme.spare", severity: .critical,
                title: String(localized: "issue.nvme.spare.title",
                              defaultValue: "Spare dự phòng dưới ngưỡng",
                              bundle: .module),
                detail: String(localized: "issue.nvme.spare.detail",
                               defaultValue: "Khối dự phòng còn \(Int(smart.availableSpare))%, thấp hơn ngưỡng \(Int(smart.availableSpareThreshold))%. Ổ sắp cạn vùng dự phòng.",
                               bundle: .module)))
            deduction += 40
            ratingCap = HealthRating.worst(ratingCap, .failing)
        }
        if warning.contains(.temperatureError) {
            issues.append(.init(
                id: "nvme.temperature.warning-bit", severity: .warning,
                title: String(localized: "issue.nvme.tempbit.title",
                              defaultValue: "Nhiệt độ ngoài ngưỡng cho phép",
                              bundle: .module),
                detail: String(localized: "issue.nvme.tempbit.detail",
                               defaultValue: "Controller báo đang hoạt động ngoài ngưỡng nhiệt an toàn.",
                               bundle: .module)))
            deduction += 10
        }
        if warning.contains(.volatileBackupFailed) {
            issues.append(.init(
                id: "nvme.backup", severity: .warning,
                title: String(localized: "issue.nvme.backup.title",
                              defaultValue: "Bộ backup nguồn cho bộ nhớ đệm bị hỏng",
                              bundle: .module),
                detail: String(localized: "issue.nvme.backup.detail",
                               defaultValue: "Thiết bị dự phòng mất điện cho volatile memory đã hỏng.",
                               bundle: .module)))
            deduction += 15
        }
        if warning.contains(.persistentMemoryReadOnly) {
            issues.append(.init(
                id: "nvme.pmr", severity: .warning,
                title: String(localized: "issue.nvme.pmr.title",
                              defaultValue: "Vùng persistent memory không ổn định",
                              bundle: .module),
                detail: String(localized: "issue.nvme.pmr.detail",
                               defaultValue: "Vùng persistent memory đang ở chế độ chỉ đọc hoặc không đáng tin cậy.",
                               bundle: .module)))
            deduction += 20
        }

        // Endurance (wear).
        let used = Int(smart.percentageUsed)
        let lifetimeLeft = max(0, 100 - min(100, used))
        switch used {
        case 100...:
            issues.append(.init(
                id: "nvme.wear.exhausted", severity: .warning,
                title: String(localized: "issue.wear.exhausted.title",
                              defaultValue: "Đã dùng hết tuổi thọ định mức",
                              bundle: .module),
                detail: String(localized: "issue.nvme.wear.exhausted.detail",
                               defaultValue: "Mức hao mòn theo nhà sản xuất là \(used)%. Ổ đã vượt tuổi thọ định mức — vẫn có thể hoạt động nhưng nên lên kế hoạch thay.",
                               bundle: .module)))
            deduction += 20
        case 90...:
            issues.append(.init(
                id: "nvme.wear.high", severity: .advisory,
                title: String(localized: "issue.wear.high.title",
                              defaultValue: "Tuổi thọ sắp cạn",
                              bundle: .module),
                detail: String(localized: "issue.nvme.wear.high.detail",
                               defaultValue: "Mức hao mòn theo nhà sản xuất là \(used)% tuổi thọ định mức.",
                               bundle: .module)))
            deduction += 10
        case 80...:
            deduction += 5
        default:
            break
        }

        if let mediaErrors = smart.knownMediaErrors, mediaErrors > 0 {
            let severity: IssueSeverity = mediaErrors > 10 ? .critical : .warning
            issues.append(.init(
                id: "nvme.media-errors", severity: severity,
                title: String(localized: "issue.nvme.mediaerrors.title",
                              defaultValue: "Lỗi toàn vẹn dữ liệu (media errors)",
                              bundle: .module),
                detail: String(localized: "issue.nvme.mediaerrors.detail",
                               defaultValue: "Đã xảy ra \(Int(clamping: mediaErrors)) lỗi toàn vẹn dữ liệu không khôi phục được.",
                               bundle: .module)))
            deduction += mediaErrors > 100 ? 25 : (mediaErrors > 10 ? 15 : 8)
            if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
        }

        if smart.unavailableCounters.contains("mediaErrors") {
            // Upper bits are nonzero: the exact count is unavailable, but it is
            // certainly positive and greater than every severity threshold above.
            issues.append(.init(id: "nvme.media-errors", severity: .critical,
                title: String(localized: "issue.nvme.mediaerrors.title", defaultValue: "Lỗi toàn vẹn dữ liệu (media errors)", bundle: .module),
                detail: String(localized: "issue.nvme.mediaerrors.large", defaultValue: "Ổ báo số lỗi media rất lớn; chưa hỗ trợ hiển thị chính xác bộ đếm này. Hãy sao lưu và kiểm tra ổ.", bundle: .module)))
            ratingCap = HealthRating.worst(ratingCap, .failing)
        }

        // Live temperature vs identify thresholds.
        let temp = smart.temperatureKelvin
        let critical = reading.controller.criticalTempKelvin
        let warn = reading.controller.warningTempKelvin
        if let tempC = smart.temperatureCelsius, critical > 0, temp >= critical {
            issues.append(.init(
                id: "nvme.temperature.critical", severity: .critical,
                title: String(localized: "issue.temp.critical.title",
                              defaultValue: "Nhiệt độ chạm mức nguy hiểm",
                              bundle: .module),
                detail: String(localized: "issue.nvme.temp.critical.detail",
                               defaultValue: "Nhiệt độ tổng hợp \(tempC)°C đã chạm ngưỡng nguy hiểm \(Int(critical) - 273)°C.",
                               bundle: .module)))
            deduction += 15
        } else if let tempC = smart.temperatureCelsius, warn > 0, temp >= warn {
            issues.append(.init(
                id: "nvme.temperature.high", severity: .warning,
                title: String(localized: "issue.temp.high.title",
                              defaultValue: "Nhiệt độ vượt ngưỡng cảnh báo",
                              bundle: .module),
                detail: String(localized: "issue.nvme.temp.high.detail",
                               defaultValue: "Nhiệt độ tổng hợp \(tempC)°C vượt ngưỡng cảnh báo \(Int(warn) - 273)°C.",
                               bundle: .module)))
            deduction += 8
        }

        return report(deduction: deduction, ratingCap: ratingCap, issues: issues,
                      lifetimeLeft: lifetimeLeft, capturedAt: smart.capturedAt, coverage: coverage)
    }

    // MARK: - ATA

    public static func evaluate(ata reading: ATASMARTReading) -> HealthReport {
        var issues: [HealthIssue] = []
        var deduction = 0
        var ratingCap = HealthRating.good
        let isSSD = reading.identify?.isSolidState ?? false

        if reading.overallFailurePredicted == true {
            issues.append(.init(
                id: "ata.smart-status", severity: .critical,
                title: String(localized: "issue.ata.status.title",
                              defaultValue: "SMART tổng thể: ĐANG HỎNG",
                              bundle: .module),
                detail: String(localized: "issue.ata.status.detail",
                               defaultValue: "Chính ổ đĩa dự báo sắp hỏng (đã vượt ngưỡng nhà sản xuất). Sao lưu dữ liệu ngay lập tức.",
                               bundle: .module)))
            deduction += 50
            ratingCap = .failing
        }

        for attribute in reading.attributes {
            let name = attribute.name
            let id = Int(attribute.attributeID)

            if attribute.failedNow, attribute.isPrefail {
                issues.append(.init(
                    id: "ata.\(attribute.attributeID).tripped", severity: .critical,
                    title: String(localized: "issue.ata.tripped.title",
                                  defaultValue: "\(name) dưới ngưỡng hỏng",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.tripped.detail",
                                   defaultValue: "Thuộc tính pre-fail \(id) (\(name)) có giá trị \(Int(attribute.current)), đã chạm/dưới ngưỡng \(Int(attribute.threshold ?? 0)). Ổ được dự báo sắp hỏng.",
                                   bundle: .module),
                    attributeID: attribute.attributeID))
                deduction += 40
                ratingCap = HealthRating.worst(ratingCap, .failing)
            } else if attribute.failedEver, attribute.isPrefail {
                issues.append(.init(
                    id: "ata.\(attribute.attributeID).tripped-past", severity: .warning,
                    title: String(localized: "issue.ata.trippedpast.title",
                                  defaultValue: "\(name) từng chạm ngưỡng hỏng",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.trippedpast.detail",
                                   defaultValue: "Thuộc tính pre-fail \(id) (\(name)) từng tụt xuống \(Int(attribute.worst)), chạm/dưới ngưỡng \(Int(attribute.threshold ?? 0)) trong quá khứ.",
                                   bundle: .module),
                    attributeID: attribute.attributeID))
                deduction += 10
            }

            guard let meaning = ATAMetrics.meaning(of: attribute, in: reading) else { continue }
            let raw = attribute.rawValue
            let rawInt = Int(clamping: raw)
            switch meaning {
            case .reallocated, .reallocationEvents: // reallocated sectors / reallocation events
                guard raw > 0 else { break }
                let isEvents = meaning == .reallocationEvents
                let severity: IssueSeverity = raw >= 50 ? .critical : (raw >= 5 ? .warning : .advisory)
                issues.append(.init(
                    id: "ata.\(attribute.attributeID).raw", severity: severity,
                    title: isEvents
                        ? String(localized: "issue.ata.196.title",
                                 defaultValue: "Có sự kiện cấp phát lại sector",
                                 bundle: .module)
                        : String(localized: "issue.ata.5.title",
                                 defaultValue: "Có sector đã cấp phát lại",
                                 bundle: .module),
                    detail: String(localized: "issue.ata.realloc.detail",
                                   defaultValue: "\(name) đếm được \(rawInt). Defect tăng dần là dấu hiệu bề mặt lưu trữ xuống cấp.",
                                   bundle: .module),
                    attributeID: attribute.attributeID))
                let base = isEvents ? [3, 6, 14] : [10, 20, 35]
                deduction += raw >= 50 ? base[2] : (raw >= 5 ? base[1] : base[0])
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case .pending: // current pending sectors
                guard raw > 0 else { break }
                let severity: IssueSeverity = raw >= 5 ? .critical : .warning
                issues.append(.init(
                    id: "ata.\(attribute.attributeID).raw", severity: severity,
                    title: String(localized: "issue.ata.197.title",
                                  defaultValue: "Sector không ổn định (pending)",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.197.detail",
                                   defaultValue: "\(rawInt) sector đang chờ được cấp phát lại. Dữ liệu trong đó có thể không đọc được.",
                                   bundle: .module),
                    attributeID: attribute.attributeID))
                deduction += raw >= 50 ? 40 : (raw >= 5 ? 25 : 15)
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case .uncorrectable: // offline uncorrectable
                guard raw > 0 else { break }
                let severity: IssueSeverity = raw >= 10 ? .critical : .warning
                issues.append(.init(
                    id: "ata.\(attribute.attributeID).raw", severity: severity,
                    title: String(localized: "issue.ata.198.title",
                                  defaultValue: "Sector không sửa được",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.198.detail",
                                   defaultValue: "\(rawInt) sector không thể đọc/sửa trong các lần quét offline.",
                                   bundle: .module),
                    attributeID: attribute.attributeID))
                deduction += raw >= 10 ? 30 : 15
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case .reportedUncorrectable: // reported uncorrectable errors
                guard raw > 0 else { break }
                let severity: IssueSeverity = raw >= 100 ? .critical : .warning
                issues.append(.init(
                    id: "ata.\(attribute.attributeID).raw", severity: severity,
                    title: String(localized: "issue.ata.187.title",
                                  defaultValue: "Lỗi không khôi phục được (reported)",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.187.detail",
                                   defaultValue: "\(rawInt) lỗi ECC không khôi phục được đã được ghi nhận.",
                                   bundle: .module),
                    attributeID: attribute.attributeID))
                deduction += raw >= 100 ? 30 : (raw >= 10 ? 20 : 10)
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case .spinRetry: // spin retry
                guard raw > 0, !isSSD else { break }
                let severity: IssueSeverity = raw >= 10 ? .critical : .warning
                issues.append(.init(
                    id: "ata.\(attribute.attributeID).raw", severity: severity,
                    title: String(localized: "issue.ata.10.title",
                                  defaultValue: "Trục quay phải thử lại",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.10.detail",
                                   defaultValue: "Trục quay cần \(rawInt) lần thử để đạt tốc độ — có thể do vấn đề cơ khí hoặc nguồn điện.",
                                   bundle: .module),
                    attributeID: attribute.attributeID))
                deduction += raw >= 10 ? 30 : 15
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case .endToEnd: // end-to-end error
                guard raw > 0 else { break }
                let severity: IssueSeverity = raw >= 10 ? .critical : .warning
                issues.append(.init(
                    id: "ata.\(attribute.attributeID).raw", severity: severity,
                    title: String(localized: "issue.ata.184.title",
                                  defaultValue: "Lỗi End-to-End",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.184.detail",
                                   defaultValue: "\(rawInt) lỗi parity trên đường dữ liệu giữa cache và media.",
                                   bundle: .module),
                    attributeID: attribute.attributeID))
                deduction += raw >= 10 ? 35 : 20
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case .commandTimeout: // command timeout
                guard raw >= 100 else { break }
                issues.append(.init(
                    id: "ata.\(attribute.attributeID).raw", severity: .warning,
                    title: String(localized: "issue.ata.188.title",
                                  defaultValue: "Lệnh bị quá thời gian (timeout)",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.188.detail",
                                   defaultValue: "\(rawInt) lệnh bị timeout — có thể do cáp hoặc controller có vấn đề.",
                                   bundle: .module),
                    attributeID: attribute.attributeID))
                deduction += raw >= 10_000 ? 20 : 10
            case .crc: // UDMA CRC
                guard raw > 0 else { break }
                issues.append(.init(
                    id: "ata.\(attribute.attributeID).raw", severity: raw >= 10 ? .warning : .advisory,
                    title: String(localized: "issue.ata.199.title",
                                  defaultValue: "Lỗi CRC giao tiếp",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.199.detail",
                                   defaultValue: "\(rawInt) lỗi CRC trên đường SATA — thường do cáp/đầu nối, không phải bản thân ổ đĩa.",
                                   bundle: .module),
                    attributeID: attribute.attributeID))
                deduction += raw >= 10 ? 8 : 3
            }
        }

        // SSD endurance from normalized values, first matching wear attribute.
        let lifetimeLeft = ATAMetrics.lifetimeLeft(in: reading)
        if isSSD {
            if let left = lifetimeLeft {
                if left <= 0 {
                    issues.append(.init(
                        id: "ata.wear.exhausted", severity: .warning,
                        title: String(localized: "issue.wear.exhausted.title",
                                      defaultValue: "Đã dùng hết tuổi thọ định mức",
                                      bundle: .module),
                        detail: String(localized: "issue.ata.wear.exhausted.detail",
                                       defaultValue: "Chỉ số hao mòn của SSD báo đã hết tuổi thọ định mức.",
                                       bundle: .module)))
                    deduction += 20
                } else if left <= 10 {
                    issues.append(.init(
                        id: "ata.wear.high", severity: .advisory,
                        title: String(localized: "issue.wear.high.title",
                                      defaultValue: "Tuổi thọ sắp cạn",
                                      bundle: .module),
                        detail: String(localized: "issue.ata.wear.high.detail",
                                       defaultValue: "Còn khoảng \(left)% tuổi thọ định mức.",
                                       bundle: .module)))
                    deduction += 10
                } else if left <= 20 {
                    deduction += 5
                }
            }
        }

        // Temperature from 194 (or 190 airflow) primary value.
        let temperature = ATAMetrics.temperature(in: reading)
        if let temp = temperature {
            let (warnAt, criticalAt): (Int, Int) = isSSD ? (70, 80) : (55, 65)
            if temp >= criticalAt {
                issues.append(.init(
                    id: "ata.temperature.critical", severity: .critical,
                    title: String(localized: "issue.temp.critical.title",
                                  defaultValue: "Nhiệt độ chạm mức nguy hiểm",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.temp.detail",
                                   defaultValue: "Nhiệt độ ổ đĩa là \(Int(clamping: temp))°C.",
                                   bundle: .module)))
                deduction += 15
            } else if temp >= warnAt {
                issues.append(.init(
                    id: "ata.temperature.high", severity: .warning,
                    title: String(localized: "issue.temp.high.title",
                                  defaultValue: "Nhiệt độ vượt ngưỡng cảnh báo",
                                  bundle: .module),
                    detail: String(localized: "issue.ata.temp.detail",
                                   defaultValue: "Nhiệt độ ổ đĩa là \(Int(clamping: temp))°C.",
                                   bundle: .module)))
                deduction += 8
            }
        }

        if let warning = reading.driveWarning {
            issues.append(.init(
                id: "ata.drivedb-warning", severity: .advisory,
                title: String(localized: "issue.ata.drivedb.title",
                              defaultValue: "Model ổ này có vấn đề đã biết",
                              bundle: .module),
                detail: warning))
        }

        let coverage: HealthCoverage
        if reading.attributes.isEmpty && reading.overallFailurePredicted == nil { coverage = .unavailable }
        else if !reading.attributes.isEmpty && reading.identify != nil && reading.overallFailurePredicted != nil
            && reading.driveFamily != nil && reading.attributes.allSatisfy({ $0.rawIsValid && (!$0.currentIsNormalized || ($0.hasComparableCurrent && $0.threshold != nil)) })
            && (lifetimeLeft != nil || reading.attributes.contains { ATAMetrics.meaning(of: $0, in: reading) != nil }) {
            coverage = .complete
        } else { coverage = .partial }
        return report(deduction: deduction, ratingCap: ratingCap, issues: issues,
                      lifetimeLeft: lifetimeLeft, capturedAt: reading.capturedAt, coverage: coverage)
    }

    // MARK: - Shared

    private static func report(deduction: Int, ratingCap: HealthRating,
                               issues: [HealthIssue], lifetimeLeft: Int?,
                               capturedAt: Date, coverage: HealthCoverage) -> HealthReport {
        let score = max(0, 100 - deduction)
        let band: HealthRating
        switch score {
        case 90...: band = .good
        case 70...: band = .ok
        case 50...: band = .warning
        case 25...: band = .failing
        default: band = .failed
        }
        var rating = HealthRating.worst(band, ratingCap)
        // A drive with warning-level findings should never be rated GOOD.
        if issues.contains(where: { $0.severity >= .warning }) {
            rating = HealthRating.worst(rating, .warning)
        }
        if coverage != .complete {
            // Known problems remain actionable even without a numerical certification.
            rating = ratingCap >= .warning ? ratingCap : .unknown
            if issues.contains(where: { $0.severity >= .warning }) { rating = HealthRating.worst(rating, .warning) }
        }
        return HealthReport(
            score: coverage == .complete ? score : nil,
            rating: rating, coverage: coverage,
            lifetimeLeftPercent: lifetimeLeft,
            issues: issues.sorted { $0.severity > $1.severity },
            capturedAt: capturedAt
        )
    }
}
