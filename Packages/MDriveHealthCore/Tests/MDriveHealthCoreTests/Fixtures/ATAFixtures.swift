/*
 * ATAFixtures.swift — synthetic ATA SMART structures for tests.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
@testable import MDriveHealthCore

enum ATAFixtures {
    struct AttributeSeed {
        let id: UInt8
        let flags: UInt16
        let current: UInt8
        let worst: UInt8
        let raw: UInt64
        let threshold: UInt8

        init(_ id: UInt8, flags: UInt16 = 0x0003, current: UInt8, worst: UInt8,
             raw: UInt64, threshold: UInt8) {
            self.id = id
            self.flags = flags
            self.current = current
            self.worst = worst
            self.raw = raw
            self.threshold = threshold
        }
    }

    /// Builds a 512-byte SMART READ DATA page + matching thresholds page.
    static func smartPages(_ seeds: [AttributeSeed],
                           selfTestByte: UInt8 = 0x00) -> (data: [UInt8], thresholds: [UInt8]) {
        var data = [UInt8](repeating: 0, count: 512)
        var thresholds = [UInt8](repeating: 0, count: 512)
        thresholds[0] = 0x10
        data[0] = 0x10 // structure revision
        data[363] = selfTestByte
        for (slot, seed) in seeds.prefix(30).enumerated() {
            let offset = 2 + slot * 12
            data[offset] = seed.id
            data[offset + 1] = UInt8(seed.flags & 0xFF)
            data[offset + 2] = UInt8(seed.flags >> 8)
            data[offset + 3] = seed.current
            data[offset + 4] = seed.worst
            for i in 0..<6 {
                data[offset + 5 + i] = UInt8((seed.raw >> (8 * UInt64(i))) & 0xFF)
            }
            thresholds[offset] = seed.id
            thresholds[offset + 1] = seed.threshold
        }
        return (checksummed(data), checksummed(thresholds))
    }

    static func checksummed(_ input: [UInt8]) -> [UInt8] {
        var data = input
        data[511] = 0
        data[511] = 0 &- data.reduce(UInt8(0), &+)
        return data
    }

    /// A healthy Samsung 850 EVO-like SATA SSD.
    static let healthySSD: [AttributeSeed] = [
        .init(5, flags: 0x0033, current: 100, worst: 100, raw: 0, threshold: 10),
        .init(9, flags: 0x0032, current: 97, worst: 97, raw: 12_345, threshold: 0),
        .init(12, flags: 0x0032, current: 99, worst: 99, raw: 456, threshold: 0),
        .init(177, flags: 0x0013, current: 95, worst: 95, raw: 42, threshold: 0),
        .init(187, flags: 0x0032, current: 100, worst: 100, raw: 0, threshold: 0),
        .init(190, flags: 0x0032, current: 66, worst: 45, raw: 34, threshold: 0),
        .init(199, flags: 0x003E, current: 100, worst: 100, raw: 0, threshold: 0),
        .init(241, flags: 0x0032, current: 99, worst: 99, raw: 21_000_000_000, threshold: 0),
    ]

    /// A dying 2.5" HDD: reallocated + pending sectors, one attribute tripped.
    static let dyingHDD: [AttributeSeed] = [
        .init(1, flags: 0x000F, current: 90, worst: 60, raw: 0, threshold: 6),
        .init(5, flags: 0x0033, current: 3, worst: 3, raw: 1_824, threshold: 36),
        .init(9, flags: 0x0032, current: 60, worst: 60, raw: 34_567, threshold: 0),
        .init(187, flags: 0x0032, current: 1, worst: 1, raw: 522, threshold: 0),
        .init(194, flags: 0x0022, current: 55, worst: 40,
              raw: 0x2D_00_15_00_2D, threshold: 0), // 45 current, min 21, max 45
        .init(197, flags: 0x0012, current: 80, worst: 80, raw: 216, threshold: 0),
        .init(198, flags: 0x0010, current: 92, worst: 92, raw: 88, threshold: 0),
        .init(199, flags: 0x003E, current: 200, worst: 200, raw: 3, threshold: 0),
    ]

    /// Builds a 512-byte IDENTIFY DEVICE block with the given strings.
    static func identify(model: String, serial: String, firmware: String,
                         rotationRate: UInt16) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 512)
        func putString(_ string: String, firstWord: Int, wordCount: Int) {
            let padded = string.padding(toLength: wordCount * 2, withPad: " ", startingAt: 0)
            let bytes = Array(padded.utf8)
            for wordIndex in 0..<wordCount {
                // first char goes into the high byte of the word
                data[(firstWord + wordIndex) * 2 + 1] = bytes[wordIndex * 2]
                data[(firstWord + wordIndex) * 2] = bytes[wordIndex * 2 + 1]
            }
        }
        putString(serial, firstWord: 10, wordCount: 10)
        putString(firmware, firstWord: 23, wordCount: 4)
        putString(model, firstWord: 27, wordCount: 20)
        data[217 * 2] = UInt8(rotationRate & 0xFF)
        data[217 * 2 + 1] = UInt8(rotationRate >> 8)
        return data
    }
}
