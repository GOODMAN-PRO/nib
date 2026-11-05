import XCTest
import NibContracts
import NibTesting
@testable import FeatImport

@MainActor
final class PackageImportServiceTests: XCTestCase {
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
