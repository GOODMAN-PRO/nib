import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatImport

/// `import.files` and `import.pick` end to end through the command bus (Harness, in-memory library and assets).
@MainActor
final class FeatImportTests: XCTestCase {
    // MARK: Helpers

    private func harness() -> Harness { Harness(features: [FeatImportFeature.self]) }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FeatImportTests-" + UUID().uuidString,
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

    @discardableResult
    private func writePNG(_ name: String, in dir: URL, width: Int = 20, height: Int = 30) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png(width: width, height: height).write(to: url)
        return url
    }

    private func urls(_ files: [URL]) -> JSONValue { .array(files.map { .string($0.absoluteString) }) }

    private func livePages(_ h: Harness, _ doc: DocumentID = Fixtures.docID) throws -> [PageID] {
        try h.app.workspace.content(doc).livePages.map { $0.id }
    }

    private func expectError(_ code: NibError.Code, path: String? = nil, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.message, file: file, line: line)
            if let path = path { XCTAssertEqual(e.path, path, file: file, line: line) }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Registration

    func testCommandsFollowTheConventions() async {
        let problems = await CommandConformance.check(features: [FeatImportFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testFeatureRegistersImportersMenusAndShortcut() throws {
        let h = harness()
        for id in [ImportFormats.imageImporterID, ImportFormats.packageImporterID, ImportFormats.archiveImporterID,
                   ImportFormats.officeImporterID, ImportFormats.webImporterID] {
            XCTAssertEqual(h.app.content.importers.get(id)?.owner, FeatImportFeature.id, id)
        }
        XCTAssertEqual(h.app.commands.descriptor("import.files")?.effect, .library)
        XCTAssertEqual(h.app.commands.descriptor("import.files")?.owner, FeatImportFeature.id)
        XCTAssertEqual(h.app.commands.descriptor("import.pick")?.userPresence, true)
        XCTAssertEqual(h.app.content.keyCommands.get("import.pick")?.command, "import.pick")

        let libraryNew = try XCTUnwrap(h.app.ui.menus.get("import.libraryNew"))
        XCTAssertEqual(libraryNew.location, .libraryNew)
        let inFolder: JSONValue = ["target": "folder:FIXTUREFLD01"]
        let atRoot: JSONValue = ["target": "lib"]
        XCTAssertEqual(libraryNew.params(MenuContext(app: h.app, folder: Fixtures.folderID)), inFolder)
        XCTAssertEqual(libraryNew.params(MenuContext(app: h.app)), atRoot)

        let addPage = try XCTUnwrap(h.app.ui.menus.get("import.addPage"))
        let onPage = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page2)
        let afterPage: JSONValue = ["target": "page:FIXTUREDOC01/FIXTUREPG002"]
        XCTAssertTrue(addPage.isVisible(onPage))
        XCTAssertEqual(addPage.params(onPage), afterPage)
        XCTAssertFalse(addPage.isVisible(MenuContext(app: h.app, doc: Fixtures.textDocID)))
        XCTAssertFalse(addPage.isVisible(MenuContext(app: h.app, doc: Fixtures.whiteboardID)))
    }

    // MARK: Images

    func testImagesBecomeANotebookWithAPagePerImage() async throws {
        let h = harness()
        let dir = try tempDir()
        let tall = try writePNG("Whiteboard photo.png", in: dir, width: 100, height: 200)
        let wide = try writePNG("Slide.png", in: dir, width: 300, height: 150)
        let result = try await h.run("import.files", ["urls": urls([tall, wide]), "folder": "folder:FIXTUREFLD01",
                                                      "ids": ["IMAGENOTE001"]])
        let refs: JSONValue = ["doc:IMAGENOTE001"]
        XCTAssertEqual(result["refs"], refs)
        XCTAssertNil(result["pages"])
        XCTAssertNil(result["failed"])

        let node = try XCTUnwrap(h.library.node("IMAGENOTE001"))
        XCTAssertEqual(node.title, "Whiteboard photo")
        XCTAssertEqual(node.parent, Fixtures.folderID)
        let content = try h.app.workspace.content("IMAGENOTE001")
        XCTAssertEqual(content.meta.kind, .notebook)
        XCTAssertFalse(content.meta.coverEnabled)
        let pages = content.livePages
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.map { $0.background.kind }, [.image, .image])
        XCTAssertEqual(pages[0].size?.width ?? 0, 595.28, accuracy: 0.001)
        XCTAssertEqual(pages[0].size?.height ?? 0, 1190.56, accuracy: 0.011)
        XCTAssertEqual(pages[1].size?.width ?? 0, 841.89, accuracy: 0.001)
        XCTAssertEqual(pages[1].size?.height ?? 0, 420.945, accuracy: 0.011)
        let asset = try XCTUnwrap(pages[0].background.asset)
        XCTAssertEqual(try h.assets.data(asset, doc: "IMAGENOTE001"), try Data(contentsOf: tall))
        XCTAssertEqual(h.undoDepth("IMAGENOTE001"), 0, "a new document's first pages are not an undo step")
    }

    func testImagesGoAfterTheAnchorInFileOrderAsOneUndoStep() async throws {
        let h = harness()
        let dir = try tempDir()
        let first = try writePNG("first.png", in: dir)
        let second = try writePNG("second.png", in: dir, width: 40, height: 40)
        let before = try livePages(h)
        let anchor = try XCTUnwrap(before.firstIndex(of: Fixtures.page1))
        let result = try await h.run("import.files", ["urls": urls([first, second]), "doc": "doc:FIXTUREDOC01",
                                                      "position": "after", "anchor": "page:FIXTUREDOC01/FIXTUREPG001",
                                                      "ids": ["IMGPAGE00001", "IMGPAGE00002"]])
        let refs: JSONValue = ["doc:FIXTUREDOC01"]
        let pages: JSONValue = ["page:FIXTUREDOC01/IMGPAGE00001", "page:FIXTUREDOC01/IMGPAGE00002"]
        XCTAssertEqual(result["refs"], refs)
        XCTAssertEqual(result["pages"], pages)
        var expected = before
        expected.insert(contentsOf: ["IMGPAGE00001", "IMGPAGE00002"], at: anchor + 1)
        XCTAssertEqual(try livePages(h), expected)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try livePages(h), before)
    }

    func testSeparateFilesKeepTheirOrderInTheDocument() async throws {
        let h = harness()
        h.app.content.importers.register(ImporterDescriptor(id: "test.page", title: "One page", fileExtensions: ["onepage"],
                                                            owner: "test") { _, target, ctx in
            guard let doc = target.document else { return [] }
            let live = try ctx.workspace.content(doc).livePages
            let key = PageSlot.keys(live, target.position, anchor: target.anchorPage, count: 1)[0]
            let id = target.ids?.first ?? NibID.make()
            try ctx.mutate { tx in _ = try tx.put(PageRecord(id: id, order: key, size: .a4), doc: doc) }
            return [doc]
        })
        let dir = try tempDir()
        let a = dir.appendingPathComponent("a.onepage")
        let b = dir.appendingPathComponent("b.onepage")
        let image = try writePNG("c.png", in: dir)
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let before = try livePages(h)
        let result = try await h.run("import.files", ["urls": urls([a, image, b]), "doc": "doc:FIXTUREDOC01",
                                                      "position": "start", "ids": ["PAGEA", "PAGEC", "PAGEB"]])
        let pages: JSONValue = ["page:FIXTUREDOC01/PAGEA", "page:FIXTUREDOC01/PAGEC", "page:FIXTUREDOC01/PAGEB"]
        XCTAssertEqual(result["pages"], pages)
        XCTAssertEqual(try livePages(h), ["PAGEA", "PAGEC", "PAGEB"] + before)
    }

    func testBeforeWithoutAnAnchorUsesTheUsersCurrentPage() async throws {
        let h = harness()
        h.session.page = Fixtures.page2
        let dir = try tempDir()
        let image = try writePNG("scan.png", in: dir)
        let before = try livePages(h)
        let result = try await h.run("import.files", ["urls": urls([image]), "doc": "doc:FIXTUREDOC01", "position": "before",
                                                      "ids": ["BEFOREPAGE01"]])
        XCTAssertEqual(result["pages"], ["page:FIXTUREDOC01/BEFOREPAGE01"] as JSONValue)
        var expected = before
        expected.insert("BEFOREPAGE01", at: try XCTUnwrap(before.firstIndex(of: Fixtures.page2)))
        XCTAssertEqual(try livePages(h), expected)
    }

    func testImagesOnlyBecomePagesOfNotebooks() async throws {
        let h = harness()
        let image = try writePNG("scan.png", in: try tempDir())
        await expectError(.unsupported) {
            _ = try await h.run("import.files", ["urls": urls([image]), "doc": "doc:FIXTUREDOC02"])
        }
        XCTAssertEqual(h.undoDepth(Fixtures.textDocID), 0)
    }

    func testExistingIDsAreConflicts() async throws {
        let h = harness()
        let image = try writePNG("scan.png", in: try tempDir())
        await expectError(.conflict) {
            _ = try await h.run("import.files", ["urls": urls([image]), "folder": "lib", "ids": ["FIXTUREDOC01"]])
        }
        await expectError(.conflict) {
            _ = try await h.run("import.files", ["urls": urls([image]), "doc": "doc:FIXTUREDOC01", "ids": ["FIXTUREPG002"]])
        }
    }

    // MARK: Folders, archives and other importers

    func testZipOfTwoFoldersRecreatesBoth() async throws {
        let h = harness()
        let root = try tempDir()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try writePNG("Physics/Waves.png", in: source)
        try writePNG("Chemistry/Atoms.png", in: source)
        try writePNG("Chemistry/Bonds.png", in: source, width: 50, height: 10)
        try Data("?".utf8).write(to: source.appendingPathComponent("Chemistry/notes.xyz"))
        let zip = root.appendingPathComponent("Science.zip")
        try ArchiveIO.archive(contentsOf: source, to: zip)

        let result = try await h.run("import.files", ["urls": urls([zip]), "folder": "lib"])
        let top = h.library.children(of: nil).filter { $0.kind == .folder }
        let physics = try XCTUnwrap(top.first { $0.title == "Physics" })
        let chemistry = try XCTUnwrap(top.first { $0.title == "Chemistry" })
        XCTAssertEqual(h.library.children(of: physics.id).filter { $0.kind == .document }.map { $0.title }, ["Waves"])
        let chemistryDocs = h.library.children(of: chemistry.id).filter { $0.kind == .document }
        XCTAssertEqual(chemistryDocs.map { $0.title }, ["Atoms"], "a run of images is one notebook")
        XCTAssertEqual(try h.app.workspace.content(chemistryDocs[0].id).livePages.count, 2)
        XCTAssertEqual(result["refs"]?.arrayValue?.count, 2)
        let folders = Set((result["folders"]?.arrayValue ?? []).compactMap { $0.stringValue })
        XCTAssertEqual(folders, ["folder:" + physics.id.raw, "folder:" + chemistry.id.raw])
    }

    func testFolderImportKeepsItsTree() async throws {
        let h = harness()
        let root = try tempDir()
        let trip = root.appendingPathComponent("Trip", isDirectory: true)
        try writePNG("map.png", in: trip)
        try writePNG("Day 1/beach.png", in: trip)
        let result = try await h.run("import.files", ["urls": urls([trip]), "folder": "folder:FIXTUREFLD01"])
        let tripFolder = try XCTUnwrap(h.library.children(of: Fixtures.folderID).first { $0.kind == .folder && $0.title == "Trip" })
        let day = try XCTUnwrap(h.library.children(of: tripFolder.id).first { $0.kind == .folder })
        XCTAssertEqual(day.title, "Day 1")
        XCTAssertEqual(h.library.children(of: tripFolder.id).filter { $0.kind == .document }.map { $0.title }, ["map"])
        XCTAssertEqual(h.library.children(of: day.id).filter { $0.kind == .document }.map { $0.title }, ["beach"])
        XCTAssertEqual(result["folders"]?.arrayValue?.count, 2)
    }

    func testFoldersCannotGoIntoADocument() async throws {
        let h = harness()
        let trip = try tempDir().appendingPathComponent("Trip", isDirectory: true)
        try writePNG("map.png", in: trip)
        await expectError(.unsupported) {
            _ = try await h.run("import.files", ["urls": urls([trip]), "doc": "doc:FIXTUREDOC01"])
        }
    }

    func testRegisteredImportersGetTheOriginalNameTargetAndIDs() async throws {
        let h = harness()
        var seen: [(url: URL, target: ImportTarget)] = []
        h.app.content.importers.register(ImporterDescriptor(id: "test.fake", title: "Fake", fileExtensions: ["fake"],
                                                            owner: "test") { url, target, ctx in
            seen.append((url, target))
            let library = try ctx.services.require(ctx.services.library, "the library")
            let meta = DocumentMeta(id: target.ids?.first ?? NibID.make(), kind: .notebook)
            return [try library.createDocument(DocumentContent(meta: meta, pages: [PageRecord()]),
                                               title: target.displayName ?? "?", in: target.folder)]
        })
        let dir = try tempDir()
        let third = dir.appendingPathComponent("Lecture 3.fake")
        let fourth = dir.appendingPathComponent("Lecture 4.fake")
        try Data("3".utf8).write(to: third)
        try Data("4".utf8).write(to: fourth)
        let result = try await h.run("import.files", ["urls": urls([third, fourth]), "folder": "folder:FIXTUREFLD01",
                                                      "ids": ["FAKEDOC00001", "FAKEDOC00002"]])
        XCTAssertEqual(result["refs"], ["doc:FAKEDOC00001", "doc:FAKEDOC00002"] as JSONValue)
        XCTAssertEqual(seen.map { $0.url.lastPathComponent }, ["Lecture 3.fake", "Lecture 4.fake"])
        XCTAssertEqual(seen.map { $0.target.displayName }, ["Lecture 3", "Lecture 4"])
        XCTAssertEqual(seen.map { $0.target.ids ?? [] }, [["FAKEDOC00001", "FAKEDOC00002"], ["FAKEDOC00002"]])
        XCTAssertEqual(seen.map { $0.target.folder }, [Fixtures.folderID, Fixtures.folderID])
        XCTAssertEqual(h.library.node("FAKEDOC00002")?.title, "Lecture 4")
        // The staged copies are gone once the import returns.
        XCTAssertFalse(seen.contains { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testTemporaryAssetsImportUnderTheirNames() async throws {
        let h = harness()
        var names: [String] = []
        h.app.content.importers.register(ImporterDescriptor(id: "test.fake", title: "Fake", fileExtensions: ["fake"],
                                                            owner: "test") { url, target, _ in
            names.append(target.displayName ?? url.lastPathComponent)
            return []
        })
        let ref = try h.assets.putTemporary(Data("x".utf8), ext: "fake")
        let result = try await h.run("import.files", ["urls": [.string("tmp:" + ref.name)], "folder": "lib"])
        XCTAssertEqual(result["refs"], [] as JSONValue)
        XCTAssertEqual(names, [(ref.name as NSString).deletingPathExtension])
    }

    // MARK: Failures and permissions

    func testPartialFailuresAreListedPerFile() async throws {
        let h = harness()
        let dir = try tempDir()
        let good = try writePNG("good.png", in: dir)
        let missing = dir.appendingPathComponent("missing.png")
        let odd = dir.appendingPathComponent("data.xyz")
        try Data("?".utf8).write(to: odd)
        let result = try await h.run("import.files", ["urls": urls([good, missing, odd]), "folder": "lib"])
        XCTAssertEqual(result["refs"]?.arrayValue?.count, 1)
        let failed = result["failed"]?.arrayValue ?? []
        XCTAssertEqual(failed.count, 2)
        XCTAssertEqual(failed.first?["url"]?.stringValue, missing.absoluteString)
        XCTAssertEqual(failed.first?["code"]?.stringValue, "not_found")
        XCTAssertEqual(failed.last?["code"]?.stringValue, "unsupported")
    }

    func testNothingImportedThrowsTheReason() async throws {
        let h = harness()
        let odd = try tempDir().appendingPathComponent("data.xyz")
        try Data("?".utf8).write(to: odd)
        await expectError(.unsupported) {
            _ = try await h.run("import.files", ["urls": urls([odd]), "folder": "lib"])
        }
    }

    func testOtherCallersCannotReadArbitraryFiles() async throws {
        let h = harness()
        let hosts = URL(fileURLWithPath: "/etc/hosts").absoluteString
        await expectError(.permissionDenied, path: "$.urls[0]") {
            _ = try await h.run("import.files", ["urls": [.string(hosts)], "folder": "lib"], as: .ai("chat"))
        }
        await expectError(.permissionDenied) {
            _ = try await h.run("import.files", ["urls": [.string(ShareHandoff.link)], "folder": "lib"], as: .ai("chat"))
        }
    }

    func testDestinationsAreChecked() async throws {
        let h = harness()
        let image = try writePNG("scan.png", in: try tempDir())
        let file: JSONValue = urls([image])
        await expectError(.notFound, path: "$.folder") {
            _ = try await h.run("import.files", ["urls": file, "folder": "folder:NOSUCHFOLDER"])
        }
        await expectError(.notFound, path: "$.doc") {
            _ = try await h.run("import.files", ["urls": file, "doc": "doc:NOSUCHDOC001"])
        }
        await expectError(.notFound, path: "$.anchor") {
            _ = try await h.run("import.files", ["urls": file, "doc": "doc:FIXTUREDOC01", "anchor": "page:FIXTUREDOC01/NOSUCHPAGE"])
        }
        await expectError(.invalidParams, path: "$.anchor") {
            _ = try await h.run("import.files", ["urls": file, "doc": "doc:FIXTUREDOC04", "position": "after"])
        }
        await expectError(.invalidParams, path: "$.urls") {
            _ = try await h.run("import.files", ["urls": []])
        }
        await expectError(.invalidParams, path: "$.ids[0]") {
            _ = try await h.run("import.files", ["urls": file, "folder": "lib", "ids": ["not valid"]])
        }
        XCTAssertEqual(h.undoDepths(), [Fixtures.docID: 0, Fixtures.textDocID: 0, Fixtures.studySetID: 0, Fixtures.whiteboardID: 0])
    }

    func testDryRunChangesNothing() async throws {
        let h = harness()
        let image = try writePNG("scan.png", in: try tempDir())
        let before = try h.snapshotAll()
        let nodes = h.library.allNodes().count
        let intoDoc = try await h.app.bus.execute(Invocation(command: "import.files",
                                                             params: ["urls": urls([image]), "doc": "doc:FIXTUREDOC01"],
                                                             session: h.session, dryRun: true))
        XCTAssertEqual(intoDoc.value["refs"], [] as JSONValue)
        let asNew = try await h.app.bus.execute(Invocation(command: "import.files", params: ["urls": urls([image]), "folder": "lib"],
                                                           session: h.session, dryRun: true))
        XCTAssertEqual(asNew.value["refs"], [] as JSONValue)
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.library.allNodes().count, nodes)
    }

    func testPickNeedsAWindow() async throws {
        let h = harness()
        await expectError(.unavailable) { _ = try await h.run("import.pick", [:]) }
        await expectError(.invalidParams, path: "$.target") {
            _ = try await h.run("import.pick", ["target": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"])
        }
    }

    // MARK: Dialog model from the library

    func testDialogOffersTheOpenNotebookOnlyForPageFormats() throws {
        let h = harness()
        let pages = ImportDialogModel.make(library: h.library, workspace: h.app.workspace, session: h.session,
                                           names: ["a.pdf", "b.png"], preset: nil)
        let current = try XCTUnwrap(pages.current)
        XCTAssertEqual(current.id, Fixtures.docID)
        XCTAssertEqual(current.title, "Fixture Notebook")
        XCTAssertEqual(current.page, Fixtures.page1)
        XCTAssertEqual(current.pageNumber, (try livePages(h).firstIndex(of: Fixtures.page1) ?? 0) + 1)
        XCTAssertEqual(pages.positions, [.before, .after, .end])
        XCTAssertTrue(pages.folders.contains { $0.folder == Fixtures.folderID && $0.title == "Fixtures" })

        let mixed = ImportDialogModel.make(library: h.library, workspace: h.app.workspace, session: h.session,
                                           names: ["a.pdf", "Backup.zip"], preset: nil)
        XCTAssertNil(mixed.current)

        h.session.document = Fixtures.textDocID
        let textDoc = ImportDialogModel.make(library: h.library, workspace: h.app.workspace, session: h.session,
                                             names: ["a.pdf"], preset: nil)
        XCTAssertNil(textDoc.current)

        let preset = ImportDialogModel.make(library: h.library, workspace: h.app.workspace, session: h.session,
                                            names: ["a.pdf"], preset: ImportDestination(folder: Fixtures.folderID))
        XCTAssertEqual(preset.presetSummary, "New documents go into “Fixtures”.")
        XCTAssertEqual(preset.folder, Fixtures.folderID)
    }
}
