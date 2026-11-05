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
            return .null
        }
        _ = try await h.run("test.packageCancellation")
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
