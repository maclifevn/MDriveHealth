/* Shared result validation for IPC, journal and history. GPL-3.0-or-later. */
import Foundation

enum MeasurementResultValidation {
    static func benchmark(_ result: BenchmarkResult, volume: VolumeUsage, config: BenchmarkConfig) throws {
        guard result.capturedAt.timeIntervalSince1970.isFinite,
                  result.volumeBSDName == volume.bsdName, result.volumeName == volume.name, result.mountPoint == volume.mountPoint,
                  result.fileSizeBytes == config.fileSizeBytes, result.sequentialBlockBytes == config.sequentialBlockBytes,
                  result.randomBlockBytes == config.randomBlockBytes, result.queueDepth == config.queueDepth,
                  (result.randomWriteBytesPerSec != nil) == config.includeRandomPhases,
                  (result.randomReadBytesPerSec != nil) == config.includeRandomPhases else { throw MeasurementWorkerError.protocolViolation }
        let rates: [Double] = [result.sequentialWriteBytesPerSec, result.sequentialReadBytesPerSec,
                               result.randomWriteBytesPerSec ?? 0, result.randomReadBytesPerSec ?? 0]
        for rate in rates { try validRate(rate) }
    }
    static func capacity(_ result: CapacityVerifyResult, volume: VolumeUsage, config: CapacityVerifyConfig) throws {
        guard result.capturedAt.timeIntervalSince1970.isFinite, result.volumeName == volume.name, result.mountPoint == volume.mountPoint,
                  result.bytesRequested > 0, result.bytesRequested % UInt64(config.blockBytes) == 0,
                  result.bytesWritten <= result.bytesRequested, result.bytesVerifiedOK <= result.bytesWritten,
                  config.maxBytes.map({ result.bytesRequested <= $0 }) ?? true,
                  result.bytesRequested / config.fileSizeBytes + (result.bytesRequested % config.fileSizeBytes == 0 ? 0 : 1) <= UInt64(DiskWorkspaceRecovery.maximumFiles),
                  result.corruptedBlocks >= 0, UInt64(result.corruptedBlocks) <= result.bytesWritten / UInt64(config.blockBytes) + 1,
                  result.firstCorruptionOffset.map({ $0 < result.bytesWritten }) ?? (result.corruptedBlocks == 0) else { throw MeasurementWorkerError.protocolViolation }
        try validRate(result.writeBytesPerSec); try validRate(result.readBytesPerSec)
        switch result.verdict {
        case .passedTestedRange: guard result.bytesRequested == result.bytesWritten, result.bytesWritten == result.bytesVerifiedOK, result.corruptedBlocks == 0, result.firstCorruptionOffset == nil, result.interruption == nil else { throw MeasurementWorkerError.protocolViolation }
        case .dataCorrupted: guard result.corruptedBlocks > 0, result.firstCorruptionOffset != nil else { throw MeasurementWorkerError.protocolViolation }
        case .inconclusive: guard result.corruptedBlocks == 0, result.firstCorruptionOffset == nil, result.interruption != nil || result.bytesWritten != result.bytesRequested || result.bytesVerifiedOK != result.bytesRequested else { throw MeasurementWorkerError.protocolViolation }
        }
    }
    private static func validRate(_ value: Double) throws { guard value.isFinite, value >= 0 else { throw MeasurementWorkerError.protocolViolation } }
}
