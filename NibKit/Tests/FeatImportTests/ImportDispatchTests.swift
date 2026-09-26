import XCTest
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibTesting
@testable import FeatImport

/// Dispatch, destinations, naming, sniffing and the other pure pieces of import.
@MainActor
final class ImportDispatchTests: XCTestCase {
    // MARK: Helpers

    private func registries() -> ContentRegistries {
        let content = ContentRegistries()
        content.importers.register(ImageImporter.descriptor(owner: FeatImportFeature.id))
        content.importers.register(PackageImporter.packageDescriptor(owner: FeatImportFeature.id))
        content.importers.register(PackageImporter.archiveDescriptor(owner: FeatImportFeature.id))
        content.importers.register(OfficeConverter.officeDescriptor(owner: FeatImportFeature.id))
        content.importers.register(OfficeConverter.webDescriptor(owner: FeatImportFeature.id))
        content.importers.register(ImporterDescriptor(id: "pdf", title: "PDF", fileExtensions: ["pdf"],
                                                      utTypes: ["com.adobe.pdf"], owner: "pdf") { _, _, _ in [] })
        return content
    }

    private func file(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/nib-import-tests/" + name) }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImportDispatchTests-" + UUID().uuidString,
                                                                               isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { _ in }
    }

    private func kinds(_ groups: [ImportGroup]) -> [ImportGroup.Kind] { groups.map { $0.kind } }

    // MARK: Importer lookup

    func testImporterIsChosenByExtensionIgnoringCase() {
        let content = registries()
        func id(_ name: String) -> String? { ImportEngine.importer(for: file(name), isDirectory: false, content: content)?.id }
        XCTAssertEqual(id("Scan.PNG"), ImportFormats.imageImporterID)
        XCTAssertEqual(id("photo.heic"), ImportFormats.imageImporterID)
        XCTAssertEqual(id("Lecture.pdf"), "pdf")
        XCTAssertEqual(id("Report.docx"), ImportFormats.officeImporterID)
        XCTAssertEqual(id("Deck.PPTX"), ImportFormats.officeImporterID)
        XCTAssertEqual(id("Library backup.zip"), ImportFormats.archiveImporterID)
        XCTAssertEqual(id("Article.webloc"), ImportFormats.webImporterID)
        XCTAssertEqual(id("Kinematics.nibnote"), ImportFormats.packageImporterID)
        XCTAssertNil(id("data.xyz"))
        XCTAssertNil(id("README"))
    }

    func testImporterFallsBackToTypeConformance() {
        let content = ContentRegistries()
        content.importers.register(ImporterDescriptor(id: "anyImage", title: "Images", fileExtensions: [],
                                                      utTypes: [UTType.image.identifier], owner: "test") { _, _, _ in [] })
        XCTAssertEqual(ImportEngine.importer(for: file("photo.png"), isDirectory: false, content: content)?.id, "anyImage")
        XCTAssertEqual(ImportEngine.importer(for: file("photo.tiff"), isDirectory: false, content: content)?.id, "anyImage")
        XCTAssertNil(ImportEngine.importer(for: file("notes.pdf"), isDirectory: false, content: content))
        XCTAssertNil(ImportEngine.importer(for: file("notes.xyz"), isDirectory: false, content: content))
    }

    func testPackagesAreRecognisedByExtensionAndHead() throws {
        let dir = try tempDir()
        let fm = FileManager.default
        let package = dir.appendingPathComponent("Kinematics.nibnote", isDirectory: true)
        let legacy = dir.appendingPathComponent("Old notes.nib", isDirectory: true)
        let interfaceBuilder = dir.appendingPathComponent("Main.nib", isDirectory: true)
        let folder = dir.appendingPathComponent("Trip", isDirectory: true)
        for d in [package, legacy, interfaceBuilder, folder] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("doc.1a2b3c4d.json"))
        try Data().write(to: interfaceBuilder.appendingPathComponent("objects.xib"))

        XCTAssertTrue(PackageImporter.isPackage(package))
        XCTAssertTrue(PackageImporter.isPackage(legacy))
        XCTAssertFalse(PackageImporter.isPackage(interfaceBuilder))
        XCTAssertFalse(PackageImporter.isPackage(folder))

        let files: [(url: URL, isDirectory: Bool)] = [(url: folder, isDirectory: true), (url: package, isDirectory: true),
                                                      (url: legacy, isDirectory: true), (url: interfaceBuilder, isDirectory: true)]
        let groups = ImportEngine.groups(files, content: registries())
        XCTAssertEqual(kinds(groups), [.folderTree, .single(importerID: ImportFormats.packageImporterID),
                                       .single(importerID: ImportFormats.packageImporterID), .folderTree])
    }

    func testConsecutiveImagesShareOneCall() {
        let names = ["a.png", "b.JPG", "c.pdf", "d.heic", "e.xyz", "f.gif", "g.png"]
        let files: [(url: URL, isDirectory: Bool)] = names.map { (url: file($0), isDirectory: false) }
        let groups = ImportEngine.groups(files, content: registries())
        XCTAssertEqual(kinds(groups), [.images, .single(importerID: "pdf"), .images, .unsupported, .images])
        XCTAssertEqual(groups.map { $0.indices }, [[0, 1], [2], [3], [4], [5, 6]])
    }

    func testAnotherOwnersImageImporterRunsFileByFile() {
        let content = ContentRegistries()
        content.importers.register(ImporterDescriptor(id: ImportFormats.imageImporterID, title: "Images",
                                                      fileExtensions: ["png"], owner: "someplugin") { _, _, _ in [] })
        let files: [(url: URL, isDirectory: Bool)] = [(url: file("a.png"), isDirectory: false),
                                                      (url: file("b.png"), isDirectory: false)]
        let groups = ImportEngine.groups(files, content: content)
        XCTAssertEqual(kinds(groups), [.single(importerID: ImportFormats.imageImporterID),
                                       .single(importerID: ImportFormats.imageImporterID)])
    }

    func testUnsupportedErrorNamesWhatIsSupported() {
        let e = ImportEngine.unsupported(file("data.xyz"), content: registries())
        XCTAssertEqual(e.code, .unsupported)
        XCTAssertTrue(e.message.contains(".xyz"))
        XCTAssertTrue(e.hint?.contains("pdf") == true)
        XCTAssertTrue(e.hint?.contains("docx") == true)
        let unknown = ImportEngine.unsupported(file("README"), content: registries())
        XCTAssertTrue(unknown.message.contains("README"))
    }

    func testCanImportForTheInboxScan() throws {
        let content = registries()
        XCTAssertTrue(ImportEngine.canImport(file("a.pdf"), isDirectory: false, content: content))
        XCTAssertFalse(ImportEngine.canImport(file("a.xyz"), isDirectory: false, content: content))
        let dir = try tempDir()
        let package = dir.appendingPathComponent("Doc.nibnote", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertTrue(ImportEngine.canImport(package, isDirectory: true, content: content))
        XCTAssertFalse(ImportEngine.canImport(dir, isDirectory: true, content: content))
    }

    // MARK: Destinations

    func testDestinationParsing() throws {
        XCTAssertNil(try ImportDestination.parse(folder: nil, doc: nil, position: nil, anchor: nil))
        XCTAssertNil(try ImportDestination.parse(folder: " ", doc: "", position: nil, anchor: nil))
        XCTAssertEqual(try ImportDestination.parse(folder: "lib", doc: nil, position: nil, anchor: nil), .libraryRoot)
        XCTAssertEqual(try ImportDestination.parse(folder: "folder:FIXTUREFLD01", doc: nil, position: nil, anchor: nil)?.folder,
                       Fixtures.folderID)
        XCTAssertEqual(try ImportDestination.parse(folder: "FIXTUREFLD01", doc: nil, position: nil, anchor: nil)?.folder,
                       Fixtures.folderID)
        XCTAssertEqual(try ImportDestination.parse(folder: nil, doc: "doc:FIXTUREDOC01", position: "after",
                                                   anchor: "page:FIXTUREDOC01/FIXTUREPG001"),
                       ImportDestination(doc: Fixtures.docID, position: .after, anchor: Fixtures.page1))
        XCTAssertEqual(try ImportDestination.parse(folder: nil, doc: "doc:FIXTUREDOC01", position: nil, anchor: nil),
                       ImportDestination(doc: Fixtures.docID, position: .end))
        // A page ref as doc, or an anchor alone, means after that page.
        XCTAssertEqual(try ImportDestination.parse(folder: nil, doc: "page:FIXTUREDOC01/FIXTUREPG002", position: nil, anchor: nil),
                       ImportDestination(doc: Fixtures.docID, position: .after, anchor: Fixtures.page2))
        XCTAssertEqual(try ImportDestination.parse(folder: nil, doc: nil, position: "BEFORE", anchor: "page:FIXTUREDOC01/FIXTUREPG002"),
                       ImportDestination(doc: Fixtures.docID, position: .before, anchor: Fixtures.page2))
        // start and end ignore an anchor.
        XCTAssertEqual(try ImportDestination.parse(folder: nil, doc: "doc:FIXTUREDOC01", position: "start",
                                                   anchor: "page:FIXTUREDOC01/FIXTUREPG002"),
                       ImportDestination(doc: Fixtures.docID, position: .start))
    }

    func testDestinationErrorsNameTheParameter() {
        func path(_ folder: String?, _ doc: String?, _ position: String?, _ anchor: String?) -> String? {
            do {
                _ = try ImportDestination.parse(folder: folder, doc: doc, position: position, anchor: anchor)
                return nil
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
                return e.path
            } catch {
                return "unexpected \(error)"
            }
        }
        XCTAssertEqual(path("doc:FIXTUREDOC01", nil, nil, nil), "$.folder")
        XCTAssertEqual(path(nil, "folder:FIXTUREFLD01", nil, nil), "$.doc")
        XCTAssertEqual(path(nil, "doc:FIXTUREDOC01", "middle", nil), "$.position")
        XCTAssertEqual(path(nil, nil, "end", nil), "$.doc")
        XCTAssertEqual(path("lib", "doc:FIXTUREDOC01", nil, nil), "$.folder")
        XCTAssertEqual(path(nil, "doc:FIXTUREDOC01", nil, "page:FIXTUREDOC04/FIXTUREBRD01"), "$.anchor")
        XCTAssertEqual(path(nil, "doc:FIXTUREDOC01", nil, "item:A/B/C"), "$.anchor")
    }

    func testPickTargets() throws {
        XCTAssertNil(try ImportPick.parseTarget(nil))
        XCTAssertNil(try ImportPick.parseTarget("  "))
        XCTAssertEqual(try ImportPick.parseTarget("lib"), .libraryRoot)
        XCTAssertEqual(try ImportPick.parseTarget("folder:FIXTUREFLD01"), ImportDestination(folder: Fixtures.folderID))
        XCTAssertEqual(try ImportPick.parseTarget("doc:FIXTUREDOC01"), ImportDestination(doc: Fixtures.docID, position: .end))
        XCTAssertEqual(try ImportPick.parseTarget("page:FIXTUREDOC01/FIXTUREPG001"),
                       ImportDestination(doc: Fixtures.docID, position: .after, anchor: Fixtures.page1))
        XCTAssertThrowsError(try ImportPick.parseTarget("item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01")) { error in
            XCTAssertEqual((error as? NibError)?.path, "$.target")
        }
    }

    func testTargetsCarryTheNameAndTheCallersIDs() {
        let target = ImportDestination(doc: Fixtures.docID, position: .before, anchor: Fixtures.page2)
            .target(displayName: "Scan", ids: ["PAGEA", "PAGEB"])
        XCTAssertEqual(target.document, Fixtures.docID)
        XCTAssertEqual(target.position, .before)
        XCTAssertEqual(target.anchorPage, Fixtures.page2)
        XCTAssertEqual(target.displayName, "Scan")
        XCTAssertEqual(target.ids, ["PAGEA", "PAGEB"])
        XCTAssertNil(ImportDestination.libraryRoot.target(displayName: nil, ids: []).ids)
    }

    func testCallerIDsAreCheckedOnce() throws {
        XCTAssertEqual(try ImportEngine.validatedIDs(["IDA_1", "IDB-2"]), ["IDA_1", "IDB-2"])
        XCTAssertEqual(try ImportEngine.validatedIDs(nil), [])
        XCTAssertThrowsError(try ImportEngine.validatedIDs(["bad id"])) { error in
            XCTAssertEqual((error as? NibError)?.path, "$.ids[0]")
        }
        XCTAssertThrowsError(try ImportEngine.validatedIDs(["SAME", "SAME"])) { error in
            XCTAssertEqual((error as? NibError)?.path, "$.ids[1]")
        }
    }

    // MARK: Names, formats and content

    func testDisplayNamesAndTitles() {
        XCTAssertEqual(ImportNaming.displayName(of: "tmp:lecture.pdf"), "lecture.pdf")
        XCTAssertEqual(ImportNaming.displayName(of: "https://example.com/files/My%20Notes.pdf"), "My Notes.pdf")
        XCTAssertEqual(ImportNaming.displayName(of: "https://example.com/"), "example.com")
        XCTAssertEqual(ImportNaming.displayName(of: "file:///private/var/mobile/Documents/Inbox/Report.docx"), "Report.docx")
        XCTAssertEqual(ImportNaming.title(of: file("Kinematics.pdf")), "Kinematics")
        XCTAssertEqual(ImportNaming.title(of: file("Scan")), "Scan")
    }

    func testSanitisedNamesAreOnePathComponent() {
        XCTAssertEqual(ImportNaming.sanitize("../secret:file/.txt"), "-secret-file-.txt")
        XCTAssertEqual(ImportNaming.sanitize("  Notes.pdf  "), "Notes.pdf")
        XCTAssertEqual(ImportNaming.sanitize("..."), "Imported")
        let long = ImportNaming.sanitize(String(repeating: "a", count: 300) + ".pdf")
        XCTAssertLessThanOrEqual(long.count, 200)
        XCTAssertTrue(long.hasSuffix(".pdf"))
        XCTAssertFalse(ImportNaming.sanitize("a/b\\c").contains("/"))
        XCTAssertFalse(ImportNaming.sanitize("a/b\\c").contains("\\"))
    }

    func testUniqueNamesNeverOverwrite() throws {
        let dir = try tempDir()
        let first = ImportNaming.unique("a.pdf", in: dir)
        XCTAssertEqual(first.lastPathComponent, "a.pdf")
        try Data().write(to: first)
        let second = ImportNaming.unique("a.pdf", in: dir)
        XCTAssertEqual(second.lastPathComponent, "a 2.pdf")
        try Data().write(to: second)
        XCTAssertEqual(ImportNaming.unique("a.pdf", in: dir).lastPathComponent, "a 3.pdf")
        XCTAssertEqual(ImportNaming.unique("Scan", in: dir).lastPathComponent, "Scan")
    }

    func testSnifferRecognisesCommonFormats() {
        XCTAssertEqual(ContentSniffer.sniff(Data("%PDF-1.7\n".utf8)), "pdf")
        XCTAssertEqual(ContentSniffer.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), "png")
        XCTAssertEqual(ContentSniffer.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])), "jpg")
        XCTAssertEqual(ContentSniffer.sniff(Data("GIF89a".utf8)), "gif")
        XCTAssertEqual(ContentSniffer.sniff(Data([0x50, 0x4B, 0x03, 0x04, 0x14])), "zip")
        XCTAssertEqual(ContentSniffer.sniff(Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0])), "heic")
        XCTAssertEqual(ContentSniffer.sniff(Data("\u{FEFF}  <!DOCTYPE html><html></html>".utf8)), "html")
        XCTAssertEqual(ContentSniffer.sniff(png(width: 2, height: 2)), "png")
        XCTAssertNil(ContentSniffer.sniff(Data("hello".utf8)))
        XCTAssertNil(ContentSniffer.sniff(Data()))
    }

    func testFormatsDecideWhatTheDialogOffers() {
        for name in ["a.PDF", "b.heic", "c.pptx", "d.webloc", "e.html"] { XCTAssertTrue(ImportFormats.isPageFormat(name), name) }
        for name in ["e.nibnote", "f.zip", "g.csv", "h"] { XCTAssertFalse(ImportFormats.isPageFormat(name), name) }
        XCTAssertFalse(ImportFormats.needsDestination("Tool.nibplugin"))
        XCTAssertFalse(ImportFormats.needsDestination("Stickers.nibcollection"))
        XCTAssertTrue(ImportFormats.needsDestination("a.pdf"))
        XCTAssertTrue(ImportDialogLogic.allowsCurrentDocument(names: ["a.pdf", "b.png"]))
        XCTAssertFalse(ImportDialogLogic.allowsCurrentDocument(names: ["a.pdf", "b.zip"]))
        XCTAssertFalse(ImportDialogLogic.allowsCurrentDocument(names: []))
    }

    // MARK: Pages

    func testPageSlotsLandBetweenTheNeighbours() {
        let live = [PageRecord(id: "P1", order: "A"), PageRecord(id: "P2", order: "M"), PageRecord(id: "P3", order: "T")]
        XCTAssertTrue(PageSlot.neighbours(live, .before, anchor: "P2") == ("A", "M"))
        XCTAssertTrue(PageSlot.neighbours(live, .after, anchor: "P3") == ("T", nil))
        XCTAssertTrue(PageSlot.neighbours(live, .start, anchor: nil) == (nil, "A"))
        XCTAssertTrue(PageSlot.neighbours(live, .after, anchor: "GONE") == ("T", nil))

        let after = PageSlot.keys(live, .after, anchor: "P1", count: 5)
        XCTAssertEqual(after.count, 5)
        XCTAssertEqual(after, after.sorted())
        XCTAssertTrue(after.allSatisfy { $0 > "A" && $0 < "M" })
        XCTAssertTrue(PageSlot.keys(live, .before, anchor: "P1", count: 2).allSatisfy { $0 < "A" })
        XCTAssertTrue(PageSlot.keys(live, .end, anchor: nil, count: 2).allSatisfy { $0 > "T" })
        let many = PageSlot.keys(live, .end, anchor: nil, count: 1_000)
        XCTAssertEqual(Set(many).count, 1_000)
        XCTAssertLessThanOrEqual(many.map { $0.count }.max() ?? 0, 4)
    }

    func testImagePagesTakeTheImageAspectRatio() {
        let a4 = PageSize.a4
        let portrait = ImageFile.pageSize(forPixels: CGSize(width: 1000, height: 2000), base: a4)
        XCTAssertEqual(portrait.width, 595.28, accuracy: 0.001)
        XCTAssertEqual(portrait.height, 1190.56, accuracy: 0.011)
        let landscape = ImageFile.pageSize(forPixels: CGSize(width: 2000, height: 1000), base: a4)
        XCTAssertEqual(landscape.width, 841.89, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 420.945, accuracy: 0.011)
        let square = ImageFile.pageSize(forPixels: CGSize(width: 500, height: 500), base: a4.rotated)
        XCTAssertEqual(square.width, 595.28, accuracy: 0.001)
        XCTAssertEqual(square.height, 595.28, accuracy: 0.011)
        XCTAssertEqual(ImageFile.pageSize(forPixels: CGSize(width: 1, height: 100_000), base: a4).height, 100_000)
        XCTAssertEqual(ImageFile.pageSize(forPixels: .zero, base: a4), PageSize(595.28, 841.89))
    }

    func testPreparedImagesKnowTheirSizeAndKind() throws {
        let prepared = try ImageFile.prepare(png(width: 40, height: 20), name: "Board.png")
        XCTAssertEqual(prepared.pixels, CGSize(width: 40, height: 20))
        XCTAssertEqual(prepared.ext, "png")
        let unnamed = try ImageFile.prepare(png(width: 3, height: 5), name: "Scan")
        XCTAssertEqual(unnamed.ext, "png")
        let jpeg = UIImage(data: png(width: 8, height: 8))?.jpegData(compressionQuality: 0.8) ?? Data()
        XCTAssertEqual(try ImageFile.prepare(jpeg, name: "photo.jpeg").ext, "jpg")
        XCTAssertThrowsError(try ImageFile.prepare(Data("not an image".utf8), name: "fake.png")) { error in
            XCTAssertEqual((error as? NibError)?.code, .unsupported)
        }
    }

    // MARK: Dialog logic

    func testFolderOptionsAreDepthFirstByName() {
        let nodes = [
            LibraryNode(id: "PHYSICS", kind: .folder, title: "Physics", path: "Physics"),
            LibraryNode(id: "CHEM", kind: .folder, title: "Chemistry", path: "Chemistry"),
            LibraryNode(id: "WAVES", kind: .folder, title: "Waves", path: "Physics/Waves", parent: "PHYSICS"),
            LibraryNode(id: "DOC", kind: .document, title: "Notes", path: "Notes"),
            LibraryNode(id: "OLD", kind: .folder, title: "Old", path: "Old", trashedAt: 1),
        ]
        let options = ImportDialogLogic.folderOptions(nodes, rootTitle: "Library")
        XCTAssertEqual(options.map { $0.title }, ["Library", "Chemistry", "Physics", "Waves"])
        XCTAssertEqual(options.map { $0.depth }, [0, 1, 1, 2])
        XCTAssertEqual(options.map { $0.id }, ["lib", "CHEM", "PHYSICS", "WAVES"])
    }

    func testDialogDestinations() {
        let current = ImportCurrentDocument(id: "DOC", title: "Physics", page: "P3", pageNumber: 3, pageCount: 5)
        XCTAssertEqual(ImportDialogLogic.destination(mode: .newDocument, folder: "F", current: current, position: .after,
                                                     preset: nil), ImportDestination(folder: "F"))
        XCTAssertEqual(ImportDialogLogic.destination(mode: .currentDocument, folder: "F", current: current, position: .before,
                                                     preset: nil), ImportDestination(doc: "DOC", position: .before, anchor: "P3"))
        XCTAssertEqual(ImportDialogLogic.destination(mode: .currentDocument, folder: nil, current: current, position: .end,
                                                     preset: nil), ImportDestination(doc: "DOC", position: .end))
        let noPage = ImportCurrentDocument(id: "DOC", title: "Physics", page: nil, pageNumber: nil, pageCount: 0)
        XCTAssertEqual(ImportDialogLogic.destination(mode: .currentDocument, folder: nil, current: noPage, position: .after,
                                                     preset: nil), ImportDestination(doc: "DOC", position: .end))
        XCTAssertEqual(ImportDialogLogic.destination(mode: .currentDocument, folder: nil, current: nil, position: .after,
                                                     preset: nil), ImportDestination())
        let preset = ImportDestination(folder: "PRESET")
        XCTAssertEqual(ImportDialogLogic.destination(mode: .currentDocument, folder: "F", current: current, position: .after,
                                                     preset: preset), preset)
        XCTAssertEqual(ImportDialogLogic.positions(hasPage: true), [.before, .after, .end])
        XCTAssertEqual(ImportDialogLogic.positions(hasPage: false), [.start, .end])
        XCTAssertEqual(ImportDialogLogic.positionTitle(.before, pageNumber: 3), "Before Page 3")
        XCTAssertEqual(ImportDialogLogic.positionTitle(.after, pageNumber: nil), "After This Page")
    }

    func testMovingFilesInTheOrder() {
        XCTAssertEqual(ImportDialogLogic.moved([0, 1, 2], 2, by: -1), [0, 2, 1])
        XCTAssertEqual(ImportDialogLogic.moved([0, 1, 2], 1, by: 1), [0, 2, 1])
        XCTAssertEqual(ImportDialogLogic.moved([0, 1, 2], 0, by: -1), [0, 1, 2])
        XCTAssertEqual(ImportDialogLogic.moved([0, 1, 2], 2, by: 1), [0, 1, 2])
        XCTAssertEqual(ImportDialogLogic.moved([0, 1, 2], 7, by: 1), [0, 1, 2])
        XCTAssertEqual(ImportDialogLogic.title(names: ["a.pdf"]), "Import “a.pdf”?")
        XCTAssertEqual(ImportDialogLogic.title(names: ["a.pdf", "b.pdf"]), "Import 2 files?")
    }

    func testDialogModelHandsBackTheChoiceAndTheOrder() {
        let current = ImportCurrentDocument(id: "DOC", title: "Physics", page: "P3", pageNumber: 3, pageCount: 5)
        let model = ImportDialogModel(names: ["a.pdf", "b.png"],
                                      folders: [ImportFolderOption(folder: nil, title: "Library", depth: 0)],
                                      current: current, preset: nil, presetSummary: nil)
        XCTAssertEqual(model.position, .after)
        XCTAssertEqual(model.primaryTitle, "Import 2 Files")
        var chosen: ImportChoice?
        var calls = 0
        model.onChoose = { choice in
            chosen = choice
            calls += 1
        }
        model.mode = .currentDocument
        model.position = .before
        model.move(1, by: -1)
        model.confirm()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(chosen, ImportChoice(destination: ImportDestination(doc: "DOC", position: .before, anchor: "P3"),
                                            order: [1, 0]))
        model.phase = .importing
        XCTAssertNil(model.primaryTitle)
        model.confirm()
        XCTAssertEqual(calls, 1)
        model.cancel()
        XCTAssertTrue(model.cancelRequested)
        model.showResult([ImportFailure(url: "tmp:b.png", code: "unsupported", message: "no")])
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.title, "1 of 2 imported")
    }

    // MARK: Share hand-off, web locations, inboxes and drops

    func testHandoffLinks() {
        XCTAssertTrue(ShareHandoff.isHandoffLink("nib://import?from=pasteboard"))
        XCTAssertTrue(ShareHandoff.isHandoffLink("NIB://IMPORT?from=pasteboard"))
        XCTAssertFalse(ShareHandoff.isHandoffLink("nib://import"))
        XCTAssertFalse(ShareHandoff.isHandoffLink("https://import?from=pasteboard"))
        XCTAssertFalse(ShareHandoff.isHandoffLink("nib://open/FIXTUREDOC01"))
    }

    func testHandoffItemsBecomeFiles() throws {
        let dir = try tempDir()
        let pdf = Data("%PDF-1.4".utf8)
        let image = png(width: 2, height: 2)
        let items: [[String: Any]] = [
            [ShareHandoff.nameType: Data("Lecture.pdf".utf8), ShareHandoff.dataType: pdf],
            [ShareHandoff.nameType: "../Photo.png", ShareHandoff.dataType: image],
            ["public.utf8-plain-text": "not ours"],
        ]
        let urls = try ShareHandoff.write(items, into: dir)
        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["Lecture.pdf", "-Photo.png"])
        XCTAssertEqual(try Data(contentsOf: urls[0]), pdf)
        XCTAssertEqual(try Data(contentsOf: urls[1]), image)
        XCTAssertTrue(urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL })
    }

    func testWebLocationsRoundTrip() throws {
        let dir = try tempDir()
        let file = try WebLocation.write(URL(string: "https://example.com/a?b=1")!, title: "Example: Page", in: dir)
        XCTAssertEqual(file.lastPathComponent, "Example- Page.webloc")
        XCTAssertEqual(WebLocation.read(file)?.absoluteString, "https://example.com/a?b=1")
        let local = try PropertyListSerialization.data(fromPropertyList: ["URL": "file:///etc/hosts"], format: .xml, options: 0)
        XCTAssertNil(WebLocation.address(in: local))
        XCTAssertNil(WebLocation.address(in: Data("garbage".utf8)))
    }

    func testInboxOffersWhatArrivedOnce() throws {
        let root = try tempDir()
        let fm = FileManager.default
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: inbox.appendingPathComponent("Trip", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: documents.appendingPathComponent("Library", isDirectory: true), withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: inbox.appendingPathComponent("shared.pdf"))
        try Data("%PDF".utf8).write(to: documents.appendingPathComponent("loose.pdf"))
        try Data().write(to: documents.appendingPathComponent("notes.xyz"))
        try Data().write(to: documents.appendingPathComponent(".hidden.pdf"))

        let entries = InboxFiles.entries(inboxes: [inbox], documents: documents)
        XCTAssertEqual(Set(entries.map { $0.url.lastPathComponent }), ["shared.pdf", "Trip", "loose.pdf", "notes.xyz"])
        XCTAssertEqual(entries.first { $0.url.lastPathComponent == "Trip" }?.isDirectory, true)
        XCTAssertEqual(entries.first { $0.url.lastPathComponent == "loose.pdf" }?.fromInbox, false)

        let pdfOnly: (URL, Bool) -> Bool = { url, isDirectory in !isDirectory && url.pathExtension == "pdf" }
        let offered = InboxFiles.offered(entries, inFlight: [], declined: [], canImport: pdfOnly)
        XCTAssertEqual(Set(offered.map { $0.url.lastPathComponent }), ["shared.pdf", "Trip", "loose.pdf"])
        let loose = try XCTUnwrap(entries.first { $0.url.lastPathComponent == "loose.pdf" })
        let shared = try XCTUnwrap(entries.first { $0.url.lastPathComponent == "shared.pdf" })
        let later = InboxFiles.offered(entries, inFlight: [shared.url.standardizedFileURL.path], declined: [loose.key],
                                       canImport: pdfOnly)
        XCTAssertEqual(later.map { $0.url.lastPathComponent }, ["Trip"])
        // A declined file changes: it is offered again.
        try Data("%PDF-1.7 changed".utf8).write(to: loose.url)
        XCTAssertNotEqual(InboxFiles.key(loose.url), loose.key)
    }

    func testLocationsTellInsideFromOutside() {
        XCTAssertTrue(ImportLocations.isInside(URL(fileURLWithPath: "/a/b/c.pdf"), URL(fileURLWithPath: "/a/b")))
        XCTAssertFalse(ImportLocations.isInside(URL(fileURLWithPath: "/a/bc/d.pdf"), URL(fileURLWithPath: "/a/b")))
        XCTAssertTrue(ImportLocations.isInsideApp(FileManager.default.temporaryDirectory.appendingPathComponent("x.pdf")))
        XCTAssertTrue(ImportLocations.isInConsumableInbox(ImportLocations.openInInbox.appendingPathComponent("x.pdf")))
        XCTAssertFalse(ImportLocations.isInConsumableInbox(ImportLocations.documents.appendingPathComponent("x.pdf")))
    }

    func testDropPlans() {
        let content = registries()
        XCTAssertEqual(DropLoader.plan(for: ["com.adobe.pdf"], content: content), .file("com.adobe.pdf"))
        XCTAssertEqual(DropLoader.plan(for: ["public.png"], content: content), .file("public.png"))
        XCTAssertEqual(DropLoader.plan(for: ["public.folder"], content: content), .file("public.folder"))
        XCTAssertNil(DropLoader.plan(for: ["app.nib.fragment", "public.png"], content: content))
        XCTAssertEqual(DropLoader.plan(for: ["public.url"], content: content), .webLink)
        XCTAssertNil(DropLoader.plan(for: ["public.file-url", "public.url"], content: content))
        XCTAssertNil(DropLoader.plan(for: ["public.utf8-plain-text"], content: content))
        XCTAssertEqual(DropLoader.fileName(suggested: "Scan", fallback: "tmp123.jpeg", type: "public.jpeg"), "Scan.jpeg")
        XCTAssertEqual(DropLoader.fileName(suggested: nil, fallback: "report", type: "com.adobe.pdf"), "report.pdf")
        XCTAssertEqual(DropLoader.fileName(suggested: "a/b.pdf", fallback: "x", type: "com.adobe.pdf"), "a-b.pdf")
    }

    // MARK: Archives and backups

    func testArchivesKeepTheirFolders() throws {
        let root = try tempDir()
        let fm = FileManager.default
        let source = root.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent("Physics", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("Chemistry", isDirectory: true), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: source.appendingPathComponent("Physics/a.txt"))
        try Data("b".utf8).write(to: source.appendingPathComponent("Chemistry/b.txt"))
        let zip = root.appendingPathComponent("folders.zip")
        try ArchiveIO.archive(contentsOf: source, to: zip)
        XCTAssertEqual(ContentSniffer.sniff(zip), "zip")
        let out = root.appendingPathComponent("out", isDirectory: true)
        try ArchiveIO.extract(zip, to: out)
        let entries = ArchiveIO.visibleEntries(of: out)
        XCTAssertEqual(entries.map { $0.url.lastPathComponent }, ["Chemistry", "Physics"])
        XCTAssertTrue(entries.allSatisfy { $0.isDirectory })
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("Physics/a.txt")), Data("a".utf8))
    }

    func testBackupRootsAreFoundAtTheTopOrOneFolderDown() throws {
        let root = try tempDir()
        let fm = FileManager.default
        let top = root.appendingPathComponent("top", isDirectory: true)
        try fm.createDirectory(at: top.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true),
                               withIntermediateDirectories: true)
        XCTAssertEqual(PackageImporter.backupRoot(in: top)?.standardizedFileURL, top.standardizedFileURL)
        let wrapped = root.appendingPathComponent("wrapped", isDirectory: true)
        let inner = wrapped.appendingPathComponent("My Library", isDirectory: true)
        try fm.createDirectory(at: inner.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true),
                               withIntermediateDirectories: true)
        XCTAssertEqual(PackageImporter.backupRoot(in: wrapped)?.lastPathComponent, "My Library")
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try fm.createDirectory(at: plain.appendingPathComponent("Physics", isDirectory: true), withIntermediateDirectories: true)
        XCTAssertNil(PackageImporter.backupRoot(in: plain))
    }

    func testBackupDataMergeKeepsWhatIsThereAndSkipsTrash() throws {
        let root = try tempDir()
        let fm = FileManager.default
        let source = root.appendingPathComponent("backup", isDirectory: true)
        let destination = root.appendingPathComponent("library", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent("templates/Planner", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("trash", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("templates/Planner/week.pdf"))
        try Data("theirs".utf8).write(to: source.appendingPathComponent("prefs.1a2b3c4d.json"))
        try Data("x".utf8).write(to: source.appendingPathComponent("trash/Old.nibnote"))
        try Data("mine".utf8).write(to: destination.appendingPathComponent("prefs.1a2b3c4d.json"))

        try ArchiveIO.merge(source, into: destination, skipping: ["trash"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("templates/Planner/week.pdf")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("prefs.1a2b3c4d.json")), Data("mine".utf8))
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("trash").path))
    }
}
