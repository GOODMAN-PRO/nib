import XCTest
import SwiftUI
import NibDesign
import NibContracts
import NibTesting
@testable import FeatSyncUI

@MainActor
final class FeatSyncUITests: XCTestCase {
    private func command(_ app: NibApp, _ id: String, effect: Effect = .read,
                         handler: @escaping CommandHandler) {
        app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test service contract.",
                                               params: .anything(), examples: [[:]], effect: effect,
                                               target: .library, owner: "test"), handler: handler)
    }

    private func sync(_ app: NibApp, result: JSONValue = ["merged": 0, "errors": []]) {
        command(app, CommandIDs.syncNow, effect: .session) { _, _ in result }
    }

    func testRegistrationsAndConformance() async {
        let h = Harness(features: [FeatSyncUIFeature.self])
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.libraryRepair)?.owner, "syncui")
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.libraryRepair)?.effect, .session)
        XCTAssertEqual(h.app.ui.panels.get(PanelIDs.cloudBackup)?.providesHeader, true)
        XCTAssertNotNil(h.app.ui.chromeOverlays.get("syncui.containerBanner"))
        XCTAssertNotNil(h.app.ui.chromeOverlays.get("syncui.readOnlyBanner"))
        XCTAssertNil(h.app.services.get(CloudStatusModel.key, as: CloudStatusModel.self))
        let problems = await CommandConformance.check(features: [FeatSyncUIFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testTypedEventsKeepSourcesIndependentAndRecover() {
        let h = Harness(features: [FeatSyncUIFeature.self])
        let model = CloudStatusModel.shared(h.app)
        h.app.events.emit(SyncStatusPayload(state: "error", source: "store", reason: "writeFailed", message: "Could not save"), doc: Fixtures.docID)
        h.app.events.emit(SyncStatusPayload(state: "checking", source: "sync"), doc: Fixtures.docID)
        XCTAssertEqual(model.documentStatus(Fixtures.docID).state, "error")
        h.app.events.emit(SyncStatusPayload(state: "idle", source: "sync"), doc: Fixtures.docID)
        XCTAssertEqual(model.syncState.state, "error")
        // F001 still needs the saved-recovery emitter; do not manufacture an event it never sends.
        h.app.events.emit(NibEventType.docClosed, doc: Fixtures.docID)
        XCTAssertFalse(model.documentStatus(Fixtures.docID).needsAttention)
        h.app.events.emit(SyncStatusPayload(state: "error", source: "backup", message: "Destination offline"))
        XCTAssertFalse(model.syncState.needsAttention)
        XCTAssertEqual(model.serviceState("backup")?.message, "Destination offline")
        h.app.events.emit(NibEventType.syncStatus, payload: ["source": "store"])
        XCTAssertFalse(model.syncState.needsAttention, "Malformed events must not replace valid state")
    }

    func testReplayDownloadsAndRootSwitchDiscardOldFailures() {
        let h = Harness(features: [FeatSyncUIFeature.self])
        h.app.events.emit(SyncStatusPayload(state: "error", source: "store"), doc: Fixtures.docID)
        h.app.events.emit(NibEventType.libraryChanged, payload: ["root": true])
        let old = h.app.events.emit(SyncStatusPayload(state: "downloading", source: "sync", files: ["a", "b"]), doc: Fixtures.textDocID)
        let model = CloudStatusModel.shared(h.app)
        XCTAssertEqual(model.syncState.files.count, 2)
        XCTAssertEqual(model.syncState.state, "downloading")
        XCTAssertEqual(model.attentionDocuments.map(\.documentID), [Fixtures.textDocID])
        h.app.events.emit(SyncStatusPayload(state: "downloading", source: "sync", files: ["c"]), doc: Fixtures.studySetID)
        XCTAssertEqual(model.syncState.files.count, 3)
        h.app.events.emit(NibEventType.libraryChanged, payload: ["root": true])
        model.consume(old, scheduleQueries: false)
        XCTAssertEqual(model.syncState.state, "unknown", "Delayed events from the old library must be ignored")
    }

    func testCatalogAndUseReadOnlyContractWithoutLibraryList() async {
        let h = Harness(features: [FeatSyncUIFeature.self])
        h.app.workspace.persistence = ReadOnlyPersistence(base: h.persistence, readOnly: Fixtures.textDocID)
        var listCalls = 0
        command(h.app, CommandIDs.libraryList) { _, _ in listCalls += 1; return [:] }
        command(h.app, CommandIDs.libraryLocations) { _, _ in
            ["locations": [["current": true, "name": "Notes", "path": "/Notes", "provider": "icloud"]]]
        }
        command(h.app, CommandIDs.backupStatus) { _, _ in
            ["queue": ["doc:FIXTUREDOC01"], "errors": [["message": "Folder unavailable"]]]
        }
        h.app.services.set(NSNumber(value: true), for: "library.inContainer")
        let model = CloudStatusModel.shared(h.app)
        await model.refresh()
        XCTAssertEqual(listCalls, 0)
        XCTAssertEqual(model.documents.count, 1, "Healthy catalogue rows are not materialized")
        XCTAssertTrue(model.documents.first?.readOnly == true)
        XCTAssertEqual(model.attentionDocuments.map(\.ref), ["doc:FIXTUREDOC02"])
        XCTAssertEqual(model.locationName, "Notes")
        XCTAssertEqual(model.locationPath, "/Notes")
        XCTAssertEqual(model.provider, "iCloud Drive")
        XCTAssertEqual(CloudStatusModel.pending(model.backup), 1)
        XCTAssertEqual(CloudStatusModel.errors(model.backup), ["Folder unavailable"])
        XCTAssertTrue(model.inContainer)
        h.app.services.set(NSNumber(value: false), for: "library.inContainer")
        h.app.events.emit(NibEventType.libraryChanged)
        XCTAssertFalse(model.inContainer)
    }

    func testStartReturnsWithoutQueryingSuspendedLibraryList() async {
        let h = Harness(features: [FeatSyncUIFeature.self])
        var suspended: CheckedContinuation<JSONValue, Never>?
        command(h.app, CommandIDs.libraryList) { _, _ in
            await withCheckedContinuation { suspended = $0 }
        }
        var returned = false
        let start = Task { @MainActor in
            await FeatSyncUIFeature.start(h.app)
            returned = true
        }
        for _ in 0..<100 where !returned && suspended == nil { await Task.yield() }
        let returnedBeforeResume = returned
        suspended?.resume(returning: ["nodes": []])
        await start.value
        XCTAssertTrue(returnedBeforeResume)
        XCTAssertNil(suspended, "Startup must not call library.list at all")
        let model = CloudStatusModel.shared(h.app)
        XCTAssertFalse(model.loading)
    }

    func testSlowQueryCannotOverwriteNewerSnapshot() async {
        let h = Harness(features: [FeatSyncUIFeature.self])
        var suspended: CheckedContinuation<JSONValue, Never>?
        var calls = 0
        command(h.app, CommandIDs.backupStatus) { _, _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { suspended = $0 } }
            return ["pending": 2]
        }
        let model = CloudStatusModel.shared(h.app)
        let slow = Task { @MainActor in await model.refresh() }
        for _ in 0..<100 where suspended == nil { await Task.yield() }
        XCTAssertNotNil(suspended)
        await model.refresh()
        suspended?.resume(returning: ["pending": 1])
        await slow.value
        XCTAssertEqual(CloudStatusModel.pending(model.backup), 2)
        XCTAssertFalse(model.loading)
    }

    func testStatusQueriesAreLazyThrottledAndDoNotReloadLocationOrCatalog() async throws {
        let h = Harness(features: [FeatSyncUIFeature.self])
        var locations = 0
        var backups = 0
        command(h.app, CommandIDs.libraryLocations) { _, _ in locations += 1; return [:] }
        command(h.app, CommandIDs.backupStatus) { _, _ in backups += 1; return [:] }
        await FeatSyncUIFeature.start(h.app)
        let model = CloudStatusModel.shared(h.app)
        h.app.events.emit(SyncStatusPayload(state: "error", source: "store"), doc: Fixtures.docID)
        h.app.events.emit(NibEventType.libraryChanged)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backups, 0)
        model.visibilityBegan()
        for _ in 0..<100 where backups == 0 { await Task.yield() }
        XCTAssertEqual(backups, 1)
        XCTAssertEqual(locations, 1)
        // Rename without library.changed: a status event must not re-read catalogue rows.
        let oldTitle = model.attentionDocuments.first?.title
        try h.library.rename(Fixtures.docID, to: "Renamed")
        for _ in 0..<20 { h.app.events.emit(SyncStatusPayload(state: "error", source: "store"), doc: Fixtures.docID) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(backups, 1)
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertEqual(backups, 2)
        XCTAssertEqual(locations, 1)
        // Titles for event rows use O(1) node lookups; no library.list query is used.
        XCTAssertNotNil(oldTitle)
        h.app.events.emit(NibEventType.libraryChanged)
        XCTAssertEqual(model.attentionDocuments.first?.title, "Renamed")
        model.visibilityEnded()
        h.app.events.emit(NibEventType.backupStatus)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backups, 2)
    }

    func testOverlayVisibilityAndDocumentMenu() throws {
        let h = Harness(features: [FeatSyncUIFeature.self])
        func overlays(_ kind: DocumentKind? = nil, compact: Bool = false) -> [String] {
            h.app.ui.visibleChromeOverlays(ChromeContext(app: h.app, session: h.session, kind: kind, isCompact: compact)).map(\.id)
        }
        h.app.services.set(NSNumber(value: true), for: "library.inContainer")
        XCTAssertTrue(overlays().contains("syncui.containerBanner"))
        XCTAssertFalse(overlays(.notebook).contains("syncui.containerBanner"))
        h.app.services.set(NSNumber(value: false), for: "library.inContainer")
        XCTAssertFalse(overlays().contains("syncui.containerBanner"))
        XCTAssertTrue(overlays(compact: true).contains("syncui.libraryStatusCompact"))
        XCTAssertFalse(overlays(compact: true).contains("syncui.libraryStatus"))
        XCTAssertEqual(h.app.ui.chromeOverlays.get("syncui.libraryStatusCompact")?.placement, .bottomTrailing)
        h.app.workspace.persistence = ReadOnlyPersistence(base: h.persistence, readOnly: Fixtures.docID)
        XCTAssertTrue(overlays(.notebook).contains("syncui.readOnlyBanner"))
        XCTAssertFalse(overlays().contains("syncui.readOnlyBanner"))
        let menu = try XCTUnwrap(h.app.ui.menus.get("syncui.documentStatus"))
        h.app.events.emit(SyncStatusPayload(state: "error", source: "store", reason: "writeFailed"), doc: Fixtures.docID)
        let doc = MenuContext(app: h.app, nodes: [Fixtures.docID])
        XCTAssertTrue(menu.isVisible(doc))
        XCTAssertEqual(menu.resolvedTitle(for: doc), "Sync: Sync needs attention")
        XCTAssertEqual(menu.params(doc)["doc"]?.stringValue, "doc:FIXTUREDOC01")
        let folder = MenuContext(app: h.app, nodes: [Fixtures.folderID])
        XCTAssertFalse(menu.isVisible(folder))
        XCTAssertEqual(menu.resolvedTitle(for: folder), "Cloud & Backup")
        XCTAssertNil(menu.params(folder)["doc"])
    }

    func testEventOnlyDocumentAttentionAndCloseRejectsDelayedEvent() {
        let h = Harness(features: [FeatSyncUIFeature.self])
        let model = CloudStatusModel.shared(h.app)
        let doc = DocumentID("MISSINGDOC01")
        let failure = h.app.events.emit(SyncStatusPayload(state: "error", source: "store", reason: "writeFailed"), doc: doc)
        XCTAssertEqual(model.attentionDocuments.count, 1)
        XCTAssertEqual(model.attentionDocuments.first?.documentID, doc)
        XCTAssertEqual(model.attentionDocuments.first?.title, "Untitled Document")
        h.app.events.emit(NibEventType.docClosed, doc: doc)
        model.consume(failure)
        XCTAssertTrue(model.attentionDocuments.isEmpty)
        XCTAssertFalse(model.syncState.needsAttention)
    }

    func testPanelRendersLightDarkAndAccessibilitySizes() {
        let h = Harness(features: [FeatSyncUIFeature.self])
        h.app.services.set(NSNumber(value: true), for: "library.inContainer")
        let model = CloudStatusModel.shared(h.app)
        model.locationName = "Notes"
        let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        let panel = CloudStatusPanel(context: context, model: model).nibLiquidMode(.off)
        let snapshots = NibSnapshot.images(panel, size: CGSize(width: 390, height: 844), scale: 1)
        XCTAssertEqual(snapshots.count, NibSnapshot.Variant.allCases.count)
        for image in snapshots.values {
            XCTAssertEqual(image.size.width, 390)
            XCTAssertEqual(image.size.height, 844)
        }
        let normal = NibSnapshot.fittingSize(ContainerLibraryBanner(app: h.app), width: 390)
        let accessible = NibSnapshot.fittingSize(ContainerLibraryBanner(app: h.app), width: 390, variant: .largeText)
        XCTAssertGreaterThan(accessible.height, normal.height, "The persistent notice must grow with Dynamic Type")
        XCTAssertNotNil(NibSnapshot.image(panel, size: CGSize(width: 768, height: 1024), scale: 1))
    }

    func testCacheInvalidationOnlyTouchesCurrentRoot() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let root = support.appendingPathComponent("libraryA")
        let other = support.appendingPathComponent("libraryB")
        let currentCache = CatalogCacheRepair.cacheURL(root: root, support: support)
        let otherCache = CatalogCacheRepair.cacheURL(root: other, support: support)
        try FileManager.default.createDirectory(at: currentCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt cache".utf8).write(to: currentCache)
        try Data("other cache".utf8).write(to: otherCache)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("document.nibnote")
        try Data("original".utf8).write(to: original)
        try CatalogCacheRepair.invalidate(root: root, support: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentCache.path))
        XCTAssertEqual(try Data(contentsOf: otherCache), Data("other cache".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        try CatalogCacheRepair.invalidate(root: root, support: support)
    }

    func testRepairDryRunDoesNotCallServicesOrEmitProgress() async throws {
        let h = Harness(features: [FeatSyncUIFeature.self])
        var calls = 0
        command(h.app, CommandIDs.syncNow, effect: .session) { _, _ in calls += 1; return ["merged": 1] }
        let seq = h.app.events.lastSeq
        let depths = h.undoDepths()
        let result = try await h.app.bus.execute(Invocation(command: CommandIDs.libraryRepair, dryRun: true))
        XCTAssertEqual(result.value["dryRun"]?.boolValue, true)
        XCTAssertEqual(result.value["catalogRebuilt"]?.boolValue, false)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(h.app.events.lastSeq, seq)
        XCTAssertEqual(h.undoDepths(), depths)
    }

    func testRepairRoutesMergesAndIndexAndReportsDocumentErrors() async throws {
        let h = Harness(features: [FeatSyncUIFeature.self])
        sync(h.app, result: ["merged": 3, "errors": [["doc": "doc:FIXTUREDOC02", "message": "Unreadable head"]]])
        var indexed = false
        command(h.app, CommandIDs.indexRebuild, effect: .session) { _, ctx in
            XCTAssertEqual(ctx.principal, .user)
            indexed = true
            return [:]
        }
        let before = try h.snapshotAll()
        let depths = h.undoDepths()
        let result = try await h.run(CommandIDs.libraryRepair, ["rebuildIndex": true])
        XCTAssertEqual(result["merged"]?.intValue, 3)
        XCTAssertEqual(result["catalogRebuilt"]?.boolValue, false, "The in-memory library does not recreate the disk cache")
        XCTAssertEqual(result["indexRebuilt"]?.boolValue, true)
        XCTAssertEqual(result["errors"]?.arrayValue?.first?["ref"]?.stringValue, "doc:FIXTUREDOC02")
        XCTAssertTrue(indexed)
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.undoDepths(), depths)
        XCTAssertEqual(h.app.events.events(since: 0).last?.decode(SyncStatusPayload.self)?.state, "warning")
    }

    func testRepairDependencyFailureBeforeWorkAndFailureResetsGate() async throws {
        let h = Harness(features: [FeatSyncUIFeature.self])
        sync(h.app)
        let seq = h.app.events.lastSeq
        do {
            _ = try await h.run(CommandIDs.libraryRepair, ["rebuildIndex": true])
            XCTFail("Missing index must be reported")
        } catch { XCTAssertEqual((error as? NibError)?.code, .unavailable) }
        XCTAssertEqual(h.app.events.lastSeq, seq)
        command(h.app, CommandIDs.indexRebuild, effect: .session) { _, _ in throw NibError.unavailable("index storage") }
        do {
            _ = try await h.run(CommandIDs.libraryRepair, ["rebuildIndex": true])
            XCTFail("Index failure must propagate")
        } catch { XCTAssertEqual((error as? NibError)?.code, .unavailable) }
        XCTAssertFalse(h.app.services.get(RepairState.key, as: RepairState.self)?.running ?? true)
        XCTAssertEqual(h.app.events.events(since: 0).last?.decode(SyncStatusPayload.self)?.state, "error")
        let retry = try await h.run(CommandIDs.libraryRepair)
        XCTAssertEqual(retry["catalogRebuilt"]?.boolValue, false)
    }

    func testRepairFailureThenSuccessClearsOnlyResolvedSaveErrors() async throws {
        let h = Harness(features: [FeatSyncUIFeature.self])
        let model = CloudStatusModel.shared(h.app)
        command(h.app, CommandIDs.syncNow, effect: .session) { _, _ in throw NibError.unavailable("folder") }
        do { _ = try await h.run(CommandIDs.libraryRepair); XCTFail("Expected repair failure") } catch {}
        XCTAssertEqual(model.syncState.state, "error")
        h.app.events.emit(SyncStatusPayload(state: "error", source: "store", reason: "writeFailed"), doc: Fixtures.docID)
        h.app.events.emit(SyncStatusPayload(state: "error", source: "store", reason: "unreadable"), doc: Fixtures.textDocID)
        sync(h.app, result: ["merged": 0, "errors": [["doc": "doc:FIXTUREDOC02", "message": "Unreadable"]]])
        _ = try await h.run(CommandIDs.libraryRepair)
        XCTAssertFalse(model.documentStatus(Fixtures.docID).needsAttention)
        XCTAssertTrue(model.documentStatus(Fixtures.textDocID).needsAttention)
        sync(h.app)
        _ = try await h.run(CommandIDs.libraryRepair)
        XCTAssertEqual(model.syncState.title, "Up to date")
        XCTAssertTrue(model.attentionDocuments.isEmpty)
    }

    func testRepairCannotClearFailureEmittedDuringRepair() async throws {
        let h = Harness(features: [FeatSyncUIFeature.self])
        let model = CloudStatusModel.shared(h.app)
        command(h.app, CommandIDs.syncNow, effect: .session) { _, _ in
            h.app.events.emit(SyncStatusPayload(state: "error", source: "store", reason: "writeFailed"), doc: Fixtures.docID)
            return ["merged": 0, "errors": []]
        }
        _ = try await h.run(CommandIDs.libraryRepair)
        XCTAssertTrue(model.documentStatus(Fixtures.docID).needsAttention)
    }

    func testDuplicateVerificationMatchesPageAndItemCounts() async {
        let h = Harness(features: [FeatSyncUIFeature.self])
        command(h.app, CommandIDs.libraryDuplicate, effect: .library) { _, _ in
            let copy = try h.library.duplicate(Fixtures.docID)
            return ["refs": [.string(NodeRef.document(copy).description)]]
        }
        command(h.app, CommandIDs.queryGet) { _, _ in ["readable": true] }
        let model = CloudStatusModel.shared(h.app)
        model.duplicateAndVerify(CloudDocument(ref: "doc:FIXTUREDOC01", title: "Notebook", badge: "error", readOnly: false, locked: false), session: h.session)
        for _ in 0..<100 where model.busy { await Task.yield() }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.actionError)
        XCTAssertTrue(model.receipt?.contains("Page and item counts match") == true)
        XCTAssertNotNil(model.verificationRef)
    }

    func testDuplicateVerificationDetectsMissingPagesAndItems() async {
        for missingPage in [true, false] {
            let h = Harness(features: [FeatSyncUIFeature.self])
            command(h.app, CommandIDs.libraryDuplicate, effect: .library) { _, _ in
                let copy = try h.library.duplicate(Fixtures.docID)
                if missingPage { h.persistence.heads[copy]?.pages.removeLast() }
                else { h.persistence.pageItems[copy]?[Fixtures.page1] = [] }
                return ["refs": [.string(NodeRef.document(copy).description)]]
            }
            command(h.app, CommandIDs.queryGet) { _, _ in ["readable": true] }
            let model = CloudStatusModel.shared(h.app)
            model.duplicateAndVerify(CloudDocument(ref: "doc:FIXTUREDOC01", title: "Notebook", badge: "error", readOnly: false, locked: false), session: h.session)
            for _ in 0..<100 where model.busy { await Task.yield() }
            XCTAssertFalse(model.busy)
            XCTAssertNotNil(model.verificationRef)
            XCTAssertNil(model.receipt)
            XCTAssertTrue(model.actionError?.contains(missingPage ? "missing 1 page" : "item count does not match") == true)
        }
    }

    func testDuplicateIsDisabledDuringDownload() async {
        let h = Harness(features: [FeatSyncUIFeature.self])
        let model = CloudStatusModel.shared(h.app)
        var copies = 0
        command(h.app, CommandIDs.libraryDuplicate, effect: .library) { _, _ in copies += 1; return [:] }
        h.app.events.emit(SyncStatusPayload(state: "downloading", source: "sync"), doc: Fixtures.docID)
        h.app.events.emit(SyncStatusPayload(state: "error", source: "store"), doc: Fixtures.docID)
        model.duplicateAndVerify(CloudDocument(ref: "doc:FIXTUREDOC01", title: "Notebook", badge: "error", readOnly: false, locked: false), session: h.session)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(copies, 0)
        XCTAssertFalse(model.busy)
        h.app.events.emit(SyncStatusPayload(state: "error", source: "sync", reason: "downloadTimeout"), doc: Fixtures.docID)
        model.duplicateAndVerify(CloudDocument(ref: "doc:FIXTUREDOC01", title: "Notebook", badge: "error", readOnly: false, locked: false), session: h.session)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(copies, 0, "A timed-out download is still incomplete")
    }

    func testDuplicateRejectsPartialReadReportedByStore() async {
        let h = Harness(features: [FeatSyncUIFeature.self])
        command(h.app, CommandIDs.libraryDuplicate, effect: .library) { _, _ in
            let copy = try h.library.duplicate(Fixtures.docID)
            return ["refs": [.string(NodeRef.document(copy).description)]]
        }
        command(h.app, CommandIDs.queryGet) { params, _ in
            if let ref = params["ref"]?.stringValue, ref != "doc:FIXTUREDOC01" {
                h.app.events.emit(SyncStatusPayload(state: "error", source: "store", reason: "unreadable", message: "Unreadable page"),
                                  doc: NodeRef.documentID(from: ref))
            }
            return ["partial": true]
        }
        let model = CloudStatusModel.shared(h.app)
        model.duplicateAndVerify(CloudDocument(ref: "doc:FIXTUREDOC01", title: "Notebook", badge: "error", readOnly: false, locked: false), session: h.session)
        for _ in 0..<100 where model.busy { await Task.yield() }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.receipt)
        XCTAssertNotNil(model.verificationRef)
        XCTAssertTrue(model.actionError?.contains("Unreadable page") == true)
    }

    func testRelocationOffersCopyAfterSharedLibraryRefusal() async {
        let h = Harness(features: [FeatSyncUIFeature.self])
        var copied = false
        command(h.app, CommandIDs.libraryRelocate, effect: .session) { params, _ in
            guard params["copy"]?.boolValue == true else { throw NibError.invalid("Shared library", path: "$.copy") }
            copied = true
            return [:]
        }
        let model = CloudStatusModel.shared(h.app)
        model.perform(CommandIDs.libraryRelocate, params: ["copy": false])
        for _ in 0..<100 where model.busy { await Task.yield() }
        XCTAssertTrue(model.canCopyLibrary)
        model.perform(CommandIDs.libraryRelocate, params: ["copy": true])
        for _ in 0..<100 where model.busy { await Task.yield() }
        XCTAssertTrue(copied)
        XCTAssertNil(model.actionError)
    }

    func testDuplicateVerificationKeepsCopyOnFailure() async {
        let h = Harness(features: [FeatSyncUIFeature.self])
        var duplicated = 0
        command(h.app, CommandIDs.libraryDuplicate, effect: .library) { _, _ in
            duplicated += 1
            return ["refs": ["doc:COPYDOC00001"]]
        }
        command(h.app, CommandIDs.queryGet) { _, _ in throw NibError.unavailable("copy contents") }
        let model = CloudStatusModel.shared(h.app)
        model.duplicateAndVerify(CloudDocument(ref: "doc:FIXTUREDOC01", title: "Notebook", badge: "error", readOnly: false, locked: false), session: h.session)
        for _ in 0..<100 where model.busy { await Task.yield() }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(duplicated, 1)
        XCTAssertEqual(model.verificationRef, "doc:COPYDOC00001")
        XCTAssertTrue(model.actionError?.contains("copy was kept") == true)
        XCTAssertNil(model.receipt)
    }
}

@MainActor
private final class ReadOnlyPersistence: DocumentPersistence {
    let base: InMemoryPersistence
    let readOnly: DocumentID
    init(base: InMemoryPersistence, readOnly: DocumentID) { self.base = base; self.readOnly = readOnly }
    func isReadOnly(_ doc: DocumentID) -> Bool { doc == readOnly }
    func loadHead(_ doc: DocumentID) throws -> DocumentContent { try base.loadHead(doc) }
    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] { try base.loadItems(doc, page: page) }
    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) { base.didChange(doc, head: head, pages: pages) }
    func flush(_ doc: DocumentID) { base.flush(doc) }
    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL { try base.fileURL(doc, relativePath: relativePath) }
    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { try base.remoteChanges(doc) }
}
