/* Stable group identities and real resource localization. GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

final class SensorsReaderTests: XCTestCase {
    func testGroupsPreserveOrderAndAverageWithoutLocalizedKeys() {
        let readings = [TemperatureSensor(name: "Unknown", celsius: 33),
                        .init(name: "Gas Gauge", celsius: 30), .init(name: "Power", celsius: 40),
                        .init(name: "NAND", celsius: 50), .init(name: "GPU", celsius: 60),
                        .init(name: "PMU tdie", celsius: 70), .init(name: "CPU", celsius: 50)]
        let groups = SensorsReader.summarize(readings)
        XCTAssertEqual(groups.map(\.group), [.processor, .graphics, .storage, .battery, .power, .other])
        XCTAssertEqual(groups.map(\.celsius), [60, 60, 50, 30, 40, 33])
        XCTAssertEqual(SensorsReader.summarize(readings.reversed()).map(\.group), groups.map(\.group))
    }

    func testInvalidTemperaturesCannotPolluteSummary() {
        let values = [Double.nan, .infinity, -.infinity, 0, -1, 130, 999]
        let readings = values.map { TemperatureSensor(name: "CPU", celsius: $0) } + [.init(name: "GPU", celsius: 45)]
        let groups = SensorsReader.summarize(readings)
        XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups.first?.group, .graphics)
        XCTAssertEqual(groups.first?.celsius, 45)
        XCTAssertTrue(SensorsReader.summarize([]).isEmpty)
    }

    func testCaptionsUseEnglishAndVietnameseResources() {
        let en = Locale(identifier: "en"), vi = Locale(identifier: "vi")
        XCTAssertEqual(TemperatureSensorGroup.allCases.map { $0.displayName(locale: en) }, ["CPU/SOC", "GPU", "SSD (NAND)", "Battery", "Power", "Other"])
        XCTAssertEqual(TemperatureSensorGroup.allCases.map { $0.displayName(locale: vi) }, ["CPU/SOC", "GPU", "SSD (NAND)", "Pin", "Nguồn", "Khác"])
    }
}
