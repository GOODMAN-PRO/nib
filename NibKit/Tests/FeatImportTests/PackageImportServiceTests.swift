import XCTest
import NibContracts
import NibTesting
@testable import FeatImport

@MainActor
final class PackageImportServiceTests: XCTestCase {
    func testTreeCancellationKeepsCompletedImportsAndStopsWithoutSkippedEntries() async throws {
        let h = Harness(features: [FeatImportFeature.self])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["1.nibnote", "2.nibnote", "3.nibnote"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        var calls = 0
        let importer: PackageImporter.PackageImport = { _, _, _ in
            calls += 1
            if calls == 2 { throw CancellationError() }
            return "IMPORTED"
        }
        h.app.services.set(importer as AnyObject, for: PackageImporter.packageImportKey)
        h.app.commands.register(CommandDescriptor(id: "test.packageCancellation", title: "Import", summary: "Exercise cancelled tree imports.",
            effect: .library, target: .library)) { _, ctx in
            let report = ImportReport()
            let contents = await PackageImporter.importContents(of: directory, into: nil, ctx: ctx,
                library: h.library, report: report, prefix: "", top: true)
            XCTAssertEqual(contents, ["IMPORTED"])
            XCTAssertEqual(calls, 2, "cancellation must not attempt the remaining package")
            XCTAssertTrue(report.skipped.isEmpty, "cancellation is not a damaged or unsupported entry")
            XCTAssertTrue(report.cancelled)
            XCTAssertTrue(report.incomplete)
            return .null
        }
        _ = try await h.run("test.packageCancellation")
    }

    func testInboxArchiveCancellationPreservesCompletedDocumentsAndOriginalBytes() async throws {
        // Both a thrown cancellation and a cancelled task must survive archive/folder report propagation.
        for cancelTask in [false, true] {
            let h = Harness(features: [FeatImportFeature.self])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let inbox = ImportLocations.openInInbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.removeItem(at: inbox)
            }
            let inner = directory.appendingPathComponent("inner", isDirectory: true)
            for name in ["1.nibnote", "2.nibnote", "3.nibnote"] {
                let package = inner.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                try Data(name.utf8).write(to: package.appendingPathComponent("payload"))
            }
            // A nested archive exercises absorb as well as the shared report used by folder traversal.
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let archive = inbox.appendingPathComponent("Notes.zip")
            // Put the nested zip inside a folder so traversal reaches it before the later outer package.
            let tree = directory.appendingPathComponent("tree/1-folder", isDirectory: true)
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try ArchiveIO.archive(contentsOf: inner, to: tree.appendingPathComponent("1.zip"))
            try FileManager.default.createDirectory(at: tree.deletingLastPathComponent().appendingPathComponent("4.nibnote"),
                                                    withIntermediateDirectories: true)
            try ArchiveIO.archive(contentsOf: tree.deletingLastPathComponent(), to: archive)
            let bytes = try Data(contentsOf: archive)
            let later = inbox.appendingPathComponent("Later.nibnote", isDirectory: true)
            try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
            var attempted: [String] = []
            let importer: PackageImporter.PackageImport = { library, url, folder in
                attempted.append(url.lastPathComponent)
                if attempted.count == 2 {
                    if cancelTask { withUnsafeCurrentTask { $0?.cancel() } }
                    throw CancellationError()
                }
                return try library.createDocument(DocumentContent(meta: DocumentMeta(id: "IMPORTED", kind: .notebook)),
                                                  title: "Completed", in: folder)
            }
            h.app.services.set(importer as AnyObject, for: PackageImporter.packageImportKey)
            let task = Task { @MainActor in
                try await h.run("import.files", ["urls": .array([archive, later].map { .string($0.absoluteString) }), "folder": "lib"])
            }
            let result = try await task.value
            XCTAssertEqual(result["refs"]?.arrayValue, [.string("doc:IMPORTED")])
            XCTAssertEqual(result["cancelled"]?.boolValue, true)
            XCTAssertNil(result["failed"])
            XCTAssertEqual(attempted, ["1.nibnote", "2.nibnote"])
            XCTAssertNotNil(h.library.node("IMPORTED"))
            XCTAssertEqual(try Data(contentsOf: archive), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: later.path))
        }
    }

    func testPackageAndArchiveContentsUseTheAwaitedLibraryService() async throws {
        let h = Harness(features: [FeatImportFeature.self])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = directory.appendingPathComponent("Notes.nibnote", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let importer: PackageImporter.PackageImport = { library, url, folder in
            XCTAssertTrue(library === h.library)
            XCTAssertEqual(url, package)
            XCTAssertNil(folder)
            await Task.yield()
            calls += 1
            return "IMPORTED"
        }
        h.app.services.set(importer as AnyObject, for: PackageImporter.packageImportKey)
        h.app.commands.register(CommandDescriptor(id: "test.packageService", title: "Import", summary: "Exercise package routes.",
            effect: .library, target: .library)) { _, ctx in
            let direct = try await PackageImporter.importPackage(package, target: ImportTarget(), ctx: ctx)
            XCTAssertEqual(direct, ["IMPORTED"])
            let report = ImportReport()
            let contents = await PackageImporter.importContents(of: directory, into: nil, ctx: ctx,
                library: h.library, report: report, prefix: "", top: true)
            XCTAssertEqual(contents, ["IMPORTED"])
            XCTAssertTrue(report.skipped.isEmpty)
            return .null
        }
        _ = try await h.run("test.packageService")
        XCTAssertEqual(calls, 2)
    }
}
