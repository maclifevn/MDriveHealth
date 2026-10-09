import XCTest
import Darwin
@testable import MDriveHealthCore

final class WorkspaceRecoveryContractTests: XCTestCase {
    private func item(name: String, path: String) -> DiskWorkspaceLeftover {
        .init(name: name, path: path, status: .recoverable, bytes: 0, fileCount: 0, diagnostic: nil, proof: String(repeating: "a", count: 64))
    }
    func testScanIsBoundToRequestedParentPath() throws {
        let name = DiskWorkspaceRecovery.workspaceName(for: UUID())
        let foreign = DiskWorkspaceScan(leftovers: [item(name: name, path: "/foreign/" + name)], complete: true, diagnostic: nil)
        try foreign.validate()
        XCTAssertThrowsError(try foreign.validate(parentPath: "/selected"))
        let scoped = DiskWorkspaceScan(leftovers: [item(name: name, path: "/selected/" + name)], complete: true, diagnostic: nil)
        try scoped.validate(parentPath: "/selected")
    }
    func testRecoverableNameRequiresCanonicalSessionAndNoNUL() {
        for name in ["legacy", DiskWorkspaceRecovery.workspaceName(for: UUID()).lowercased(), "bad\0name"] {
            XCTAssertThrowsError(try DiskWorkspaceScan(leftovers: [item(name: name, path: "/selected/" + name)], complete: true, diagnostic: nil).validate())
        }
    }
    func testAlternateUUIDCasingIsRecognizedForConservativeAbsenceOnly() {
        let id = UUID(), name = DiskWorkspaceRecovery.workspaceName(for: id)
        XCTAssertEqual(DiskWorkspaceRecovery.sessionID(forName: name), id)
        XCTAssertEqual(DiskWorkspaceRecovery.sessionID(forName: name.lowercased()), id)
        XCTAssertNil(DiskWorkspaceRecovery.sessionID(forName: "other-" + id.uuidString))
    }
    func testPartialScanRemainsPartialAndRequiresDiagnostic() throws {
        let partial = DiskWorkspaceScan(leftovers: [], complete: false, diagnostic: "bounded scan exhausted")
        try partial.validate(parentPath: "/selected"); XCTAssertFalse(partial.complete)
        XCTAssertThrowsError(try DiskWorkspaceScan(leftovers: [], complete: false, diagnostic: nil).validate())
    }
    func testDirectoryReplacementCannotAuthorizeAWorkspaceWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parent-proof-\(UUID())")
        let archived = root.appendingPathExtension("old")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: archived) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let original = try XCTUnwrap(WorkspaceDirectoryIdentity.capture(at: root))
        try Data("keep".utf8).write(to: root.appendingPathComponent("sentinel"))
        try FileManager.default.moveItem(at: root, to: archived)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertNotEqual(original, WorkspaceDirectoryIdentity.capture(at: root))
        XCTAssertThrowsError(try DiskTestWorkspace.fixture(at: root, expectedDirectory: original))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: archived.appendingPathComponent("sentinel")), Data("keep".utf8))
    }
    func testScanMustReportTheOpenedParentRatherThanOnlyItsPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-parent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let identity = try XCTUnwrap(WorkspaceDirectoryIdentity.capture(at: root))
        let scan = try DiskWorkspaceRecovery.scanFixture(at: root)
        try scan.validate(parentPath: root.path, expectedParentIdentity: identity)
        XCTAssertEqual(scan.parentIdentity, identity)
        XCTAssertThrowsError(try DiskWorkspaceScan(leftovers: [], complete: true, diagnostic: nil).validate(expectedParentIdentity: identity))
        var info = stat(); XCTAssertEqual(stat(root.path, &info), 0); info.st_ino += 1
        XCTAssertThrowsError(try scan.validate(expectedParentIdentity: WorkspaceDirectoryIdentity(info)))
    }
    func testPersistentVolumeRemountStillRequiresInodeOwnerAndBirthTime() throws {
        var original = stat()
        XCTAssertEqual(stat(FileManager.default.temporaryDirectory.path, &original), 0)
        let identity = WorkspaceDirectoryIdentity(original)
        var remounted = original; remounted.st_dev += 1
        XCTAssertFalse(identity.matches(WorkspaceDirectoryIdentity(remounted)))
        XCTAssertTrue(identity.matches(WorkspaceDirectoryIdentity(remounted), allowDeviceChange: true))
        for changed in ["inode", "owner", "birth"] {
            var replacement = remounted
            switch changed { case "inode": replacement.st_ino += 1; case "owner": replacement.st_uid += 1; default: replacement.st_birthtimespec.tv_nsec = (replacement.st_birthtimespec.tv_nsec + 1) % 1_000_000_000 }
            XCTAssertFalse(identity.matches(WorkspaceDirectoryIdentity(replacement), allowDeviceChange: true))
        }
    }
    func testDirectoryIdentityNeverFollowsALinkOrAcceptsARegularFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-follow-parent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("file"), link = root.appendingPathComponent("link")
        try Data().write(to: file); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertNotNil(WorkspaceDirectoryIdentity.capture(at: root))
        XCTAssertNil(WorkspaceDirectoryIdentity.capture(at: file))
        XCTAssertNil(WorkspaceDirectoryIdentity.capture(at: link))
        XCTAssertNil(WorkspaceDirectoryIdentity.capture(at: root.appendingPathComponent("absent")))
    }
    func testOldVolumeHistoryDecodesWithoutAuthorizingNewWrites() throws {
        let old = VolumeUsage(bsdName: "disk1s1", name: "Old", mountPoint: "/", totalBytes: 1024, availableBytes: 512, sharedCapacityKey: "disk1")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "writeDirectoryIdentity")
        let decoded = try JSONDecoder().decode(VolumeUsage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.writeDirectoryIdentity)
        XCTAssertEqual(decoded.usedBytes, 512)
        XCTAssertThrowsError(try DiskTestWorkspace.validatedLocation(volume: decoded))
    }
}
