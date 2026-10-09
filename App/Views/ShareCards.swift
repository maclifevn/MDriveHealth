/*
 * ShareCards.swift — social-friendly PNG cards for benchmark / capacity
 * results. Facebook groups are image-first: a branded card travels much
 * further than pasted text.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

private struct ShareImageDirectoryKey: EnvironmentKey {
    static let defaultValue = FileManager.default.temporaryDirectory
}
extension EnvironmentValues {
    var shareImageDirectory: URL {
        get { self[ShareImageDirectoryKey.self] }
        set { self[ShareImageDirectoryKey.self] = newValue }
    }
}

/// Renders a card view into a temp PNG the system share sheet can take.
@MainActor
enum ShareCardRenderer {
    static func pngURL(for view: some View, name: String, directory: URL = FileManager.default.temporaryDirectory) -> URL? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        let scale: CGFloat = 2
        var image: CGImage?
        // Draw into a CPU bitmap; the default snapshot path can abort in
        // Metal when a virtual Intel GPU has no supported device architecture.
        renderer.render(rasterizationScale: scale) { size, draw in
            guard let width = Int(exactly: (size.width * scale).rounded(.up)),
                  let height = Int(exactly: (size.height * scale).rounded(.up)),
                  width > 0, height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let bitmap = CGContext(data: nil, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            bitmap.scaleBy(x: scale, y: scale)
            draw(bitmap)
            image = bitmap.makeImage()
        }
        guard let cgImage = image else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        // Unique per render — a fixed name would silently overwrite another
        // drive's card between generating and sharing.
        let url = directory
            .appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// Fixed-appearance (always light) card — the PNG must look right no matter
/// the poster's theme.
struct BenchmarkShareCard: View {
    let drive: DriveInfo
    let health: HealthReport?
    let result: BenchmarkResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("MDriveHealth", systemImage: "internaldrive.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(result.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(StatusPalette.information.fill)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(drive.model)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.black)
                        Text(verbatim: "\(Format.bytes(drive.sizeBytes)) · \(drive.isSolidState ? "SSD" : "HDD") · \(drive.interconnect) · \(result.volumeName)")
                            .font(.callout)
                            .foregroundStyle(StatusPalette.neutral.foreground)
                    }
                    Spacer()
                    if let health {
                        Text(health.rating.displayName)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(health.rating.badgeFill, in: Capsule())
                    }
                }

                HStack(spacing: 12) {
                    shareStat("Ghi tuần tự", result.sequentialWriteBytesPerSec)
                    shareStat("Đọc tuần tự", result.sequentialReadBytesPerSec)
                    if let rw = result.randomWriteBytesPerSec {
                        shareStat("Random 4K Ghi", rw)
                    }
                    if let rr = result.randomReadBytesPerSec {
                        shareStat("Random 4K Đọc", rr)
                    }
                }

                Text(String(localized: "share.footer.qd",
                            defaultValue: "Đo bằng MDriveHealth (QD\(result.queueDepth), \(Format.bytes(result.fileSizeBytes))) — app sức khoẻ ổ đĩa miễn phí cho cộng đồng Maclife 🇻🇳"))
                    .font(.caption)
                    .foregroundStyle(StatusPalette.neutral.foreground)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 640)
        .background(Color.white)
    }

    private func shareStat(_ title: LocalizedStringKey, _ bytesPerSec: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(StatusPalette.neutral.foreground)
            Text(Format.speed(bytesPerSec))
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(white: 0.955), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CapacityShareCard: View {
    let drive: DriveInfo
    let result: CapacityVerifyResult

    private var verdictColor: Color {
        result.verdict.statusPalette.foreground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("MDriveHealth", systemImage: "internaldrive.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(result.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(result.verdict.statusPalette.fill)

            VStack(alignment: .leading, spacing: 12) {
                Text(drive.model)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.black)
                Text(verbatim: "\(Format.bytes(drive.sizeBytes)) · \(result.volumeName)")
                    .font(.callout)
                    .foregroundStyle(StatusPalette.neutral.foreground)

                Label(result.summaryTitle, systemImage: result.symbolName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(verdictColor)

                Text(result.summaryDetail)
                    .font(.callout)
                    .foregroundStyle(.black)

                Text(String(localized: "share.capacity.footer",
                            defaultValue: "Kiểm tra kiểu H2testw bằng MDriveHealth — app sức khoẻ ổ đĩa miễn phí cho cộng đồng Maclife 🇻🇳"))
                    .font(.caption)
                    .foregroundStyle(StatusPalette.neutral.foreground)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 640)
        .background(Color.white)
    }
}
