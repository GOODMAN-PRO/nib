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
