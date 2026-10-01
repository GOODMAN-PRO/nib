import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibDesign
import NibTesting
@testable import FeatTextDocTables

@MainActor
final class FeatTextDocTablesTests: XCTestCase {
    private let doc = Fixtures.textDocID
    private let ref = "block:FIXTUREDOC02/FIXTUREBLK03"
    private func harness() -> Harness {
        let h = Harness(features: [FeatTextDocTablesFeature.self])
        h.session.document = doc
        h.session.page = nil
        return h
    }
    private func table(_ h: Harness) throws -> TableData {
        let b = try XCTUnwrap(h.app.workspace.content(doc).liveBlocks.first { $0.id == Fixtures.tableBlockID })
        return try XCTUnwrap(b.table)
    }
    private func view(_ h: Harness, heightChanged: @escaping @MainActor (CGFloat) -> Void = { _ in }) throws -> TableBlockView {
        let b = try XCTUnwrap(h.app.workspace.content(doc).liveBlocks.first { $0.id == Fixtures.tableBlockID })
        return TableBlockView(context: BlockViewContext(app: h.app, session: h.session, doc: doc,
                                                       block: b, heightChanged: heightChanged))
    }

    /// Keep a real enclosing viewport and window alive so commit/scroll/lifecycle observation is exercised.
    private func mount(_ v: TableBlockView) -> (UIWindow, UIScrollView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        let scroll = UIScrollView(frame: window.bounds)
        controller.view.addSubview(scroll)
        v.frame = CGRect(x: 0, y: 0, width: 600, height: v.reportedHeight)
        scroll.addSubview(v)
        XCTAssertNotNil(v.window)
        v.layoutIfNeeded()
        v.frame.size.height = v.reportedHeight
        scroll.contentSize = v.frame.size
        return (window, scroll)
    }

    private func type(_ text: String, into v: TableBlockView) {
        v.editor.attributedText = TableCellStyle().attributed(RichText(plain: text))
        v.editor.selectedRange = NSRange(location: v.editor.textStorage.length, length: 0)
        v.textViewDidChange(v.editor)
    }

    func testForeignRowInsertionRemapsDebouncedTypingAndKeepsCaret() async throws {
        let h = harness(), v = try view(h)
        let mounted = mount(v)
        defer { withExtendedLifetime(mounted) {} }
        v.beginEditing(at: CellPosition(row: 1, column: 0))
        type("A2x", into: v)
        let caret = v.editor.selectedRange
        try await h.run("table.edit", ["ref": .string(ref), "op": "insertRowBefore", "row": 0])
        XCTAssertEqual(v.editing, CellPosition(row: 2, column: 0))
        XCTAssertEqual(v.editor.selectedRange, caret)
        await v.flushEdits()
        XCTAssertEqual(try table(h).rows[2][0].text.plainText, "A2x")
        XCTAssertEqual(try table(h).rows[1][0].text.plainText, "A1")
    }

    func testForeignColumnInsertionAndRowMoveCarryPendingText() async throws {
        for params: JSONValue in [
            ["ref": .string(ref), "op": "insertColumnBefore", "column": 0],
            ["ref": .string(ref), "op": "moveRow", "row": 1, "to": 0],
            ["ref": .string(ref), "op": "moveColumn", "column": 0, "to": 1]
        ] {
            let h = harness(), v = try view(h)
            let mounted = mount(v)
            defer { withExtendedLifetime(mounted) {} }
            v.beginEditing(at: CellPosition(row: 1, column: 0))
            type("A2x", into: v)
            try await h.run("table.edit", params)
            await v.flushEdits()
            let destination = params["op"]?.stringValue == "moveRow"
                ? CellPosition(row: 0, column: 0) : CellPosition(row: 1, column: 1)
            XCTAssertEqual(v.editing, destination)
            XCTAssertEqual(try table(h).rows[destination.row][destination.column].text.plainText, "A2x")
        }
    }

    func testForeignMergeDropsCoveredPendingTextWithoutOverwritingAnchor() async throws {
        let h = harness(), v = try view(h)
        let mounted = mount(v)
        defer { withExtendedLifetime(mounted) {} }
        v.beginEditing(at: CellPosition(row: 0, column: 1))
        type("B1x", into: v)
        try await h.run("table.edit", ["ref": .string(ref), "op": "merge", "row": 0, "column": 0, "toColumn": 1])
        let merged = try table(h)
        XCTAssertNil(v.editing)
        await v.flushEdits()
        XCTAssertEqual(try table(h), merged)
        XCTAssertEqual(merged.rows[0][0].text.plainText, "A1\nB1")
        XCTAssertEqual(h.undoDepth(doc), 1)
    }

    func testForeignUndoCancelsPendingWriteAndPreservesRedo() async throws {
        let h = harness()
        try await h.run("table.edit", ["ref": .string(ref), "op": "setCell", "row": 0, "column": 0, "text": "Changed"])
        let v = try view(h), mounted = mount(v)
        defer { withExtendedLifetime(mounted) {} }
        v.beginEditing(at: CellPosition(row: 0, column: 0))
        type("Changedx", into: v)
        var writes = 0
        let subscription = h.app.bus.observeCommits { if $0.command == "table.edit" { writes += 1 } }
        defer { subscription.cancel() }
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(v.editor.text, "A1")
        await v.flushEdits()
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try table(h).rows[0][0].text.plainText, "A1")
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertEqual(v.editor.text, "Changed")
    }

    func testUndoAlsoCancelsAnAlreadyEnqueuedTypingWrite() async throws {
        let h = harness()
        try await h.run("table.edit", ["ref": .string(ref), "op": "setCell", "row": 0, "column": 0, "text": "Changed"])
        let v = try view(h), mounted = mount(v)
        defer { withExtendedLifetime(mounted) {} }
        v.beginEditing(at: CellPosition(row: 0, column: 0))
        type("Changedx", into: v)
        v.flushTyping()
        XCTAssertTrue(h.app.bus.undo(doc))
        await v.flushEdits()
        XCTAssertEqual(try table(h).rows[0][0].text.plainText, "A1")
        XCTAssertTrue(h.app.bus.history.canRedo(doc))
    }

    func testForeignDeletionDropsPendingTextWithoutWritingToNeighbour() async throws {
        let h = harness(), v = try view(h), mounted = mount(v)
        defer { withExtendedLifetime(mounted) {} }
        v.beginEditing(at: CellPosition(row: 0, column: 0))
        type("A1x", into: v)
        try await h.run("table.edit", ["ref": .string(ref), "op": "deleteRow", "row": 0])
        XCTAssertNil(v.editing)
        await v.flushEdits()
        XCTAssertEqual(try table(h).rows[0][0].text.plainText, "A2")
        XCTAssertEqual(h.undoDepth(doc), 1)
    }

    func testForeignCellReplacementReloadsEditorAndClampsCaret() async throws {
        let h = harness(), v = try view(h), mounted = mount(v)
        defer { withExtendedLifetime(mounted) {} }
        v.beginEditing(at: CellPosition(row: 0, column: 0))
        type("A1 local", into: v)
        try await h.run("table.edit", ["ref": .string(ref), "op": "setCell", "row": 0, "column": 0, "text": "X"])
        await v.flushEdits()
        XCTAssertEqual(v.editor.text, "X")
        XCTAssertEqual(v.editor.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(try table(h).rows[0][0].text.plainText, "X")
    }

    func testMultipleRowInsertDeleteUndoAndViewRemapping() async throws {
        let h = harness()
        let original = try table(h)
        try await h.run("table.edit", ["ref": .string(ref), "op": "insertRowBefore", "row": 0, "count": 2])
        XCTAssertEqual(try table(h).rows.count, 4)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try table(h), original)
        try await h.run("table.edit", ["ref": .string(ref), "op": "insertRowBefore", "row": 0])
        let threeRows = try table(h)
        let v = try view(h), mounted = mount(v)
        defer { withExtendedLifetime(mounted) {} }
        v.beginEditing(at: CellPosition(row: 2, column: 0))
        try await h.run("table.edit", ["ref": .string(ref), "op": "deleteRow", "row": 0, "count": 2])
        XCTAssertEqual(try table(h).rows.count, 1)
        XCTAssertEqual(v.editing, CellPosition(row: 0, column: 0))
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try table(h), threeRows)
        v.select(.rows(0...2))
        try await h.run("table.edit", ["ref": .string(ref), "op": "deleteRow", "row": 1, "count": 2])
        XCTAssertEqual(v.selection, .rows(0...0))
    }

    func testLifecycleNotificationsFlushTyping() async throws {
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            let h = harness(), v = try view(h), mounted = mount(v)
            defer { withExtendedLifetime(mounted) {} }
            v.beginEditing(at: CellPosition(row: 0, column: 0))
            type("Saved", into: v)
            NotificationCenter.default.post(name: name, object: nil)
            // Wait for the already enqueued write, without calling the flushing helper first.
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(try table(h).rows[0][0].text.plainText, "Saved")
            await v.flushEdits()
        }
    }

    func testLargeTableTypingBudgetAndViewportRecycling() async throws {
        let h = harness()
        h.app.commands.register(TableFixtureWrite.self)
        try await h.run("test.tableFixture", [:])
        let v = try view(h), mounted = mount(v)
        defer { withExtendedLifetime(mounted) {} }
        v.beginEditing(at: CellPosition(row: 0, column: 0))
        let start = Date.timeIntervalSinceReferenceDate
        for i in 1...20 { type("0,0" + String(repeating: "x", count: i), into: v) }
        let elapsed = Date.timeIntervalSinceReferenceDate - start
        let budget = 20.0 * 0.016 // One 60 Hz frame per character, CI gets the architecture's 4× allowance.
        XCTAssertLessThan(elapsed, budget * 4)
        XCTAssertLessThan(v.cellViews.count, 1_500)
        let offscreen = try XCTUnwrap(v.grid.accessibilityDataTableCellElement(forRow: 249, column: 29))
        XCTAssertEqual(offscreen.accessibilityRowRange(), NSRange(location: 249, length: 1))
        XCTAssertEqual((offscreen as? UIAccessibilityElement)?.accessibilityLabel, "249,29")
        mounted.1.contentOffset.y = v.reportedHeight - 600
        XCTAssertNotNil(v.cellViews[CellPosition(row: 249, column: 29)])
        XCTAssertNil(v.cellViews[CellPosition(row: 0, column: 0)])
        XCTAssertLessThan(v.cellViews.count, 1_500)
        await v.flushEdits()
        XCTAssertEqual(try table(h).rows[0][0].text.plainText, "0,0" + String(repeating: "x", count: 20))
    }

    func testReorderResizeGeometryAndMergeSplitReadOnlyMenus() throws {
        XCTAssertEqual(TableLayout.moveDestination(source: 2, boundary: 4), 3)
        XCTAssertEqual(TableLayout.nearestBoundary(5, offsets: [0, 10, 20]), 0)
        XCTAssertEqual(TableLayout.nearestBoundary(5.1, offsets: [0, 10, 20]), 1)
        XCTAssertEqual(TableLayout.nearestBoundary(15, offsets: [0, 10, 20]), 1)
        let layout = TableGridLayout(columnWidths: [44, 44, 44], rowHeights: [44])
        XCTAssertEqual(layout.divider(near: 70, slop: 30), 1)
        XCTAssertEqual(layout.divider(near: 45, slop: 3), 0)
        XCTAssertNil(layout.divider(near: 50, slop: 3))
        var t = TableOps.empty(rows: 2, columns: 2)
        let target = TableMenuTarget.cells(CellRange(row: 0, column: 0, toRow: 1, toColumn: 1))
        XCTAssertTrue(TableMenus.sections(for: target, in: t, readOnly: false).flatMap(\.items).contains { $0.id == "merge" })
        try TableOps.merge(&t, target.range(in: t)!)
        let items = TableMenus.sections(for: target, in: t, readOnly: false).flatMap(\.items)
        XCTAssertTrue(items.contains { $0.id == "split" })
        XCTAssertFalse(items.contains { $0.id == "merge" })
        for target: TableMenuTarget in [target, .rows(0...0), .columns(0...0), .table] {
            let sections = TableMenus.sections(for: target, in: t, readOnly: true)
            XCTAssertFalse(sections.contains { $0.id == "insert" || $0.id == "delete" || $0.id == "add" })
            XCTAssertFalse(sections.flatMap(\.items).contains { $0.id == "merge" || $0.id == "split" })
        }
    }

    func testConformanceAndRegistryIntegration() async throws {
        let problems = await CommandConformance.check(features: [FeatTextDocTablesFeature.self])
        XCTAssertEqual(problems, [])
        let h = harness()
        XCTAssertEqual(Set(h.app.commands.all().filter { $0.owner == "tables" }.map { $0.id }), ["table.edit", "table.exportCSV"])
        let descriptor = try XCTUnwrap(h.app.ui.blockViews.get("table"))
        XCTAssertEqual(descriptor.owner, "tables")
        let kind = try XCTUnwrap(h.app.content.blockKinds.get(TableFeatureParts.blockKindID))
        XCTAssertEqual(kind.kind, .table)
        XCTAssertTrue(kind.aliases.contains("grid"))
        let exporter = try XCTUnwrap(h.app.content.exporters.get(TableExport.exporterID))
        XCTAssertEqual(exporter.docKinds, [.textDocument])
        XCTAssertEqual(exporter.fileExtension, "csv")
        XCTAssertEqual(h.app.ui.menus.all.filter { $0.owner == "tables" }.count, 3)
    }

    func testEveryEditExamplePassesUndoAndRedoRoundTrip() async throws {
        for example in TableEdit.descriptor.examples {
            let h = harness()
            let before = try h.snapshot(doc)
            try await h.run("table.edit", example)
            let after = try h.snapshot(doc)
            XCTAssertNotEqual(before, after)
            XCTAssertTrue(TableOps.isConsistent(try table(h)))
            XCTAssertEqual(h.undoDepth(doc), 1)
            XCTAssertTrue(h.app.bus.undo(doc))
            XCTAssertEqual(try h.snapshot(doc), before)
            XCTAssertTrue(h.app.bus.redo(doc))
            XCTAssertNotEqual(try h.snapshot(doc), before)
        }
        let h = harness()
        let before = try h.snapshot(doc)
        try await h.run("table.edit", ["ref": .string(ref), "op": "merge", "row": 0, "column": 0, "toColumn": 1])
        let merged = try table(h)
        try await h.run("table.edit", ["ref": .string(ref), "op": "split", "row": 0, "column": 1])
        XCTAssertTrue(try table(h).merges.isEmpty)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try table(h), merged)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(doc), before)
    }

    func testNoOpDoesNotAddUndoAndInvalidCommandIsAtomic() async throws {
        let h = harness()
        let before = try h.snapshot(doc)
        try await h.run("table.edit", ["ref": .string(ref), "op": "setCell", "row": 0, "column": 0, "text": "A1"])
        XCTAssertEqual(h.undoDepth(doc), 0)
        for params: JSONValue in [
            ["ref": .string(ref), "op": "deleteRow", "row": 0, "count": 2],
            ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "op": "setBorders"],
            ["ref": "doc:FIXTUREDOC02", "op": "setBorders"],
            ["ref": .string(ref), "op": "setCell", "row": 0],
            ["ref": .string(ref), "op": "unknown"]
        ] {
            do { try await h.run("table.edit", params); XCTFail("invalid command accepted") }
            catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
            XCTAssertEqual(try h.snapshot(doc), before)
            XCTAssertEqual(h.undoDepth(doc), 0)
        }
        h.session.readOnly = true
        do {
            try await h.run("table.edit", ["ref": .string(ref), "op": "setBorders", "borders": false])
            XCTFail("read-only document was edited")
        } catch {}
        XCTAssertEqual(try h.snapshot(doc), before)
    }

    func testCSVCommandCreatesUTF8AssetWithoutUndoAndRefusesLockedExport() async throws {
        let h = harness()
        let before = try h.snapshot(doc)
        let result = try await h.run("table.exportCSV", ["ref": .string(ref)])
        XCTAssertEqual(result["csv"]?.stringValue, "A1,B1\r\nA2,B2\r\n")
        let asset = try XCTUnwrap(result["asset"]?.stringValue)
        let url = try XCTUnwrap(h.assets.temporaryURL(AssetRef(String(asset.dropFirst(4)))))
        XCTAssertEqual(try Data(contentsOf: url), TableExport.fileData("A1,B1\r\nA2,B2\r\n"))
        XCTAssertEqual(try h.snapshot(doc), before)
        XCTAssertEqual(h.undoDepth(doc), 0)
        h.app.services.lock = FakeLockService(locked: [doc])
        do { try await h.run("table.exportCSV", ["ref": .string(ref)]); XCTFail("locked export accepted") }
        catch let error as NibError { XCTAssertEqual(error.code, .locked) }
    }

    func testExporterWritesRealCSVAndSanitizesNames() async throws {
        let h = harness()
        h.app.commands.register(TableExporterProbe.self)
        let result = try await h.run("test.tableExport", [:])
        let urls = try XCTUnwrap(result.arrayValue).compactMap { $0.stringValue }.map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(urls.count, 1)
        let url = try XCTUnwrap(urls.first)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.lastPathComponent, "Chosen-Name.csv")
        XCTAssertEqual(try Data(contentsOf: url), TableExport.fileData("A1,B1\r\nA2,B2\r\n"))
        XCTAssertEqual(TableExport.fileName("Physics.csv", index: 1, of: 2), "Physics – Table 2.csv")
    }

    func testEditorTypingNewlineAndUndoProxyUseDocumentHistory() async throws {
        let h = harness()
        let v = try view(h)
        XCTAssertTrue(v.undoProxy.owner === v)
        let before = try table(h)
        v.beginEditing(at: CellPosition(row: 0, column: 0))
        XCTAssertTrue(v.textView(v.editor, shouldChangeTextIn: NSRange(location: 2, length: 0), replacementText: "\n"))
        v.editor.attributedText = TableCellStyle().attributed(RichText(plain: "First\nSecond"))
        v.textViewDidChange(v.editor)
        XCTAssertTrue(v.undoProxy.canUndo, "pending text can be undone before debounce")
        await v.flushEdits()
        XCTAssertEqual(try table(h).rows[0][0].text.plainText, "First\nSecond")
        XCTAssertEqual(h.undoDepth(doc), 1)
        v.undoProxy.undo()
        await v.flushEdits()
        XCTAssertEqual(try table(h), before)
        XCTAssertTrue(v.undoProxy.canRedo)
        v.undoProxy.redo()
        await v.flushEdits()
        XCTAssertEqual(try table(h).rows[0][0].text.plainText, "First\nSecond")
    }

    func testSelectAllTwiceSelectsTableAndFloatingMenuUsesHost() throws {
        let h = harness()
        let host = TableTestFloatingHost()
        h.session.floatingHost = host
        let v = try view(h)
        v.beginEditing(at: CellPosition(row: 0, column: 0))
        v.editor.selectedRange = NSRange(location: 1, length: 0)
        v.editor.selectAll(nil)
        XCTAssertEqual(v.editor.selectedRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(v.selection, .none)
        v.editor.selectAll(nil)
        XCTAssertEqual(v.selection, .table)
        v.openMenu(.table, from: v, rect: CGRect(x: 0, y: 0, width: 44, height: 44))
        XCTAssertTrue(host.isPresenting(v.menu.popoverID))
        XCTAssertTrue(host.anchors.contains(v.menu.anchorID))
        XCTAssertTrue(v.menu.sections.contains { $0.kind == .borders })
        v.closeMenus(dismiss: true)
        XCTAssertFalse(host.isPresenting(v.menu.popoverID))
        XCTAssertTrue(host.anchors.isEmpty)
    }

    func testTabAndShiftTabUsePriorityCommandsBetweenCells() throws {
        let h = harness()
        let v = try view(h)
        v.beginEditing(at: CellPosition(row: 0, column: 0))
        let forward = try XCTUnwrap(v.editor.keyCommands?.first { $0.input == "\t" && $0.modifierFlags.isEmpty })
        let backward = try XCTUnwrap(v.editor.keyCommands?.first { $0.input == "\t" && $0.modifierFlags == .shift })
        XCTAssertTrue(forward.wantsPriorityOverSystemBehavior)
        v.navigationKey(forward)
        XCTAssertEqual(v.editing, CellPosition(row: 0, column: 1))
        v.navigationKey(backward)
        XCTAssertEqual(v.editing, CellPosition(row: 0, column: 0))
        XCTAssertGreaterThanOrEqual(v.cellFrame(CellPosition(row: 0, column: 0)).minY, NibMetrics.hitTarget)
    }

    func testLargeCSVResultRemainsAvailableInAssetWhenInlineResultIsCapped() async throws {
        let h = harness()
        let text = String(repeating: "ไทย", count: NibLimits.aiToolResultBytes)
        try await h.run("table.edit", ["ref": .string(ref), "op": "setCell", "row": 0, "column": 0, "text": .string(text)])
        let result = try await h.run("table.exportCSV", ["ref": .string(ref)])
        XCTAssertNil(result["csv"])
        XCTAssertEqual(result["truncated"]?.boolValue, true)
        let asset = try XCTUnwrap(result["asset"]?.stringValue)
        let url = try XCTUnwrap(h.assets.temporaryURL(AssetRef(String(asset.dropFirst(4)))))
        let contents = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(contents.contains(text))
    }

    func testNarrowLayoutAutoHeightAndSlashQueryHandleUnicode() throws {
        let h = harness()
        let v = try view(h)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        v.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(v.layout.rowHeights.min() ?? 0, NibMetrics.hitTarget)
        let widths = TableLayout.columnWidths([200, 0, 0], count: 3, available: 300, minimumAuto: 88)
        XCTAssertEqual(widths, [200, 88, 88])
        let heights = TableLayout.rowHeights(count: 2, cells: [.init(range: CellRange(row: 0, column: 0, toRow: 1), height: 150)], minimum: 44)
        XCTAssertEqual(heights, [44, 106])
        let text = "📝 /row"
        XCTAssertEqual(TableSlash.query(in: text, caret: (text as NSString).length)?.location, 3)
        XCTAssertNil(TableSlash.query(in: "https://example", caret: 15))
        let items = TableSlash.filter(TableSlash.items(for: CellPosition(row: 0, column: 0), in: try table(h)), query: "CSV")
        XCTAssertEqual(items.first?.id, "csv")
    }

    func testCellStylePreservesChosenFormattingAndDoesNotPersistReadingFont() {
        let style = TableCellStyle()
        let text = RichText(plain: "Bold\nNext", attrs: TextAttributes(bold: true, underline: true))
        let restored = style.richText(from: style.attributed(text))
        XCTAssertEqual(restored.plainText, text.plainText)
        XCTAssertEqual(restored.paragraphs.first?.runs.first?.attrs.bold, true)
        XCTAssertEqual(restored.paragraphs.first?.runs.first?.attrs.underline, true)
        XCTAssertNil(restored.paragraphs.first?.runs.first?.attrs.font)
        XCTAssertNil(restored.paragraphs.first?.runs.first?.attrs.size)
    }
}

@MainActor
private final class TableTestFloatingHost: FloatingHosting {
    var views: [String: AnyView] = [:]
    var anchors = Set<String>()
    func present(_ id: String, content: AnyView) { views[id] = content }
    func dismiss(_ id: String) { views[id] = nil }
    func isPresenting(_ id: String) -> Bool { views[id] != nil }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool { anchors.insert(id); return true }
    func removeAnchor(_ id: String) { anchors.remove(id) }
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { rect }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {}
}

private struct TableExporterProbe: NibCommand {
    struct Params: Codable {}
    static let descriptor = CommandDescriptor(id: "test.tableExport", title: "Test export", summary: "Exercise registered exporter",
                                              params: .obj([:]), examples: [[:]], effect: .read)
    static func run(_ params: Params, _ ctx: CommandContext) async throws -> [String] {
        let exporter = try XCTUnwrap(ctx.content.exporters.get(TableExport.exporterID))
        return try await exporter.handler(ExportRequest(documents: [Fixtures.textDocID], fileName: "Chosen/Name"), ctx).map { $0.path }
    }
}

private struct TableFixtureWrite: NibCommand {
    struct Params: Codable {}
    static let descriptor = CommandDescriptor(id: "test.tableFixture", title: "Fill Table", summary: "Large table fixture",
                                              params: .obj([:]), examples: [[:]], effect: .edit)
    static func run(_ params: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ctx.mutate { tx in
            var block = try XCTUnwrap(tx.content(Fixtures.textDocID).liveBlocks.first { $0.id == Fixtures.tableBlockID })
            block.table = TableData(rows: (0..<250).map { r in (0..<30).map { c in
                TableCell(text: RichText(plain: "\(r),\(c)"))
            } })
            try tx.put(block, doc: Fixtures.textDocID)
        }
        return NoResult()
    }
}
