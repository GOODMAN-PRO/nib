import XCTest
import NibContracts
import NibTesting
@testable import FeatObjectMenu

@MainActor
final class AtomicShapeJoinTests: XCTestCase {
    private let doc = Fixtures.docID
    private let page = Fixtures.page1
    private var ref: String { NodeRef.item(doc, page, Fixtures.shapeID).description }

    private func params(_ h: Harness) throws -> JSONValue {
        let neighbour = try h.app.workspace.item(doc, page: page, id: Fixtures.shapeID)
        let shape = ShapeItem(shape: .polyline, frame: Frame(x: 0, y: 0, w: 200, h: 100),
                              points: [.zero, Point(100, 100), Point(200, 100)])
        return ["refs": [.string(ref)], "expectedRevisions": try JSONValue.from([ref: neighbour.rev]),
                "replacementShape": try JSONValue.from(shape), "replacementID": "JOINED"]
    }

    func testJoinCommitsOnceAndUndoRedoRestoreNeighboursAndDependants() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let before = try h.snapshotAll(), depth = h.undoDepth(doc)
        var commits = 0
        let observation = h.app.bus.observeCommits { _ in commits += 1 }
        defer { withExtendedLifetime(observation) {} }
        let out = try await h.run(CommandIDs.itemDelete, params(h))
        XCTAssertEqual(commits, 1, "Observers must never see creation and deletion as separate commits")
        XCTAssertTrue((out["deleted"]?.arrayValue ?? []).contains(.string(ref)))
        XCTAssertEqual(out["replacementRef"], .string(NodeRef.item(doc, page, "JOINED").description))
        XCTAssertThrowsError(try h.app.workspace.item(doc, page: page, id: Fixtures.shapeID))
        XCTAssertEqual(try h.app.workspace.item(doc, page: page, id: "JOINED").shape?.shape, .polyline)
        XCTAssertEqual(h.undoDepth(doc), depth + 1)
        let joined = try h.snapshotAll()
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshotAll(), before, "Restore the neighbours and any detached connectors together")
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertEqual(try h.snapshotAll(), joined)
    }

    func testSuspendedJoinRejectsConcurrentEditDeletionAndReadOnlyWithoutHistory() async throws {
        for change in ["edit", "delete", "windowReadOnly", "storeReadOnly"] {
            let h = Harness(features: [FeatObjectMenuFeature.self])
            let input = try params(h)
            h.app.commands.register(CommandDescriptor(id: "test.changeNeighbour", title: "Change neighbour",
                summary: "Concurrent change while the join hook is suspended.", effect: .edit)) { _, ctx in
                try ctx.mutate { tx in
                    if change == "delete" {
                        try tx.delete(item: Fixtures.shapeID, doc: Fixtures.docID, page: Fixtures.page1)
                    } else {
                        var item = try tx.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID)
                        item.shape?.frame.x += 25
                        _ = try tx.put(item, doc: Fixtures.docID, page: Fixtures.page1)
                    }
                }
                return [:]
            }
            var entered = false, resume = false
            h.app.bus.hooks.register(CommandHookDescriptor.guarding(id: "test.pauseJoin", owner: "test",
                commands: [CommandIDs.itemDelete]) { _, _, _ in
                entered = true
                let deadline = Date().addingTimeInterval(3)
                while !resume, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
                guard resume else { throw NibError(.unavailable, "join hook timed out") }
                return nil
            })
            defer { resume = true }
            let join = Task { try await h.run(CommandIDs.itemDelete, input) }
            let deadline = Date().addingTimeInterval(2)
            while !entered, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(entered)
            switch change {
            case "windowReadOnly": h.session.readOnly = true
            case "storeReadOnly": h.app.services.set(NSSet(array: [doc.raw]), for: ServiceKeys.storeReadOnly)
            default: _ = try await h.run("test.changeNeighbour")
            }
            let before = try h.snapshotAll(), depth = h.undoDepth(doc)
            resume = true
            do {
                _ = try await join.value
                XCTFail("The join must fail after \(change)")
            } catch let error as NibError {
                XCTAssertEqual(error.code, change == "storeReadOnly" ? .unsupported : .conflict)
            }
            XCTAssertEqual(try h.snapshotAll(), before)
            XCTAssertEqual(h.undoDepth(doc), depth, "A rejected join must not create a rollback entry")
            h.session.readOnly = false
            h.app.services.set(nil, for: ServiceKeys.storeReadOnly)
            if depth > 0 {
                XCTAssertTrue(h.app.bus.undo(doc))
                XCTAssertThrowsError(try h.app.workspace.item(doc, page: page, id: "JOINED"))
                XCTAssertTrue(h.app.bus.redo(doc))
                XCTAssertEqual(try h.snapshotAll(), before)
            } else {
                XCTAssertFalse(h.app.bus.undo(doc))
                XCTAssertFalse(h.app.bus.redo(doc))
            }
            XCTAssertThrowsError(try h.app.workspace.item(doc, page: page, id: "JOINED"))
        }
    }

    func testConditionalNoOpFailsButUnversionedReadOnlyDeleteRemainsANoOp() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        var input = try XCTUnwrap(try params(h).objectValue)
        input["replacementShape"] = nil
        input["replacementID"] = nil
        let before = try h.snapshotAll()
        h.session.readOnly = true
        do {
            _ = try await h.run(CommandIDs.itemDelete, .object(input))
            XCTFail("Conditional deletion must not succeed with an empty result")
        } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        let legacy = try await h.run(CommandIDs.itemDelete, ["refs": [.string(ref)]])
        XCTAssertEqual(legacy["deleted"], [])
        h.session.readOnly = false
        do {
            _ = try await h.run(CommandIDs.itemDelete, ["refs": [], "expectedRevisions": [:]])
            XCTFail("An empty conditional deletion must fail")
        } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.undoDepth(doc), 0)
    }

    func testInvalidOrCollidingReplacementNeverDeletesNeighbours() async throws {
        for invalid in ["missingRevision", "invalidShape", "existingID", "invalidID"] {
            let h = Harness(features: [FeatObjectMenuFeature.self])
            var input = try XCTUnwrap(try params(h).objectValue)
            switch invalid {
            case "missingRevision": input["expectedRevisions"] = [:]
            case "invalidShape": input["replacementShape"] = try JSONValue.from(ShapeItem(shape: .polyline, frame: Frame(.zero), points: []))
            case "existingID": input["replacementID"] = .string(Fixtures.shapeID.raw)
            default: input["replacementID"] = "not a valid id"
            }
            let before = try h.snapshotAll()
            do {
                _ = try await h.run(CommandIDs.itemDelete, .object(input))
                XCTFail("Invalid replacement must fail: \(invalid)")
            } catch { XCTAssertTrue(error is NibError) }
            XCTAssertEqual(try h.snapshotAll(), before)
            XCTAssertEqual(h.undoDepth(doc), 0)
        }
    }
}
