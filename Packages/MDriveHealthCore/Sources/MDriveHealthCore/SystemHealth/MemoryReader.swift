/*
 * MemoryReader.swift — RAM usage, swap and memory pressure.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import Darwin

public struct MemoryStats: Sendable, Codable, Hashable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    /// 1 = normal, 2 = warning, 4 = critical (kernel memorystatus levels).
    public let pressureLevel: Int

    public var usedBytes: UInt64 {
        activeBytes &+ wiredBytes &+ compressedBytes
    }

    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

public enum MemoryReader {
    public static func read() -> MemoryStats? {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0 else { return nil }

        // mach_host_self acquires a send-right reference on every call.
        // Reuse one reference and release it on every exit, including failures.
        let host = mach_host_self()
        guard host != MACH_PORT_NULL else { return nil }
        defer { mach_port_deallocate(mach_task_self_, host) }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        let page = UInt64(pageSize)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var pressure: Int = 1
        var pressureSize = MemoryLayout<Int>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure,
                         &pressureSize, nil, 0)

        return MemoryStats(
            totalBytes: total,
            freeBytes: UInt64(stats.free_count) &* page,
            activeBytes: UInt64(stats.active_count) &* page,
            inactiveBytes: UInt64(stats.inactive_count) &* page,
            wiredBytes: UInt64(stats.wire_count) &* page,
            compressedBytes: UInt64(stats.compressor_page_count) &* page,
            swapUsedBytes: swap.xsu_used,
            swapTotalBytes: swap.xsu_total,
            pressureLevel: pressure
        )
    }
}
