/*
 * SMARTError.swift — errors surfaced by SMART providers.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public enum SMARTError: Error, LocalizedError {
    /// The IOKit registry entry could no longer be found (drive detached?).
    case serviceNotFound
    /// An IOKit call failed.
    case ioKit(kern_return_t, String)
    /// The drive does not support the requested SMART transport.
    case invalidPayload(String)
    case unsupportedTransport

    public var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return "Drive not found in IOKit registry (was it disconnected?)"
        case .ioKit(let code, let what):
            return String(format: "%@ failed (IOReturn 0x%08x)", what, code)
        case .invalidPayload(let reason):
            return "Invalid SMART payload: \(reason)"
        case .unsupportedTransport:
            return "SMART is not accessible for this drive on macOS"
        }
    }
}
