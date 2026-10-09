import XCTest
import Darwin
@testable import MDriveHealthCore

final class MemoryReaderTests: XCTestCase {
    func testRepeatedSuccessfulReadsReleaseHostSendRight() throws {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        func references() throws -> mach_port_urefs_t {
            var count: mach_port_urefs_t = 0
            XCTAssertEqual(mach_port_get_refs(mach_task_self_, host,
                mach_port_right_t(MACH_PORT_RIGHT_SEND), &count), KERN_SUCCESS)
            return count
        }
        let before = try references()
        for _ in 0..<100 {
            let stats = try XCTUnwrap(MemoryReader.read())
            XCTAssertGreaterThan(stats.totalBytes, 0)
        }
        XCTAssertEqual(try references(), before)
    }
}
