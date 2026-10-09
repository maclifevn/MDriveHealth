/* Hardware worker bootstrap. MDriveHealth, GPL-3.0-or-later. */
import Darwin
import MDriveHealthCore
exit(CommandLine.arguments.dropFirst().first == "--measurement-worker" ? MeasurementWorker.runStandardIO() : DriveHardwareWorker.runStandardIO())
