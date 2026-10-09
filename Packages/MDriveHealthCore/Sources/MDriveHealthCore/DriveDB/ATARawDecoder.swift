/*
 * ATA raw formats and byte selection follow smartmontools atacmds.cpp
 * (https://github.com/smartmontools/smartmontools), GPL-2.0-or-later.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */
import Foundation

public struct ATARawValue: Sendable {
    /// Primary quantity; time formats use hours, split formats use the left counter.
    public let value: UInt64
    /// Entire assembled counter, before interpreting units or split fields.
    public let counter: UInt64
    public let display: String
    public let isValid: Bool
    public let currentIsNormalized: Bool
    public let worstIsNormalized: Bool
    public let temperatureCelsius: Int?
}

public enum ATARawDecoder {
    public static func decode(raw: [UInt8], format: String, byteorder: String? = nil,
                              current: UInt8? = nil, worst: UInt8? = nil,
                              reserved: UInt8? = nil) -> ATARawValue {
        let format = canonicalFormat(format)
        let order = byteorder ?? defaultByteorder(format)
        let currentValid = !order.contains("v")
        let worstValid = currentValid && !order.contains("w")
        func result(_ value: UInt64, _ counter: UInt64, _ display: String,
                    valid: Bool = true, temperature: Int? = nil) -> ATARawValue {
            .init(value: value, counter: counter, display: display, isValid: valid,
                  currentIsNormalized: currentValid, worstIsNormalized: worstValid,
                  temperatureCelsius: temperature)
        }
        guard raw.count == 6, (1...8).contains(order.count),
              order.allSatisfy({ "012345rvwz".contains($0) }),
              !order.contains("v") || current != nil, !order.contains("w") || worst != nil,
              !order.contains("r") || reserved != nil else {
            return result(0, 0, "?", valid: false)
        }
        var counter: UInt64 = 0
        for character in order {
            let byte: UInt8
            switch character {
            case "r": byte = reserved!
            case "v": byte = current!
            case "w": byte = worst!
            case "z": byte = 0
            default: byte = raw[Int(String(character))!]
            }
            counter = (counter << 8) | UInt64(byte)
        }
        let bytes = (0..<6).map { UInt8(truncatingIfNeeded: counter >> (8 * $0)) }
        let words = (0..<3).map { (counter >> (16 * $0)) & 0xffff }
        let low24 = counter & 0xffffff, low32 = counter & 0xffffffff
        let two: (UInt64) -> String = { String(format: "%02llu", $0) }
        switch format {
        case "raw48", "raw56", "raw64":
            return result(counter, counter, String(counter))
        case "hex48", "hex56", "hex64":
            let width = format == "hex48" ? 12 : (format == "hex56" ? 14 : 16)
            return result(counter, counter, String(format: "0x%0*llx", width, counter))
        case "raw8":
            return result(counter, counter, bytes.reversed().map(String.init).joined(separator: " "))
        case "raw16":
            return result(words[0], counter, words.reversed().map(String.init).joined(separator: " "))
        case "raw16(raw16)":
            let companion = words[1] == 0 && words[2] == 0 ? "" : " (\(words[2]) \(words[1]))"
            return result(words[0], counter, "\(words[0])" + companion)
        case "raw16(avg16)":
            return result(words[0], counter, "\(words[0])" + (words[1] == 0 ? "" : " (Average \(words[1]))"))
        case "raw24(raw8)":
            let companion = bytes[3...5].allSatisfy { $0 == 0 } ? "" : " (\(bytes[5]) \(bytes[4]) \(bytes[3]))"
            return result(low24, counter, "\(low24)" + companion)
        case "raw24/raw24":
            return result(counter >> 24, counter, "\(counter >> 24)/\(low24)")
        case "raw24/raw32":
            return result(counter >> 32, counter, "\(counter >> 32)/\(low32)")
        case "seconds":
            return result(counter / 3600, counter, "\(counter / 3600)h+\(two(counter % 3600 / 60))m+\(two(counter % 60))s")
        case "minutes":
            return result(low32 / 60, counter, "\(low32 / 60)h+\(two(low32 % 60))m" + (words[2] == 0 ? "" : " (\(words[2]))"))
        case "halfminutes":
            return result(counter / 120, counter, "\(counter / 120)h+\(two(counter % 120 / 2))m")
        case "msec24hour32":
            let ms = counter >> 32
            return result(low32, counter, "\(low32)h+\(two(ms / 60000))m+\(two(ms / 1000 % 60)).\(String(format: "%03llu", ms % 1000))s")
        case "temp10x":
            let temperature = Int(words[0] / 10)
            return result(words[0] / 10, counter, String(format: "%.1f", Double(words[0]) / 10), valid: (0...120).contains(temperature), temperature: (0...120).contains(temperature) ? temperature : nil)
        case "tempminmax":
            let t = Int(Int8(bitPattern: bytes[0]))
            func wordKind(_ value: UInt64) -> Int {
                if value <= 0x7f { return 0x11 }
                if value <= 0xff { return 0x01 }
                if value >= 0xff80 { return 0x10 }
                return 0
            }
            func range(_ a: UInt8, _ b: UInt8) -> (Int, Int)? {
                let lo = min(Int(Int8(bitPattern: a)), Int(Int8(bitPattern: b)))
                let hi = max(Int(Int8(bitPattern: a)), Int(Int8(bitPattern: b)))
                return -60 <= lo && lo <= t && t <= hi && hi <= 120 && !(lo == -1 && hi <= 0) ? (lo, hi) : nil
            }
            let kind = wordKind(words[0])
            var limits: (Int, Int)?
            var overTemperatureCount: UInt64?
            var valid = false
            if words[2] == 0 {
                if words[1] == 0 && kind != 0 { valid = true }
                else if kind != 0, let pair = range(bytes[2], bytes[3]) { limits = pair; valid = true }
                else if bytes[3] == 0, let pair = range(bytes[1], bytes[2]) { limits = pair; valid = true }
            } else if kind != 0 {
                if kind & wordKind(words[1]) & wordKind(words[2]) != 0,
                   let pair = range(bytes[2], bytes[4]) { limits = pair; valid = true }
                else if words[2] < 0x7fff, let pair = range(bytes[2], bytes[3]), pair.1 >= 40 {
                    limits = pair; overTemperatureCount = words[2]; valid = true
                }
            }
            let display: String
            if let limits {
                display = "\(t) (Min/Max \(limits.0)/\(limits.1)" + (overTemperatureCount.map { " #\($0)" } ?? "") + ")"
            } else if valid { display = String(t) }
            else { display = "\(bytes[0]) (\(bytes[5]) \(bytes[4]) \(bytes[3]) \(bytes[2]) \(bytes[1]))" }
            return result(UInt64(max(0, t)), counter, display, valid: valid, temperature: valid && (-60...120).contains(t) ? t : nil)
        default:
            // Preserve bytes for inspection, but never assign units/health meaning.
            return result(counter, counter, String(counter), valid: false)
        }
    }

    static func canonicalFormat(_ format: String) -> String {
        switch format {
        case "loadunload": return "raw24/raw24"
        case "sec2hour": return "seconds"
        case "min2hour": return "minutes"
        case "halfmin2hour": return "halfminutes"
        case "10xCelsius": return "temp10x"
        case "unknown", "emergencyretractcyclect", "offlinescanuncsectorct", "writeerrorcount", "detectedtacount", "increasing": return "raw48"
        default: return format
        }
    }
    static func defaultByteorder(_ format: String) -> String {
        switch canonicalFormat(format) {
        case "raw64", "hex64": return "543210wv"
        case "raw56", "hex56", "raw24/raw32", "msec24hour32": return "r543210"
        default: return "543210"
        }
    }
}
