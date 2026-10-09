/* Menu bar freshness and scoped health presentation. GPL-3.0-or-later. */
import SwiftUI
import MDriveHealthCore

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case icon, temp, score
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .icon: return "Không có gì"
        case .temp: return "menubar.display.temp"
        case .score: return "menubar.display.score"
        }
    }
    var accessibilityName: String {
        switch self {
        case .icon: return ""
        case .temp: return String(localized: "menubar.display.temp")
        case .score: return String(localized: "menubar.display.score")
        }
    }
}

struct MenuBarStatus {
    enum ReadingState: Equatable {
        case current, reading, previous, sleeping, failed, unsupported, unread
    }
    let snapshots: [DriveSnapshot]
    let isRefreshing: Bool
    let discoveryFailed: Bool
    let measurementInProgress: Bool
    let isShuttingDown: Bool

    init(snapshots: [DriveSnapshot], isRefreshing: Bool = false, refreshError: String? = nil,
         measurementInProgress: Bool = false, isShuttingDown: Bool = false) {
        self.snapshots = snapshots; self.isRefreshing = isRefreshing
        discoveryFailed = refreshError != nil
        self.measurementInProgress = measurementInProgress; self.isShuttingDown = isShuttingDown
    }

    static func readingState(_ snapshot: DriveSnapshot, readsPaused: Bool = false) -> ReadingState {
        if snapshot.isProbing { return .reading }
        if snapshot.lastError != nil || snapshot.probeStalled {
            return snapshot.reading == nil ? .failed : .previous
        }
        if snapshot.isStale { return .previous }
        if snapshot.skippedWhileSleeping { return .sleeping }
        if snapshot.reading != nil { return readsPaused ? .previous : .current }
        return snapshot.drive.smartInterface == .unsupported ? .unsupported : .unread
    }

    var currentSnapshots: [DriveSnapshot] {
        guard !discoveryFailed, !measurementInProgress, !isShuttingDown else { return [] }
        return snapshots.filter { Self.readingState($0) == .current }
    }
    var currentWorstRating: HealthRating? { currentSnapshots.compactMap { $0.health?.rating }.max() }
    var isUnverified: Bool {
        discoveryFailed || isRefreshing || measurementInProgress || isShuttingDown || snapshots.contains {
            let state = Self.readingState($0)
            if state == .unsupported { return false }
            return state != .current || $0.health?.score == nil || $0.health?.coverage != .complete
        }
    }
    var refreshEnabled: Bool { !isRefreshing && !measurementInProgress && !isShuttingDown }
    var accessibilityStatus: String {
        let unverified = String(localized: "menubar.unverified", defaultValue: "Chưa xác minh")
        if let rating = currentWorstRating, rating >= .warning {
            return rating.displayName + (isUnverified ? " · " + unverified : "")
        }
        if isUnverified { return unverified }
        return currentWorstRating?.displayName ?? HealthRating.unknown.displayName
    }

    /// A retained cache is useful in the popover, but must not masquerade as a
    /// fresh compact temperature/score or conceal an unresolved SMART probe.
    func value(for display: MenuBarDisplay) -> String? {
        guard !isUnverified else { return nil }
        switch display {
        case .icon: return nil
        case .temp: return currentSnapshots.compactMap { $0.reading?.temperatureCelsius }.max().map { "\($0)°" }
        case .score: return currentSnapshots.compactMap { $0.health?.score }.min().map(String.init)
        }
    }

    var symbol: String {
        if let rating = currentWorstRating, rating >= .failing { return "externaldrive.fill.badge.xmark" }
        if isUnverified { return "exclamationmark.triangle" }
        switch currentWorstRating {
        case .some(.failing), .some(.failed): return "externaldrive.fill.badge.xmark"
        case .some(.warning): return "externaldrive.fill.badge.exclamationmark"
        default: return "internaldrive"
        }
    }
}

extension DriveStore {
    var menuBarStatus: MenuBarStatus {
        MenuBarStatus(snapshots: visibleSnapshots, isRefreshing: isRefreshing, refreshError: refreshError,
                      measurementInProgress: benchmarkInProgress, isShuttingDown: operations.isShuttingDown)
    }
}
