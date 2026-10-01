import XCTest
import Foundation
import UIKit
import ZIPFoundation
import NibContracts
import NibTesting
@testable import FeatBackup

@MainActor
final class FeatBackupTests: XCTestCase {
    func makeHarness() throws -> (Harness, BackupEngine, URL) {
        let harness = Harness(features: [FeatBackupFeature.self])
        harness.app.commands.register(CommandDescriptor(id: CommandIDs.webdavPut, title: "Test validation", summary: "Configured WebDAV", effect: .session)) { _, ctx in
            guard ctx.dryRun else { throw NibError.unavailable("Install a delivery fake") }
            return [:]
        }
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
            if ctx.dryRun { return [:] }
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
        h.app.commands.register(CommandDescriptor(id: CommandIDs.webdavPut, title: "Test PUT", summary: "Test WebDAV", effect: .session)) { _, ctx in
            if ctx.dryRun { return [:] }
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
        h.app.commands.register(CommandDescriptor(id: CommandIDs.webdavPut, title: "Test PUT", summary: "Test WebDAV", effect: .session)) { _, ctx in if !ctx.dryRun { uploads += 1 }; return [:] }
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
        XCTAssertTrue(engine.queue.isDue(at: time, frequent: true), "Enabling backup must run at the next window")
        time = 100
        _ = try await BackupExecution.$automatic.withValue(true) { try await h.run(CommandIDs.backupNow) }
        XCTAssertEqual(exportCount, 4)
        XCTAssertTrue(engine.queue.entries.isEmpty)
        // Subsequent edits respect the interval measured from the successful initial pass.
        await engine.start()
        let (_, items) = Fixtures.sampleContent()
        try await h.insert([items[Fixtures.page1]![0]])
        time = 189
        _ = try await BackupExecution.$automatic.withValue(true) { try await h.run(CommandIDs.backupNow) }
        XCTAssertEqual(exportCount, 4)
        time = 190
        _ = try await BackupExecution.$automatic.withValue(true) { try await h.run(CommandIDs.backupNow) }
        XCTAssertEqual(exportCount, 5)
        let documentUndoDepth = h.undoDepth(Fixtures.docID)
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
        XCTAssertEqual(h.undoDepth(Fixtures.docID), documentUndoDepth, "Settings undo must not pollute document history")
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

    func testCommitBudgetWithFiveThousandQueuedDocuments() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        let (head, items) = Fixtures.sampleContent()
        for i in 0..<4_996 {
            var content = head; content.meta.id = NibID("PERF" + String(i))
            _ = try h.library.createDocument(content, title: "Notebook " + String(i), in: nil)
        }
        await engine.start()
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "nib"])
        XCTAssertEqual(engine.queue.entries.count, 5_000)
        let doc = engine.queue.entries.last!.document
        let changes = Changeset(seq: 1, principal: .user, group: "budget", label: "Stroke", command: "test.stroke",
            mutations: [.item(doc, Fixtures.page1, before: nil, after: items[Fixtures.page1]![0])])
        let eventsBefore = h.app.events.events(since: 0).count
        let diskBefore = try Data(contentsOf: root.appendingPathComponent("queue.json"))
        let token = engine.queue.entries.last!.token
        let budget = 0.002
        var worst = 0.0
        for _ in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            engine.committed(changes)
            worst = max(worst, ProcessInfo.processInfo.systemUptime - start)
        }
        XCTAssertLessThan(worst, budget * 4)
        XCTAssertNotEqual(engine.queue.entries.last!.token, token)
        XCTAssertEqual(h.app.events.events(since: 0).count, eventsBefore)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("queue.json")), diskBefore)
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertEqual(h.app.events.events(since: 0).count, eventsBefore + 2, "A burst emits one status pair")
        try await engine.persist().value
    }

    func testStampReusesUnchangedPagesAndIgnoresDeletionOnlyRevisions() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = CountingBackupPersistence(base: h.persistence)
        let head = try h.persistence.loadHead(Fixtures.docID)
        for page in head.livePages { persistence.revisions[page.id] = Rev(wallMs: 1, counter: 0, device: 0) }
        let initial = try await engine.contentStamp(Fixtures.docID, persistence: persistence)
        XCTAssertEqual(persistence.loads.count, head.livePages.count)
        persistence.loads = []
        let unchanged = try await engine.contentStamp(Fixtures.docID, persistence: persistence, previous: initial)
        XCTAssertTrue(persistence.loads.isEmpty)
        XCTAssertEqual(unchanged, initial)
        h.persistence.pageItems[Fixtures.docID]![Fixtures.page1]![0].deleted = true
        persistence.revisions[Fixtures.page1] = Rev(wallMs: 2, counter: 0, device: 0)
        let deleted = try await engine.contentStamp(Fixtures.docID, persistence: persistence, previous: unchanged)
        XCTAssertEqual(persistence.loads, [Fixtures.page1])
        XCTAssertFalse(deleted.hasChanges(since: unchanged))
        persistence.loads = []
        h.persistence.pageItems[Fixtures.docID]![Fixtures.page1]![1].z = "new"
        persistence.revisions[Fixtures.page1] = Rev(wallMs: 3, counter: 0, device: 0)
        let changed = try await engine.contentStamp(Fixtures.docID, persistence: persistence, previous: deleted)
        XCTAssertEqual(persistence.loads, [Fixtures.page1])
        XCTAssertTrue(changed.hasChanges(since: deleted))
        persistence.loads = []
        persistence.revisions[Fixtures.page2] = nil
        _ = try await engine.contentStamp(Fixtures.docID, persistence: persistence, previous: changed)
        XCTAssertEqual(persistence.loads, [Fixtures.page2], "Unknown revisions require loading")
    }

    func testFirstExternalEditAfterClearQueueIsBackedUp() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        await engine.start()
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "nib"])
        try await engine.clearQueue()
        var head = h.persistence.heads[Fixtures.docID]!
        head.meta.language = "th"
        _ = try h.library.createDocument(head, title: h.library.node(Fixtures.docID)!.title, in: Fixtures.folderID)
        await engine.libraryChanged()
        XCTAssertEqual(engine.queue.entries.map(\.document), [Fixtures.docID])
        try await engine.persist().value
    }

    func testUploadDoesNotStampContentChangedAfterExport() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        await engine.start()
        installExport(h)
        var rewritten = false
        h.app.commands.register(CommandDescriptor(id: CommandIDs.webdavPut, title: "Upload", summary: "Rewrite while uploading", effect: .session)) { params, ctx in
            if !ctx.dryRun, params["path"]!.stringValue!.contains(Fixtures.docID.raw), !rewritten {
                rewritten = true
                var head = h.persistence.heads[Fixtures.docID]!
                head.meta.language = "th"
                _ = try h.library.createDocument(head, title: h.library.node(Fixtures.docID)!.title, in: Fixtures.folderID)
            }
            return [:]
        }
        _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "nib"])
        _ = try await h.run(CommandIDs.backupNow)
        XCTAssertTrue(engine.queue.entries.isEmpty)
        await engine.libraryChanged()
        XCTAssertEqual(engine.queue.entries.map(\.document), [Fixtures.docID])
        try await engine.persist().value
    }

    func testManualRestartsAfterBackgroundAndSavesWithoutTemporaryAsset() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        let navigator = BackupTestNavigator(session: h.session)
        h.app.ui.activeNavigator = navigator
        h.app.services.assets = nil // The Files flow must not require or copy into the temporary asset store.
        let picker = BackupTestPicker()
        engine.userInterface = picker
        var archives = 0
        engine.archive = { _, _, progress, _, _ in
            archives += 1
            XCTAssertTrue(engine.status().manual)
            if archives == 1 {
                while !progress.isCancelled { try await Task.sleep(nanoseconds: 1_000_000) }
                throw CancellationError()
            }
            let output = root.appendingPathComponent("manual.zip")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("archive".utf8).write(to: output)
            return output
        }
        h.app.commands.register(CommandDescriptor(id: "test.manual", title: "Manual", summary: "Exercise engine", effect: .session)) { _, ctx in
            try await engine.manual(ctx)
        }
        var resumed: Task<JSONValue, Error>?
        engine.resumeManual = { resumed = Task { try await h.run("test.manual") } }
        let first = Task { try await h.run("test.manual") }
        for _ in 0..<100 where archives == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(archives, 1)
        engine.interruptManualForBackground()
        engine.resumeInterruptedManual() // Activation while the old run is still unwinding must preserve the flag.
        XCTAssertNil(resumed)
        do { _ = try await first.value; XCTFail("Interrupted archive succeeded") } catch { }
        XCTAssertTrue(engine.status().manualInterrupted)
        engine.resumeInterruptedManual()
        let task = try XCTUnwrap(resumed)
        let result = try await task.value
        XCTAssertEqual(archives, 2)
        XCTAssertEqual(picker.saves, 1)
        XCTAssertNil(result["asset"])
        XCTAssertEqual(result["restoreCommand"], .string(CommandIDs.importPick))
        XCTAssertFalse(engine.status().manualInterrupted)
        XCTAssertFalse(engine.status().manual)
        picker.cancel = true
        do { _ = try await h.run("test.manual"); XCTFail("Cancelled picker succeeded") }
        catch let error as NibError { XCTAssertEqual(error.code, .userDenied) }
        XCTAssertEqual(engine.status().state, "idle")
        XCTAssertNil(engine.status().error)
    }

    func testWebDAVValidationFailsBeforeSettingsOrQueueChanges() async throws {
        let (h, engine, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.webdavPut, title: "Validate", summary: "Reject library paths", effect: .session)) { _, ctx in
            XCTAssertTrue(ctx.dryRun)
            throw NibError(.invalidParams, "Destination is inside the library")
        }
        do {
            _ = try await h.run(CommandIDs.backupConfigure, ["destination": ["kind": "webdav"], "format": "nib"])
            XCTFail("Invalid destination accepted")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .invalidParams)
            XCTAssertEqual(error.path, "$.destination")
            XCTAssertNotNil(error.hint)
        }
        XCTAssertEqual(engine.status().configuration.destination.kind, "none")
        XCTAssertTrue(engine.queue.entries.isEmpty)
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

    func testManualArchivePreservesUserFoldersAndOmitsJunkSymlinksAndLockedPackages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-" + UUID().uuidString)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        for name in ["School/Notes.nibnote/assets", "School/Notes.nibnote/audio", "School/Notes.nibnote/caches", "Locked.nibnote", ".nib-library/Previews", "Temp/Notes.nibnote", "Previews/A.nibnote", "Cache.tmp/Keep.nibnote"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for path in ["School/Notes.nibnote/assets/image.png", "School/Notes.nibnote/audio/clip.caf", "School/Notes.nibnote/caches/thumb.png", "Locked.nibnote/secret.json", ".nib-library/prefs.json", ".nib-library/Previews/template.json", "Temp/Notes.nibnote/doc.x.json", "Previews/A.nibnote/content.nibpage", "Cache.tmp/Keep.nibnote/data", "Temp/Notes.nibnote/.DS_Store", "Previews/A.nibnote/write.partial", "Previews/A.nibnote/write.tmp"] {
            try Data(path.utf8).write(to: root.appendingPathComponent(path))
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("secret-link"), withDestinationURL: root.appendingPathComponent("Locked.nibnote/secret.json"))
        let (head, _) = Fixtures.sampleContent()
        try JSONEncoder().encode(head).write(to: root.appendingPathComponent("School/Notes.nibnote/doc.00000001.json"))
        try JSONEncoder().encode(head).write(to: root.appendingPathComponent("Temp/Notes.nibnote/doc.x.json"))
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
        for path in ["School/Notes.nibnote/caches/thumb.png", "Temp/Notes.nibnote/doc.x.json", "Previews/A.nibnote/content.nibpage", ".nib-library/Previews/template.json", "Cache.tmp/Keep.nibnote/data"] {
            XCTAssertTrue(paths.contains(path), path)
        }
        XCTAssertFalse(paths.contains { $0.contains("Locked") || $0.contains("secret-link") || $0.hasSuffix(".DS_Store") || $0.hasSuffix("write.partial") || $0.hasSuffix("write.tmp") })
        XCTAssertEqual(progress.fractionCompleted, 1)
        var extracted = Data()
        _ = try zip.extract(zip["School/Notes.nibnote/audio/clip.caf"]!) { extracted.append($0) }
        XCTAssertEqual(extracted, Data("School/Notes.nibnote/audio/clip.caf".utf8))
        let cancelled = Progress(totalUnitCount: 1); cancelled.cancel()
        do { _ = try await BackupWriter.archive(root: root, blocked: [], progress: cancelled); XCTFail("Cancelled archive succeeded") } catch { }
    }
}

@MainActor
private final class CountingBackupPersistence: DocumentPersistence {
    let base: InMemoryPersistence
    var revisions: [PageID: Rev] = [:]
    var loads: [PageID] = []
    init(base: InMemoryPersistence) { self.base = base }
    func loadHead(_ doc: DocumentID) throws -> DocumentContent { try base.loadHead(doc) }
    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] { loads.append(page); return try base.loadItems(doc, page: page) }
    func contentRevision(_ doc: DocumentID, page: PageID) -> Rev? { revisions[page] }
    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) { base.didChange(doc, head: head, pages: pages) }
    func flush(_ doc: DocumentID) { base.flush(doc) }
    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL { try base.fileURL(doc, relativePath: relativePath) }
    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { try base.remoteChanges(doc) }
}

@MainActor
private final class BackupTestNavigator: SceneNavigator {
    let session: EditorSession
    let openDocuments: [DocumentID] = []
    var activeDocument: DocumentID? { nil }
    var rootViewController: UIViewController? { nil }
    init(session: EditorSession) { self.session = session }
    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {}
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) {}
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) {}
}

@MainActor
private final class BackupTestPicker: BackupUserInterface {
    var saves = 0
    var cancel = false
    func chooseFolder(navigator: SceneNavigator) async throws -> URL { throw NibError.unavailable("Not used") }
    func saveArchive(_ url: URL, navigator: SceneNavigator) async throws {
        saves += 1
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        if cancel { throw NibError(.userDenied, "Files selection cancelled") }
    }
}
