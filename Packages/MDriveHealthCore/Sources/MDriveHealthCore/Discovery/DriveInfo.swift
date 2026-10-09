/*
 * DriveInfo.swift — model describing a physical storage device.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

/// Which SMART transport the drive supports on macOS.
public enum SMARTInterfaceKind: String, Sendable, Codable {
    /// NVMe SMART via the private NVMeSMARTLib IOKit plug-in (internal NVMe,
    /// Apple Fabric, Thunderbolt NVMe enclosures with native passthrough).
    case nvme
    /// ATA SMART via the public ATASMARTLib IOKit plug-in (SATA drives).
    case ata
    /// No SMART path from userspace (typically USB mass-storage bridges).
    case unsupported
}

/// A physical storage device discovered in the IOKit registry.
public struct DriveInfo: Identifiable, Sendable, Codable, Hashable {
    /// IOKit registry entry ID for this attachment/session, used to reopen the SMART service.
    /// Use DriveIdentity for persisted history and notification routing.
    public let registryEntryID: UInt64
    /// Whole-disk BSD name, e.g. "disk0".
    public let bsdName: String
    public let model: String
    public let serialNumber: String?
    /// IOMedia UUID when macOS exposes one; useful as a fallback identity.
    public let mediaUUID: String?
    public let firmwareRevision: String?
    public let sizeBytes: UInt64
    /// IOKit physical interconnect, e.g. "Apple Fabric", "PCI-Express", "SATA",
    /// "USB", "Virtual Interface".
    public let interconnect: String
    /// IOKit interconnect location, e.g. "Internal", "External".
    public let location: String
    public let isSolidState: Bool
    public let smartInterface: SMARTInterfaceKind

    public var id: UInt64 { registryEntryID }
    public var isInternal: Bool { location == "Internal" }
    /// Disk images, simulator volumes and other non-physical media.
    public var isVirtual: Bool { interconnect == "Virtual Interface" }

    public init(registryEntryID: UInt64, bsdName: String, model: String,
                serialNumber: String?, mediaUUID: String? = nil,
                firmwareRevision: String?, sizeBytes: UInt64,
                interconnect: String, location: String, isSolidState: Bool,
                smartInterface: SMARTInterfaceKind) {
        self.registryEntryID = registryEntryID
        self.bsdName = bsdName
        self.model = model
        self.serialNumber = serialNumber
        self.mediaUUID = mediaUUID
        self.firmwareRevision = firmwareRevision
        self.sizeBytes = sizeBytes
        self.interconnect = interconnect
        self.location = location
        self.isSolidState = isSolidState
        self.smartInterface = smartInterface
    }
}
