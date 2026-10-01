import XCTest
import SwiftUI
import NibContracts
import NibDesign
import NibTesting
@testable import FeatTeacher

@MainActor
final class LessonManagerTests: XCTestCase {
    private func harness() -> Harness { Harness(features: [FeatTeacherFeature.self, FeatTeacherLessonsFeature.self]) }

    private func source(_ h: Harness, id: DocumentID = "LESSONSOURCE01") throws -> (DocumentID, PageID, ElementID, AssetRef) {
        let image = try h.assets.put(Fixtures.pngData, ext: "png", doc: id)
        let page = PageRecord(id: "LESSONPAGE01", order: "V", size: .a4, background: .ofImage(image))
        var meta = DocumentMeta(id: id, kind: .notebook)
        meta.sourceBookmark = Data("external-source".utf8)
        let content = DocumentContent(meta: meta, pages: [page])
        _ = try h.library.createDocument(content, title: "Motion", in: Fixtures.folderID)
        let item = Item(id: "LESSONITEM01", kind: .image, z: "V",
                        image: ImageItem(frame: Frame(x: 40, y: 40, w: 64, h: 64), asset: image))
        h.persistence.pageItems[id] = [page.id: [item]]
        return (id, page.id, item.id, image)
    }

    func testCSVQuotedNamesBOMCRLFAndStableIdentity() throws {
        let csv = "\u{FEFF}student_id,first_name,last_name,email\r\nsam,\"Sam, Jr.\",\"O\"\"Brien\",SAM@example.org\r\nlee,Lee,Chen,\r\n"
        let students = try RosterImport.parse(csv)
        XCTAssertEqual(students, [LessonStudent(id: "sam", name: "Sam, Jr. O\"Brien", email: "sam@example.org"),
                                  LessonStudent(id: "lee", name: "Lee Chen", email: nil)])
        let multiline = try RosterImport.parse("name,email\n\"Sam\nTaylor\",sam@example.org\n")
        XCTAssertEqual(multiline.first?.name, "Sam\nTaylor")
        XCTAssertEqual(multiline.first?.id, RosterImport.stableID("SAM@example.org"))
    }

    func testCSVRejectsAmbiguousAndMalformedRows() throws {
        for csv in ["name\nSam\nSam", "name,name\nSam,Lee", "id,name\nsam,Sam\nsam,Lee", "name,email\nSam,x",
                    "name,email\nSam,sam@example.org\nLee,SAM@example.org", "name,email\n\"Sam,Lee", "name\n\"Sam\"text",
                    "name,email\nSam,sam@example.org,extra", "name\n"] {
            XCTAssertThrowsError(try RosterImport.parse(csv), csv) { error in
                XCTAssertEqual((error as? NibError)?.code, .invalidParams)
            }
        }
        let sameName = try RosterImport.parse("id,name\none,Sam\ntwo,Sam")
        XCTAssertEqual(sameName.count, 2)
    }

    func testRosterImportReplacementUsesOneSyncedDocumentAndUndo() async throws {
        let h = harness()
        let first = try await h.run(CommandIDs.lessonImportRoster, ["csv": "id,name,email\nsam,Sam,sam@example.org", "folder": "folder:FIXTUREFLD01"])
        let ref = try XCTUnwrap(first["ref"]?.stringValue)
        let doc = NodeRef.documentID(from: ref)
        XCTAssertEqual(doc, LessonManager.rosterID(Fixtures.folderID))
        let old = try h.app.workspace.content(doc).meta.ext?[LessonManager.rosterKey]
        let second = try await h.run(CommandIDs.lessonImportRoster, ["csv": "id,name,email\nlee,Lee,lee@example.org", "folder": "folder:FIXTUREFLD01"])
        XCTAssertEqual(second["ref"]?.stringValue, ref)
        XCTAssertEqual(h.library.children(of: Fixtures.folderID).filter { $0.id == doc }.count, 1)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.app.workspace.content(doc).meta.ext?[LessonManager.rosterKey], old)
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertEqual(try h.app.workspace.content(doc).meta.ext?[LessonManager.rosterKey]?.decode(LessonRoster.self).students.first?.id, "lee")
        // The roster follows its folder, including archive moves.
        let archive = try h.library.createFolder(title: "Archive", in: nil, style: nil)
        try h.library.move(Fixtures.folderID, to: archive)
        XCTAssertEqual(h.library.node(doc)?.parent, Fixtures.folderID)
    }

    func testLessonCopiesCallerIDsAssetsAndIndependentWorkOnTempLibrary() async throws {
        let h = harness()
        let (doc, page, item, asset) = try source(h)
        let before = try LessonManager.capture(doc, workspace: h.app.workspace)
        try await h.run(CommandIDs.lessonImportRoster, ["csv": "id,name\nsam,Sam\nlee,Lee", "folder": "folder:FIXTUREFLD01"])
        let output = try await h.run(CommandIDs.lessonCreate, ["doc": .string(doc.raw), "folder": "folder:FIXTUREFLD01", "ids": ["SAMCOPY01", "LEECOPY01"]])
        XCTAssertEqual(output["refs"], ["doc:SAMCOPY01", "doc:LEECOPY01"])
        for copy: DocumentID in ["SAMCOPY01", "LEECOPY01"] {
            XCTAssertEqual(h.library.node(copy)?.parent, Fixtures.folderID)
            let content = try h.app.workspace.content(copy)
            XCTAssertNil(content.meta.sourceBookmark)
            XCTAssertEqual(content.livePages.first?.id, page)
            let record = try XCTUnwrap(LessonManager.assignment(content.meta))
            XCTAssertEqual(record.source, doc)
            XCTAssertEqual(record.state, .published)
            XCTAssertEqual(record.attempt, 1)
            let copied = try h.app.workspace.item(copy, page: page, id: item)
            XCTAssertEqual(try h.assets.data(try XCTUnwrap(copied.image?.asset), doc: copy), Fixtures.pngData)
            XCTAssertEqual(try h.assets.data(try XCTUnwrap(content.livePages.first?.background.asset), doc: copy), Fixtures.pngData)
            XCTAssertNotNil(copied.createdBy)
        }
        XCTAssertEqual(try h.assets.data(asset, doc: doc), Fixtures.pngData)
        XCTAssertEqual(try LessonManager.capture(doc, workspace: h.app.workspace), before)
        let new = Item(id: "STUDENTWORK01", kind: .text, text: TextBoxItem(frame: Frame(x: 40, y: 160, w: 300, h: 50), text: RichText(plain: "6 m/s")))
        try await h.insert([new], page: page, doc: "SAMCOPY01")
        XCTAssertFalse(try h.app.workspace.items("LEECOPY01", page: page).contains { $0.id == new.id })
        try await h.run(CommandIDs.lessonCreate, ["action": "trash", "ids": ["SAMCOPY01", "LEECOPY01"]])
        XCTAssertNotNil(h.library.node("SAMCOPY01")?.trashedAt)
        try await h.run(CommandIDs.lessonCreate, ["action": "restore", "ids": ["SAMCOPY01", "LEECOPY01"]])
        XCTAssertNil(h.library.node("SAMCOPY01")?.trashedAt)
        XCTAssertTrue(try h.app.workspace.items("SAMCOPY01", page: page).contains { $0.id == new.id })
    }

    func testAssignmentReturnSnapshotRemainsImmutableAndUndoRedo() async throws {
        let h = harness()
        let (doc, page, _, _) = try source(h)
        try await h.run(CommandIDs.lessonCreate, ["doc": .string(doc.raw), "folder": "folder:FIXTUREFLD01", "students": ["Sam"], "ids": ["SAMCOPY01"]])
        let copy: DocumentID = "SAMCOPY01"
        try await h.run(CommandIDs.lessonSetState, ["doc": "doc:SAMCOPY01", "state": "submitted"])
        let submitted = try LessonManager.capture(copy, workspace: h.app.workspace)
        let returned = try await h.run(CommandIDs.lessonSetState, ["doc": "doc:SAMCOPY01", "state": "returned"])
        let name = try XCTUnwrap(returned["snapshot"]?.stringValue)
        let bytes = try h.assets.data(AssetRef(name), doc: copy)
        XCTAssertEqual(try JSONDecoder().decode(LessonSnapshot.self, from: bytes), submitted)
        XCTAssertTrue(h.app.bus.undo(copy))
        XCTAssertEqual(try LessonManager.assignment(h.app.workspace.content(copy).meta)?.state, .submitted)
        XCTAssertTrue(h.app.bus.redo(copy))
        XCTAssertEqual(try LessonManager.assignment(h.app.workspace.content(copy).meta)?.returns.count, 1)
        try await h.run(CommandIDs.lessonSetState, ["doc": "doc:SAMCOPY01", "state": "returned"])
        XCTAssertEqual(try LessonManager.assignment(h.app.workspace.content(copy).meta)?.returns.count, 1)
        try await h.run(CommandIDs.lessonSetState, ["doc": "doc:SAMCOPY01", "state": "resubmit"])
        try await h.insert([Item(kind: .text, text: TextBoxItem(frame: Frame(x: 40, y: 250, w: 300, h: 40), text: RichText(plain: "Revised answer")))], page: page, doc: copy)
        try await h.run(CommandIDs.lessonSetState, ["doc": "doc:SAMCOPY01", "state": "submitted"])
        try await h.run(CommandIDs.lessonSetState, ["doc": "doc:SAMCOPY01", "state": "returned"])
        let record = try XCTUnwrap(LessonManager.assignment(h.app.workspace.content(copy).meta))
        XCTAssertEqual(record.attempt, 2)
        XCTAssertEqual(record.returns.map(\.attempt), [1, 2])
        XCTAssertEqual(try h.assets.data(AssetRef(name), doc: copy), bytes)
    }

    func testInvalidStateLockedSourceAndCollisionMakeNoChanges() async throws {
        let h = harness()
        let (doc, _, _, _) = try source(h)
        let before = try LessonManager.capture(doc, workspace: h.app.workspace)
        do {
            try await h.run(CommandIDs.lessonSetState, ["doc": .string(doc.raw), "state": "returned"])
            XCTFail("unpublished document returned")
        } catch { XCTAssertEqual((error as? NibError)?.code, .conflict) }
        h.app.services.lock = FakeLockService(locked: [doc])
        do {
            try await h.run(CommandIDs.lessonCreate, ["doc": .string(doc.raw), "folder": "folder:FIXTUREFLD01", "students": ["Sam"]])
            XCTFail("locked source copied")
        } catch { XCTAssertEqual((error as? NibError)?.code, .locked) }
        h.app.services.lock = nil
        do {
            try await h.run(CommandIDs.lessonCreate, ["doc": .string(doc.raw), "folder": "folder:FIXTUREFLD01", "students": ["Sam"], "ids": [.string(doc.raw)]])
            XCTFail("existing id overwritten")
        } catch { XCTAssertEqual((error as? NibError)?.code, .invalidParams) }
        XCTAssertEqual(try LessonManager.capture(doc, workspace: h.app.workspace), before)
    }

    func testDryRunsDoNotCreateDocumentsSnapshotsOrPrivateStores() async throws {
        let h = harness()
        let (doc, _, _, _) = try source(h)
        let nodes = h.library.allNodes()
        let before = try h.app.workspace.content(doc)
        let previews: [(String, JSONValue)] = [
            (CommandIDs.lessonCreate, ["doc": .string(doc.raw), "folder": "folder:FIXTUREFLD01", "students": ["Sam"]]),
            (CommandIDs.lessonImportRoster, ["csv": "name\nSam", "folder": "folder:FIXTUREFLD01"]),
            (CommandIDs.lessonSetState, ["doc": .string(doc.raw), "state": "present"])]
        for (command, params) in previews {
            _ = try await h.app.bus.execute(Invocation(command: command, params: params, session: h.session, dryRun: true))
        }
        XCTAssertEqual(h.library.allNodes(), nodes)
        XCTAssertEqual(try h.app.workspace.content(doc), before)
        XCTAssertTrue(h.app.workspace.persistence === h.persistence)
        XCTAssertEqual(h.undoDepth(doc), 0)
    }

    func testPrivatePresentNotesPersistLocallyAndCannotBeShared() async throws {
        let h = harness()
        let (doc, page, _, _) = try source(h)
        let initial = try LessonManager.capture(doc, workspace: h.app.workspace)
        let output = try await h.run(CommandIDs.lessonSetState, ["doc": .string(doc.raw), "state": "present"])
        let privateDoc = NodeRef.documentID(from: try XCTUnwrap(output["ref"]?.stringValue))
        XCTAssertTrue(LessonManager.isPrivate(privateDoc))
        XCTAssertNil(h.library.node(privateDoc))
        XCTAssertEqual(h.session.activeLayer, LessonManager.presentLayer)
        let secret = Item(id: "PRIVATENOTE01", kind: .text, layer: LessonManager.presentLayer,
                          text: TextBoxItem(frame: Frame(x: 40, y: 180, w: 300, h: 40), text: RichText(plain: "Teacher reminder")))
        try await h.insert([secret], page: page, doc: privateDoc)
        h.app.workspace.close(privateDoc)
        let store = try XCTUnwrap(h.app.workspace.persistence as? PrivateLessonPersistence)
        h.app.workspace.persistence = PrivateLessonPersistence(base: h.persistence, root: store.root)
        XCTAssertTrue(try h.app.workspace.items(privateDoc, page: page).contains { $0.id == secret.id })
        XCTAssertTrue(h.app.bus.undo(privateDoc))
        XCTAssertFalse(try h.app.workspace.items(privateDoc, page: page).contains { $0.id == secret.id })
        XCTAssertTrue(h.app.bus.redo(privateDoc))
        XCTAssertEqual(try LessonManager.capture(doc, workspace: h.app.workspace), initial)
        // A registered dependency is guarded before its handler runs, including typed and JSON calls.
        h.app.commands.register(CommandDescriptor(id: CommandIDs.collabHost, title: "Host", summary: "Test live host", effect: .library)) { _, _ in
            XCTFail("private notes reached transport"); return [:]
        }
        do {
            try await h.run(CommandIDs.collabHost, ["doc": .string(NodeRef.document(privateDoc).description)])
            XCTFail("private presentation shared")
        } catch { XCTAssertEqual((error as? NibError)?.code, .permissionDenied) }
        try await h.run(CommandIDs.lessonSetState, ["doc": .string(NodeRef.document(privateDoc).description), "state": "prep"])
        XCTAssertEqual(h.session.document, doc)
        XCTAssertEqual(h.session.activeLayer, LessonManager.prepLayer)
        let shared = Item(id: "NEWPREPNOTE01", kind: .text, text: TextBoxItem(frame: Frame(x: 40, y: 300, w: 300, h: 40), text: RichText(plain: "Shared preparation update")))
        try await h.insert([shared], page: page, doc: doc)
        try await h.run(CommandIDs.lessonSetState, ["doc": .string(doc.raw), "state": "present"])
        let refreshed = try h.app.workspace.items(privateDoc, page: page)
        XCTAssertTrue(refreshed.contains { $0.id == shared.id })
        XCTAssertTrue(refreshed.contains { $0.id == secret.id })
        let copy = try await h.run(CommandIDs.lessonCreate, ["doc": .string(doc.raw), "folder": "folder:FIXTUREFLD01", "students": ["Sam"]])
        let copyID = NodeRef.documentID(from: try XCTUnwrap(copy["refs"]?[0]?.stringValue))
        XCTAssertFalse(try h.app.workspace.items(copyID, page: page).contains { $0.id == secret.id })
    }

    func testLibraryWindowUndoRedoForCopiesAndRosterReplacement() async throws {
        let h = harness()
        let (doc, _, _, _) = try source(h)
        let runtime = try XCTUnwrap(h.app.services.get(LessonRuntime.key, as: LessonRuntime.self))
        let undo = runtime.fallbackUndo
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await h.run(CommandIDs.lessonCreate, ["doc": .string(doc.raw), "folder": "folder:FIXTUREFLD01", "students": ["Sam"], "ids": ["WINDOWCOPY01"]])
        undo.endUndoGrouping()
        await windowAction(h, action: { undo.undo() })
        XCTAssertNotNil(h.library.node("WINDOWCOPY01")?.trashedAt)
        await windowAction(h, action: { undo.redo() })
        XCTAssertNil(h.library.node("WINDOWCOPY01")?.trashedAt)
        undo.beginUndoGrouping()
        try await h.run(CommandIDs.lessonImportRoster, ["csv": "id,name\nsam,Sam", "folder": "folder:FIXTUREFLD01"])
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        try await h.run(CommandIDs.lessonImportRoster, ["csv": "id,name\nlee,Lee", "folder": "folder:FIXTUREFLD01"])
        undo.endUndoGrouping()
        let roster = LessonManager.rosterID(Fixtures.folderID)
        await windowAction(h, action: { undo.undo() })
        XCTAssertEqual(try h.app.workspace.content(roster).meta.ext?[LessonManager.rosterKey]?.decode(LessonRoster.self).students.first?.id, "sam")
        await windowAction(h, action: { undo.redo() })
        XCTAssertEqual(try h.app.workspace.content(roster).meta.ext?[LessonManager.rosterKey]?.decode(LessonRoster.self).students.first?.id, "lee")
    }

    private func windowAction(_ h: Harness, action: () -> Void) async {
        let completed = expectation(description: "library undo command completed")
        let subscription = h.app.events.subscribe { event in
            if event.type == NibEventType.libraryChanged { completed.fulfill() }
        }
        defer { subscription.cancel() }
        action()
        await fulfillment(of: [completed], timeout: 5)
    }

    func testRosterURLImportAndCopyFailureRollsBackCreatedPackages() async throws {
        let h = harness()
        let file = h.persistence.root.appendingPathComponent("roster.csv")
        try FileManager.default.createDirectory(at: h.persistence.root, withIntermediateDirectories: true)
        try Data("id,name\nsam,Sam".utf8).write(to: file)
        let result = try await h.run(CommandIDs.lessonImportRoster, ["url": .string(file.absoluteString), "folder": "folder:FIXTUREFLD01"])
        XCTAssertEqual(result["students"]?[0]?["id"]?.stringValue, "sam")
        let (doc, _, _, _) = try source(h)
        h.app.services.assets = FailingLessonAssets(base: h.assets, refused: "FAILCOPY02")
        do {
            try await h.run(CommandIDs.lessonCreate, ["doc": .string(doc.raw), "folder": "folder:FIXTUREFLD01", "students": ["Sam", "Lee"], "ids": ["FAILCOPY01", "FAILCOPY02"]])
            XCTFail("asset write failure should abort the lesson")
        } catch { XCTAssertEqual((error as? NibError)?.code, .unavailable) }
        XCTAssertNil(h.library.node("FAILCOPY01"))
        XCTAssertNil(h.library.node("FAILCOPY02"))
        XCTAssertEqual(h.undoDepth("FAILCOPY01"), 0)
    }

    func testSampleLessonIncludesQuestionAnswerZoneAndTeacherHints() async throws {
        let h = harness()
        let value = try await h.run(CommandIDs.lessonCreate, ["doc": "sample", "folder": "folder:FIXTUREFLD01", "students": [], "ids": ["SAMPLE01"]])
        XCTAssertEqual(value["refs"], ["doc:SAMPLE01"])
        let content = try h.app.workspace.content("SAMPLE01")
        let page = try XCTUnwrap(content.livePages.first)
        let items = try h.app.workspace.items("SAMPLE01", page: page.id)
        let zone = try XCTUnwrap(items.compactMap(AnswerZone.decode).first)
        XCTAssertEqual(zone.points, 3)
        XCTAssertEqual(zone.hints.count, 2)
        XCTAssertTrue(items.contains { $0.text?.text.plainText.contains("120 metres") == true })
    }

    func testCommandsConformAndPanelRendersAtPhoneAndIPadSizes() async throws {
        let issues = await CommandConformance.check(features: [FeatTeacherFeature.self, FeatTeacherLessonsFeature.self], owners: [FeatTeacherLessonsFeature.id])
        XCTAssertEqual(issues, [])
        let h = harness()
        let panel = try XCTUnwrap(h.app.ui.panels.get(FeatTeacherLessonsFeature.panelID))
        let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        for width: CGFloat in [390, 768] {
            for variant in NibSnapshot.Variant.allCases {
                let image = NibSnapshot.image(panel.makeView(context), size: CGSize(width: width, height: 844), variant: variant, scale: 1)
                XCTAssertNotNil(image, "\(variant) \(width)")
                if let image {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Teacher Toolkit \(variant.rawValue) \(width)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        let reduced = panel.makeView(context).environment(\.nibLiquidMode, .off)
        XCTAssertNotNil(NibSnapshot.image(reduced, size: CGSize(width: 390, height: 844), variant: .largeText, scale: 1))
    }
}

private final class FailingLessonAssets: AssetStore {
    let base: AssetStore
    let refused: DocumentID
    init(base: AssetStore, refused: DocumentID) { self.base = base; self.refused = refused }
    func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef {
        if doc == refused { throw NibError.unavailable("test asset destination") }
        return try base.put(data, ext: ext, doc: doc)
    }
    func url(_ ref: AssetRef, doc: DocumentID) -> URL? { base.url(ref, doc: doc) }
    func data(_ ref: AssetRef, doc: DocumentID) throws -> Data { try base.data(ref, doc: doc) }
    func putTemporary(_ data: Data, ext: String) throws -> AssetRef { try base.putTemporary(data, ext: ext) }
    func temporaryURL(_ ref: AssetRef) -> URL? { base.temporaryURL(ref) }
}
