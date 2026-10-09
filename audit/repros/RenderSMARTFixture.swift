// Synthetic visual evidence for F08. Uses the actual app score gauge and badge.
import AppKit
import SwiftUI
@testable import MDriveHealthCore

@main
struct RenderSMARTFixture {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let empty = ATASMARTReading(capturedAt: Date(), identify: nil, attributes: [],
                                    overallFailurePredicted: nil, selfTest: nil, driveFamily: nil, driveWarning: nil)
        let failing = ATASMARTReading(capturedAt: Date(), identify: nil, attributes: [],
                                      overallFailurePredicted: true, selfTest: nil, driveFamily: nil, driveWarning: nil)
        let reports = [HealthEvaluator.evaluate(ata: empty), HealthEvaluator.evaluate(ata: failing)]
        let card = VStack(alignment: .leading, spacing: 24) {
            Text("SMART DATA QUALITY — SYNTHETIC FIXTURE").font(.headline)
            ForEach(Array(reports.enumerated()), id: \.offset) { index, health in
                HStack(alignment: .top, spacing: 20) {
                    HealthScoreGauge(health: health)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(index == 0 ? "Empty SMART input" : "SMART failure + missing attributes").font(.headline)
                        HealthBadge(rating: health.rating)
                        Text(health.coverageDescription).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.padding(24).frame(width: 720).background(Color.white).foregroundStyle(.black)
        guard let image = ShareCardRenderer.pngURL(for: card, name: "audit-smart") else {
            throw NSError(domain: "ProductionAudit", code: 1)
        }
        try FileManager.default.copyItem(at: image, to: URL(fileURLWithPath: CommandLine.arguments[1]))
        try FileManager.default.removeItem(at: image)
        print("Rendered actual score gauge and badge: unavailable and partial failure, both score=nil")
    }
}
