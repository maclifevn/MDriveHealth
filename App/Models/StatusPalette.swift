/* Semantic status colors for readable text and filled badges. GPL-3.0-or-later. */
import AppKit
import SwiftUI
import MDriveHealthCore

enum StatusPalette: CaseIterable {
    case neutral, positive, okay, information, caution, danger, failure

    /// A stronger tint reduces the contrast of small captions on card surfaces.
    static let captionBackgroundOpacity = 0.10

    private var lightRGB: UInt32 {
        switch self {
        case .neutral: return 0x55616E
        case .positive: return 0x176C3A
        case .okay: return 0x536911
        case .information: return 0x175EAA
        case .caution: return 0x915100
        case .danger: return 0xB42318
        case .failure: return 0x961020
        }
    }
    private var darkRGB: UInt32 {
        switch self {
        case .neutral: return 0xC6CED8
        case .positive: return 0x8FEBAB
        case .okay: return 0xD3E892
        case .information: return 0xA9CEFF
        case .caution: return 0xFFD18A
        case .danger: return 0xFFB3AA
        case .failure: return 0xFFC0C8
        }
    }
    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    /// Foreground on ordinary light/dark window and card surfaces.
    var foreground: Color {
        let light = Self.color(lightRGB), dark = Self.color(darkRGB)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    /// Opaque fill paired with white text in either appearance.
    var fill: Color { Color(nsColor: Self.color(lightRGB)) }
}

extension HealthRating {
    var statusPalette: StatusPalette {
        switch self {
        case .unknown: return .neutral
        case .good: return .positive
        case .ok: return .okay
        case .warning: return .caution
        case .failing: return .danger
        case .failed: return .failure
        }
    }
    var color: Color { statusPalette.foreground }
    var badgeFill: Color { statusPalette.fill }
}

extension IssueSeverity {
    var color: Color {
        switch self {
        case .info: return StatusPalette.neutral.foreground
        case .advisory: return StatusPalette.information.foreground
        case .warning: return StatusPalette.caution.foreground
        case .critical: return StatusPalette.danger.foreground
        }
    }
}

extension CapacityVerifyResult.Verdict {
    var statusPalette: StatusPalette {
        switch self {
        case .passedTestedRange: return .positive
        case .dataCorrupted: return .danger
        case .inconclusive: return .caution
        }
    }
}
