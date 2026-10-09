import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import MDriveHealthCore

@MainActor
final class StatusPaletteTests: XCTestCase {
    private let appearances: [(NSAppearance.Name, Bool)] = [
        (.aqua, false), (.darkAqua, true), (.accessibilityHighContrastAqua, false), (.accessibilityHighContrastDarkAqua, true)
    ]

    private func rgb(_ color: Color, in name: NSAppearance.Name) throws -> [Double] {
        var resolved: NSColor?
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        appearance.performAsCurrentDrawingAppearance { resolved = NSColor(color).usingColorSpace(.sRGB) }
        let value = try XCTUnwrap(resolved)
        XCTAssertEqual(value.alphaComponent, 1, accuracy: 0.00001)
        return [Double(value.redComponent), Double(value.greenComponent), Double(value.blueComponent)]
    }
    private func contrast(_ a: [Double], _ b: [Double]) -> Double {
        func luminance(_ values: [Double]) -> Double {
            zip([0.2126, 0.7152, 0.0722], values).reduce(0) { result, pair in
                let linear = pair.1 <= 0.04045 ? pair.1 / 12.92 : pow((pair.1 + 0.055) / 1.055, 2.4)
                return result + pair.0 * linear
            }
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    private func verifyText(_ colors: [Color], tinted: Bool = false) throws {
        for (name, dark) in appearances {
            let backgrounds = dark ? [[0.12, 0.12, 0.12], [0.27, 0.27, 0.27]] : [[1.0, 1.0, 1.0], [0.93, 0.93, 0.93]]
            for color in colors {
                let foreground = try rgb(color, in: name)
                for surface in backgrounds {
                    let opacity = tinted ? StatusPalette.captionBackgroundOpacity : 0
                    let background = zip(surface, foreground).map { $0 * (1 - opacity) + $1 * opacity }
                    XCTAssertGreaterThanOrEqual(contrast(foreground, background), 4.5, "\(name): \(foreground) on \(background)")
                }
            }
        }
    }

    func testHealthCaptionColorsRemainReadableInAllAppearances() throws {
        try verifyText(HealthRating.allCases.map(\.color))
    }

    func testFilledStatusLabelsStayOpaqueAndReadableInEitherTheme() throws {
        for palette in StatusPalette.allCases {
            var previous: [Double]?
            for (name, _) in appearances {
                let fill = try rgb(palette.fill, in: name)
                XCTAssertGreaterThanOrEqual(contrast(fill, [1, 1, 1]), 4.5)
                if let previous { XCTAssertEqual(fill, previous) }
                previous = fill
            }
        }
    }

    func testIssueRiskAndCapacityCaptionsUseReadableStatusRoles() throws {
        let issues: [IssueSeverity] = [.info, .advisory, .warning, .critical]
        let risks: [DriveRiskLevel] = [.healthy, .watch, .backupSoon, .backupNow]
        let verdicts: [CapacityVerifyResult.Verdict] = [.passedTestedRange, .dataCorrupted, .inconclusive]
        try verifyText(issues.map(\.color) + risks.map(\.color) + verdicts.map { $0.statusPalette.foreground })
        try verifyText(issues.map(\.color), tinted: true)
    }

    func testProductionPNGRendererUsesLightContentDuringDarkDrawing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MDriveHealth-status-palette-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var url: URL?
        try XCTUnwrap(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            url = ShareCardRenderer.pngURL(for: ExportPaletteProbe(), name: "appearance", directory: directory)
        }
        let data = try Data(contentsOf: XCTUnwrap(url))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertTrue(try XCTUnwrap(properties[kCGImagePropertyProfileName] as? String).hasPrefix("sRGB"))
        // colorAt returns device-RGB components even for this tagged sRGB
        // bitmap. Converting that NSColor again applies another transform.
        let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        let expected = try rgb(HealthRating.failed.color, in: .aqua)
        for (actual, wanted) in zip([pixel.redComponent, pixel.greenComponent, pixel.blueComponent], expected) {
            XCTAssertEqual(Double(actual), wanted, accuracy: 0.01)
        }
    }
}

private struct ExportPaletteProbe: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(scheme == .light ? HealthRating.failed.color : Color.purple).frame(width: 24, height: 24)
    }
}
