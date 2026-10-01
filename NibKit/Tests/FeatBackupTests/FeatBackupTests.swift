import XCTest
import Foundation
import ZIPFoundation
import NibContracts
import NibTesting
@testable import FeatBackup

@MainActor
final class FeatBackupTests: XCTestCase {
    func makeHarness() throws -> (Harness, BackupEngine, URL) {
        let harness = Harness(features: [FeatBackupFeature.self])
        let engine = try BackupEngine.resolve(harness.app.services)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-tests-" + UUID().uuidString)
        engine.store = BackupQueueStore(url: root.appendingPathComponent("queue.json"))
        return (harness, engine, root)
    }

    func installExport(_ h: Harness, exported: @escaping (String) -> Void = { _ in }) {
        h.app.commands.register(CommandDescriptor(id: CommandIDs.exportRun, title: "Test Export", summary: "Test export service", effect: .read)) { params, ctx in
            let format = params["format"]!.stringValue!
            exported(format)
            let ref = try ctx.services.assets!.putTemporary(Data("Real exported bytes".utf8), ext: format == "pdf" ? "pdf" : "nibnote")
            return ["files": .array([["asset": .string("tmp:" + ref.name), "name": .string("backup." + format)]])]
        }
    }

    func testRegistrationAndConformance() async {
        let h = Harness(features: [FeatBackupFeature.self])
        let commands = h.app.commands.all().filter { $0.owner == "backup" }
        XCTAssertEqual(Set(commands.map(\.id)), ["backup.now", "backup.manual", "backup.configure", "backup.chooseFolder", "backup.status", "backup.clearQueue"])
        XCTAssertEqual(h.app.content.backgroundTasks.get("app.nib.backup")?.kind, .processing)
        XCTAssertEqual(h.app.ui.settingsPages.get("backup.settings")?.section, .sync)
        XCTAssertTrue(h.app.commands.descriptor(CommandIDs.backupConfigure)!.sensitive)
        XCTAssertTrue(h.app.commands.descriptor(CommandIDs.backupManual)!.userPresence)
        XCTAssertTrue(h.app.commands.descriptor(CommandIDs.backupChooseFolder)!.userPresence)
        let problems = await CommandConformance.check(features: [FeatBackupFeature.self])
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func testConfigureQueueExclusionsAndCommitEvents() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        await engine.start()
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "nib", "exclusions": ["Fixture notebook"]])
        let nodes = h.library.allNodes()
        let excludedTitle = nodes.first { $0.id == Fixtures.docID }!.title
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "both", "exclusions": .array([.string(excludedTitle)])])
        XCTAssertFalse(engine.queue.entries.contains { $0.document == Fixtures.docID })
        _ = try await h.run(CommandIDs.backupClearQueue)
        XCTAssertTrue(engine.queue.entries.isEmpty)
        let (_, initialItems) = Fixtures.sampleContent()
        try await h.insert([initialItems[Fixtures.page1]![0]])
        XCTAssertTrue(engine.queue.entries.isEmpty, "Excluded documents must not be queued by commits")
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "nib", "exclusions": []])
        _ = try await h.run(CommandIDs.backupClearQueue)
        let (_, fixtureItems) = Fixtures.sampleContent()
        try await h.insert([fixtureItems[Fixtures.page1]![0]])
        XCTAssertEqual(engine.queue.entries.map(\.document), [Fixtures.docID])
        XCTAssertTrue(h.app.events.events(since: 0).contains { $0.type == NibEventType.backupStatus })
        try await engine.persist().value
    }

    func testBothFormatsWebDAVAndLockedDocumentRetry() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = FakeLockService(locked: [Fixtures.docID])
        h.app.services.lock = lock
        var formats: [String] = [], paths: [String] = []
        installExport(h) { formats.append($0) }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.webdavPut, title: "Test PUT", summary: "Test WebDAV", effect: .session)) { params, ctx in
            let file = try await ctx.inputFile(params["file"]!.stringValue!)
            XCTAssertEqual(try Data(contentsOf: file), Data("Real exported bytes".utf8))
            XCTAssertEqual(params["overwrite"], true)
            paths.append(params["path"]!.stringValue!)
            return [:]
        }
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav", "folder": "Backups"], "format": "both"])
        let result = try await h.run(CommandIDs.backupNow)
        XCTAssertEqual(result["skippedLocked"], 1)
        XCTAssertEqual(engine.queue.entries.map(\.document), [Fixtures.docID])
        XCTAssertEqual(formats.filter { $0 == "pdf" }.count, 3)
        XCTAssertEqual(formats.filter { $0 == "nibnote" }.count, 3)
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("Backups/") })
        XCTAssertFalse(paths.contains { $0.contains(Fixtures.docID.raw) })
        lock.locked = []
        _ = try await h.run(CommandIDs.backupNow)
        XCTAssertTrue(engine.queue.entries.isEmpty)
        XCTAssertNotNil(engine.queue.lastSuccess)
        let status = try await h.run(CommandIDs.backupStatus)
        XCTAssertEqual(status["state"], "ok")
    }

    func testFailedDeliveryRetainsQueueAndLaterRunRecovers() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        installExport(h)
        var fail = true
        h.app.commands.register(CommandDescriptor(id: CommandIDs.webdavPut, title: "Test PUT", summary: "Test WebDAV", effect: .session)) { _, _ in
            if fail { throw NibError.unavailable("Offline") }
            return [:]
        }
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "nib"])
        do { _ = try await h.run(CommandIDs.backupNow); XCTFail("An upload error must be reported") } catch { }
        XCTAssertEqual(engine.queue.entries.count, 4)
        XCTAssertFalse(engine.status().running)
        XCTAssertEqual(engine.status().state, "error")
        fail = false
        _ = try await h.run(CommandIDs.backupNow)
        XCTAssertTrue(engine.queue.entries.isEmpty)
    }

    func testClearDuringExportDoesNotSendOrConsumeNewQueue() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        var uploads = 0
        h.app.commands.register(CommandDescriptor(id: CommandIDs.exportRun, title: "Test Export", summary: "Test export", effect: .read)) { _, ctx in
            try await engine.clearQueue()
            let ref = try h.assets.putTemporary(Data("bytes".utf8), ext: "pdf")
            return ["files": .array([["asset": .string("tmp:" + ref.name)]])]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.webdavPut, title: "Test PUT", summary: "Test WebDAV", effect: .session)) { _, _ in uploads += 1; return [:] }
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "pdf"])
        _ = try await h.run(CommandIDs.backupNow)
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(engine.queue.entries.isEmpty)
        XCTAssertEqual(engine.status().state, "idle")
        XCTAssertNil(engine.queue.lastSuccess)
    }

    func testInvalidFolderAndHostlessPickerAreRejectedWithoutMutation() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "nib", "folder": "../Escape"])
            XCTFail("Traversal accepted")
        } catch let e as NibError { XCTAssertEqual(e.code, .invalidParams) }
        XCTAssertEqual(engine.status().configuration.destination.kind, "none")
        do { _ = try await h.run(CommandIDs.backupChooseFolder); XCTFail("Hostless picker opened") }
        catch let e as NibError { XCTAssertEqual(e.code, .unavailable) }
        let result = try await h.run(CommandIDs.backupStatus)
        XCTAssertEqual(result["folderChosen"], false)
    }

    func testAutomaticDeadlineAndSettingsUndoRedo() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        var time = 100.0, exportCount = 0
        engine.now = { Date(timeIntervalSince1970: time) }
        installExport(h) { _ in exportCount += 1 }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.webdavPut, title: "Test PUT", summary: "Test WebDAV", effect: .session)) { _, _ in [:] }
        let oldConfig = engine.status().configuration
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "pdf", "frequent": true])
        let config = engine.status().configuration
        time = 189
        _ = try await BackupExecution.$automatic.withValue(true) { try await h.run(CommandIDs.backupNow) }
        XCTAssertEqual(exportCount, 0)
        time = 190
        _ = try await BackupExecution.$automatic.withValue(true) { try await h.run(CommandIDs.backupNow) }
        XCTAssertEqual(exportCount, 4)
        XCTAssertTrue(engine.queue.entries.isEmpty)
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        BackupUndo.record(manager: manager, app: h.app, from: config, to: oldConfig)
        manager.endUndoGrouping()
        manager.undo()
        for _ in 0..<100 where engine.status().configuration != oldConfig { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(engine.status().configuration, oldConfig)
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        for _ in 0..<100 where engine.status().configuration != config { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(engine.status().configuration, config)
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "Settings undo must not pollute document history")
        try await engine.persist().value
    }

    func testUnopenedLibraryRescanFiltersOutlineFavouritesAndDeletionsButQueuesContent() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        await engine.start()
        installExport(h)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.webdavPut, title: "Test PUT", summary: "Test WebDAV", effect: .session)) { _, _ in [:] }
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "nib"])
        _ = try await h.run(CommandIDs.backupNow)
        XCTAssertTrue(engine.queue.entries.isEmpty)
        let title = h.library.node(Fixtures.docID)!.title
        var head = h.persistence.heads[Fixtures.docID]!
        head.meta.favorite.toggle()
        head.outline[0].title = "Remote outline edit"
        head.pages[0].bookmarked.toggle()
        _ = try h.library.createDocument(head, title: title, in: Fixtures.folderID)
        await engine.libraryChanged()
        XCTAssertTrue(engine.queue.entries.isEmpty, "A physical rescan must ignore favourites, bookmarks and outline edits")
        h.persistence.pageItems[Fixtures.docID]![Fixtures.page1]![0].deleted = true
        _ = try h.library.createDocument(head, title: title, in: Fixtures.folderID)
        await engine.libraryChanged()
        XCTAssertTrue(engine.queue.entries.isEmpty, "Removal-only physical changes must not trigger a new backup")
        h.persistence.pageItems[Fixtures.docID]![Fixtures.page1]![1].z = "zz"
        _ = try h.library.createDocument(head, title: title, in: Fixtures.folderID)
        await engine.libraryChanged()
        XCTAssertEqual(engine.queue.entries.map(\.document), [Fixtures.docID])
        try await engine.persist().value
    }

    func testFolderDeliveryReplacesAtomicallyAndRejectsLibraryOrSymlinkEscape() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let library = root.appendingPathComponent("Library"), destination = root.appendingPathComponent("Destination")
        for folder in [library, destination] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let bookmark = try destination.bookmarkData(options: [])
        let source = root.appendingPathComponent("source.pdf")
        try Data("first".utf8).write(to: source)
        try await BackupWriter.write(source: source, relativePath: "Backups/School/Notes.pdf", bookmark: bookmark, libraryRoot: library)
        let output = destination.appendingPathComponent("Backups/School/Notes.pdf")
        XCTAssertEqual(try Data(contentsOf: output), Data("first".utf8))
        try Data("updated".utf8).write(to: source)
        try await BackupWriter.write(source: source, relativePath: "Backups/School/Notes.pdf", bookmark: bookmark, libraryRoot: library)
        XCTAssertEqual(try Data(contentsOf: output), Data("updated".utf8))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: output.deletingLastPathComponent().path).contains { $0.hasSuffix(".partial") })
        let libraryBookmark = try library.bookmarkData(options: [])
        do { try await BackupWriter.write(source: source, relativePath: "Wrong.pdf", bookmark: libraryBookmark, libraryRoot: library); XCTFail("Library destination accepted") }
        catch let e as NibError { XCTAssertEqual(e.code, .invalidParams) }
        try fm.createSymbolicLink(at: destination.appendingPathComponent("Escape"), withDestinationURL: library)
        do { try await BackupWriter.write(source: source, relativePath: "Escape/secret.pdf", bookmark: bookmark, libraryRoot: library); XCTFail("Symlink escape accepted") }
        catch let e as NibError { XCTAssertEqual(e.code, .invalidParams) }
        XCTAssertFalse(fm.fileExists(atPath: library.appendingPathComponent("secret.pdf").path))
    }

    func testManualArchiveOmitsCachesSymlinksAndLockedPackages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-" + UUID().uuidString)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        for name in ["School/Notes.nibnote/assets", "School/Notes.nibnote/audio", "School/Notes.nibnote/caches", "Locked.nibnote", ".nib-library"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for path in ["School/Notes.nibnote/assets/image.png", "School/Notes.nibnote/audio/clip.caf", "School/Notes.nibnote/caches/thumb.png", "Locked.nibnote/secret.json", ".nib-library/prefs.json"] {
            try Data(path.utf8).write(to: root.appendingPathComponent(path))
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("secret-link"), withDestinationURL: root.appendingPathComponent("Locked.nibnote/secret.json"))
        let (head, _) = Fixtures.sampleContent()
        try JSONEncoder().encode(head).write(to: root.appendingPathComponent("School/Notes.nibnote/doc.00000001.json"))
        var lockedHead = head; lockedHead.meta.id = Fixtures.textDocID; lockedHead.meta.locked = true
        try JSONEncoder().encode(lockedHead).write(to: root.appendingPathComponent("Locked.nibnote/doc.00000001.json"))
        let progress = Progress(totalUnitCount: 1)
        let output = try await BackupWriter.archive(root: root, blocked: [], progress: progress, unlockedDocuments: [Fixtures.docID])
        defer { try? fm.removeItem(at: output) }
        let zip = try Archive(url: output, accessMode: .read)
        let paths = Set(zip.map(\.path))
        XCTAssertTrue(paths.contains("School/Notes.nibnote/assets/image.png"))
        XCTAssertTrue(paths.contains("School/Notes.nibnote/audio/clip.caf"))
        XCTAssertTrue(paths.contains(".nib-library/prefs.json"))
        XCTAssertFalse(paths.contains { $0.contains("caches") || $0.contains("Locked") || $0.contains("secret-link") })
        XCTAssertEqual(progress.fractionCompleted, 1)
        var extracted = Data()
        _ = try zip.extract(zip["School/Notes.nibnote/audio/clip.caf"]!) { extracted.append($0) }
        XCTAssertEqual(extracted, Data("School/Notes.nibnote/audio/clip.caf".utf8))
        let cancelled = Progress(totalUnitCount: 1); cancelled.cancel()
        do { _ = try await BackupWriter.archive(root: root, blocked: [], progress: cancelled); XCTFail("Cancelled archive succeeded") } catch { }
    }
}
