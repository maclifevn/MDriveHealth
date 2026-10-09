/* Sidebar selection survives discovery without overriding user choices. GPL-3.0-or-later. */
enum SidebarItem: Hashable {
    case allDrives, drive(UInt64), battery, sensors, memory
}

struct SidebarSelection {
    private(set) var item: SidebarItem?
    private(set) var isExplicit = false

    mutating func choose(_ item: SidebarItem?) {
        self.item = item
        isExplicit = item != nil
    }

    /// Only a settled fleet can invalidate a drive or choose a default.
    /// Empty startup state and intermediate refresh publications are not proof
    /// that a drive has disappeared. A failed scan retains the store's fleet.
    mutating func reconcile(driveIDs: Set<UInt64>, batteryAvailable: Bool, discoverySettled: Bool) {
        guard discoverySettled else { return }
        switch item {
        case .drive(let id) where !driveIDs.contains(id):
            item = nil; isExplicit = false
        case .battery where !batteryAvailable:
            item = nil; isExplicit = false
        default: break
        }
        if !isExplicit { item = driveIDs.isEmpty ? .memory : .allDrives }
    }

    enum RequestResolution: Equatable { case waiting, selected, unavailable }
    mutating func requestDrive(_ id: UInt64, driveIDs: Set<UInt64>, discoverySettled: Bool) -> RequestResolution {
        guard discoverySettled else { return .waiting }
        guard driveIDs.contains(id) else { return .unavailable }
        choose(.drive(id)); return .selected
    }
}
