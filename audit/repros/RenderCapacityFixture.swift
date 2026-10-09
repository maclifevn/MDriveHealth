// Synthetic evidence for F09. No hardware probes or disk benchmarks.
import AppKit
import SwiftUI
@testable import MDriveHealthCore

@main
struct RenderCapacityFixture {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let result = CapacityVerifyResult(
            capturedAt: Date(timeIntervalSince1970: 1_791_446_400),
            volumeName: "AUDIT FIXTURE", mountPoint: "/audit-fixture",
            bytesRequested: 16384, bytesWritten: 8192, bytesVerifiedOK: 0,
            firstCorruptionOffset: nil, corruptedBlocks: 0,
            writeBytesPerSec: 0, readBytesPerSec: 0, verdict: .inconclusive, interruption: .readFailed)
        let drive = DriveInfo(
            registryEntryID: 0, bsdName: "audit", model: "AUDIT INPUT: INCONCLUSIVE",
            serialNumber: nil, firmwareRevision: nil, sizeBytes: 1 << 40,
            interconnect: "Fixture", location: "External", isSolidState: true,
            smartInterface: .unsupported)
        guard let image = ShareCardRenderer.pngURL(
            for: CapacityShareCard(drive: drive, result: result), name: "audit-inconclusive") else {
            throw NSError(domain: "ProductionAudit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "SwiftUI did not render the fixture"])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.copyItem(at: image, to: output)
        try FileManager.default.removeItem(at: image)
        print("Input: verdict=inconclusive, bytesVerifiedOK=0. Image: \(output.path)")
    }
}
