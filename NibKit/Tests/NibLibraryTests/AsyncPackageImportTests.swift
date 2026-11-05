import XCTest
import NibContracts
import NibTesting
@testable import NibLibrary

@MainActor
final class AsyncPackageImportTests: XCTestCase {
    private func source(in directory: URL) throws -> URL {
        let package = directory.appendingPathComponent("Vocabulary.nibnote", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = DocumentContent(meta: DocumentMeta(id: "ASYNCIMPORT", kind: .studySet))
        try PackageIO.encoder().encode(content).write(to: package.appendingPathComponent("doc.0000000b.json"))
        return package
    }

    func testCopyLeavesMainActorResponsiveAndPublishesPreparedCatalog() async throws {
        let lib = try TempLibrary()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: lib.root); try? FileManager.default.removeItem(at: outside) }
        await lib.library.waitForScans()
        let package = try source(in: outside)
        let started = expectation(description: "worker started")
        let gate = DispatchSemaphore(value: 0)
        let task = Task { @MainActor in
            try await lib.library.importPackageAsync(at: package, into: nil) {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw NibError(.timeout, "test copy gate") }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(lib.library.allNodes().isEmpty, "an incomplete import must not be visible")
        let folder = try lib.library.createFolder(title: "Main actor advanced", in: nil, style: nil)
        XCTAssertNotNil(lib.library.node(folder))
        gate.signal()
        let imported = try await task.value
        XCTAssertEqual(imported, "ASYNCIMPORT")
        XCTAssertEqual(lib.library.node(imported)?.path, "Vocabulary.nibnote")
        XCTAssertEqual(lib.head(imported)?.meta.id, imported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        let second = try await lib.library.importPackageAsync(at: package, into: folder)
        XCTAssertNotEqual(second, imported)
        XCTAssertEqual(lib.library.node(second)?.parent, folder)
        XCTAssertEqual(lib.head(second)?.meta.id, second)
        lib.library.rebuild()
        XCTAssertEqual(lib.library.node(second)?.parent, folder)
        await lib.library.waitForScans()
    }

    func testConcurrentIdentityCollisionRefusesImportAndKeepsOriginal() async throws {
        let lib = try TempLibrary()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: lib.root); try? FileManager.default.removeItem(at: outside) }
        await lib.library.waitForScans()
        let package = try source(in: outside)
        let started = expectation(description: "worker started")
        let gate = DispatchSemaphore(value: 0)
        let task = Task { @MainActor in
            try await lib.library.importPackageAsync(at: package, into: nil) {
                started.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw NibError(.timeout, "test copy gate") }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let existing = try lib.library.importPackage(at: package, into: nil)
        gate.signal()
        do { _ = try await task.value; XCTFail("An intervening ID collision must not publish a second document") }
        catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        XCTAssertEqual(lib.library.allNodes().map(\.id), [existing])
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: lib.library.metadataURL.path).contains { $0.hasPrefix("import-") })
    }

    func testUnreadableCopyPublishesNothingAndRemovesStaging() async throws {
        let lib = try TempLibrary()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: lib.root); try? FileManager.default.removeItem(at: outside) }
        await lib.library.waitForScans()
        let package = try source(in: outside)
        let head = package.appendingPathComponent("doc.0000000b.json")
        let broken = Data("{truncated".utf8)
        try broken.write(to: head)
        do { _ = try await lib.library.importPackageAsync(at: package, into: nil); XCTFail("A corrupt copy must fail") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertTrue(lib.library.allNodes().isEmpty)
        XCTAssertFalse(lib.exists("Vocabulary.nibnote"))
        XCTAssertEqual(try Data(contentsOf: head), broken)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: lib.library.metadataURL.path).contains { $0.hasPrefix("import-") })
    }

    func testRootSwitchDuringCopyDoesNotPublishIntoEitherLibrary() async throws {
        let lib = try TempLibrary()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let otherRoot = outside.appendingPathComponent("Other Library", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: lib.root); try? FileManager.default.removeItem(at: outside) }
        await lib.library.waitForScans()
        let package = try source(in: outside)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let originalMetadata = lib.library.metadataURL
        let started = expectation(description: "worker started")
        let gate = DispatchSemaphore(value: 0)
        let task = Task { @MainActor in
            try await lib.library.importPackageAsync(at: package, into: nil) {
                started.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw NibError(.timeout, "test copy gate") }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        try lib.library.setRoot(otherRoot)
        gate.signal()
        do { _ = try await task.value; XCTFail("A root switch must invalidate the import") }
        catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        await lib.library.waitForScans()
        XCTAssertTrue(lib.library.allNodes().isEmpty)
        XCTAssertFalse(lib.exists("Vocabulary.nibnote"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherRoot.appendingPathComponent("Vocabulary.nibnote").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: originalMetadata.path).contains { $0.hasPrefix("import-") })
    }
}
