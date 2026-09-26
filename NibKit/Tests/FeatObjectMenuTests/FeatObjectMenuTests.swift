import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibTesting
@testable import FeatObjectMenu

/// A window's floating host as the tests see it: what is presented, where the anchors are, and container rects equal
/// to the canvas view's.
@MainActor
final class FakeFloatingHost: FloatingHosting {
    private(set) var presented: [String: AnyView] = [:]
    private(set) var anchors: [String: CGRect] = [:]
    private(set) var toasts: [String] = []

    func present(_ id: String, content: AnyView) { presented[id] = content }
    func dismiss(_ id: String) { presented[id] = nil }
    func isPresenting(_ id: String) -> Bool { presented[id] != nil }

    @discardableResult
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool {
        anchors[id] = rect
        return true
    }

    func removeAnchor(_ id: String) { anchors[id] = nil }
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { rect }

    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) { toasts.append(message) }
}

@MainActor
final class FeatObjectMenuTests: XCTestCase {
    private var doc: DocumentID { Fixtures.docID }
    private var page: PageID { Fixtures.page1 }

    private func ref(_ id: ElementID, _ page: PageID = Fixtures.page1, _ doc: DocumentID = Fixtures.docID) -> JSONValue {
        .string(NodeRef.item(doc, page, id).description)
    }

    private func item(_ h: Harness, _ id: ElementID, page: PageID = Fixtures.page1) throws -> Item {
        try h.app.workspace.item(Fixtures.docID, page: page, id: id)
    }

    /// Edits a fixture item before the workspace loads the page.
    private func edit(_ h: Harness, _ id: ElementID, _ change: (inout Item) -> Void) {
        guard var items = h.persistence.pageItems[Fixtures.docID]?[Fixtures.page1],
              let i = items.firstIndex(where: { $0.id == id }) else { return XCTFail("fixture \(id) missing") }
        change(&items[i])
        h.persistence.pageItems[Fixtures.docID]?[Fixtures.page1] = items
    }

    private func order(_ h: Harness) throws -> [ElementID] {
        try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).map { $0.id }
    }

    private func select(_ h: Harness, _ ids: [ElementID], bounds: Rect? = nil) {
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: ids, bounds: bounds)
    }

    /// Ids of this feature's entries a menu shows at `location` for the window's selection.
    private func visible(_ h: Harness, _ location: MenuLocation, point: Point? = nil) -> [String] {
        let ctx = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1, point: point,
                              selection: h.session.selection)
        return h.app.ui.menuItems(location, ctx).filter { $0.owner == FeatObjectMenuFeature.id }.map { $0.id }
    }

    private func context(_ h: Harness, point: Point? = nil) -> MenuContext {
        MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1, point: point,
                    selection: h.session.selection)
    }

    private func withPasteboard(_ hasContent: Bool, _ body: () async throws -> Void) async rethrows {
        let saved = ObjectMenuEntries.pasteboardHasContent
        ObjectMenuEntries.pasteboardHasContent = { hasContent }
        defer { ObjectMenuEntries.pasteboardHasContent = saved }
        try await body()
    }

    // MARK: Registration

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatObjectMenuFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersExactlyItsCommands() {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let ids = Set(h.app.commands.all().filter { $0.owner == FeatObjectMenuFeature.id }.map { $0.id })
        XCTAssertEqual(ids, ["item.delete", "item.arrange", "item.recolor", "item.setLocked", "selection.screenshot",
                             "menu.showAt"])
        XCTAssertEqual(h.app.commands.descriptor("item.delete")?.destructive, true)
        XCTAssertEqual(h.app.commands.descriptor("selection.screenshot")?.effect, .read)
        XCTAssertEqual(h.app.commands.descriptor("menu.showAt")?.effect, .session)
    }

    func testKeysLongPressToolPanelAndAttachmentAreRegistered() {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let keys = h.app.content.keyCommands.all.filter { $0.owner == FeatObjectMenuFeature.id }
        let delete = keys.first { $0.shortcut == KeyShortcut("delete") }
        XCTAssertEqual(delete?.command, "item.delete")
        XCTAssertEqual(delete?.scope, .canvas)
        XCTAssertEqual(keys.first { $0.shortcut == KeyShortcut("]", [.command, .option, .shift]) }?.params["to"], "front")
        XCTAssertEqual(keys.first { $0.shortcut == KeyShortcut("l", [.command]) }?.params["locked"], true)
        let handler = h.app.content.tapHandlers.get("objectmenu.pageLongPress")
        XCTAssertEqual(handler?.gesture, .longPress)
        XCTAssertEqual(handler?.command, "menu.showAt")
        XCTAssertEqual(handler?.worksInReadOnly, true)
        XCTAssertNotNil(h.app.ui.canvasTools.get(ObjectMenuIDs.screenshotTool))
        XCTAssertNotNil(h.app.ui.canvasAttachments.get(ObjectMenuIDs.attachment))
        XCTAssertEqual(h.app.ui.panels.get(ObjectMenuIDs.stylePanel)?.placement, .floating)
    }

    // MARK: item.delete

    func testDeletingAShapeDetachesItsConnectorInOneUndoStep() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let before = try h.snapshot()
        let out = try await h.run("item.delete", ["refs": [ref(Fixtures.shapeID)]])
        XCTAssertEqual(out["deleted"], .array([ref(Fixtures.shapeID)]))
        XCTAssertEqual(out["detached"], .array([ref(Fixtures.connectorID)]))
        XCTAssertThrowsError(try item(h, Fixtures.shapeID))
        let connector = try XCTUnwrap(try item(h, Fixtures.connectorID).connector)
        XCTAssertNil(connector.from.item)
        XCTAssertEqual(connector.from.point, Point(260, 245))        // stays where the shape's side was
        XCTAssertEqual(connector.to.item, Fixtures.stickyID)
        XCTAssertEqual(h.undoDepth(doc), 1)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testDeletingBothEndsDeletesTheConnector() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let out = try await h.run("item.delete", ["refs": [ref(Fixtures.shapeID), ref(Fixtures.stickyID)]])
        XCTAssertEqual(out["deleted"], .array([ref(Fixtures.shapeID), ref(Fixtures.stickyID), ref(Fixtures.connectorID)]))
        XCTAssertEqual(out["detached"], .array([]))
        XCTAssertThrowsError(try item(h, Fixtures.connectorID))
    }

    func testAttachedContentsGoAndCommentThreadsStay() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        edit(h, Fixtures.textID) { $0.attachedTo = Fixtures.shapeID }
        edit(h, Fixtures.commentID) { $0.attachedTo = Fixtures.shapeID }
        let before = try h.snapshot()
        let out = try await h.run("item.delete", ["refs": [ref(Fixtures.shapeID)]])
        let deleted = out["deleted"]?.arrayValue ?? []
        XCTAssertTrue(deleted.contains(ref(Fixtures.textID)))
        XCTAssertFalse(deleted.contains(ref(Fixtures.commentID)))
        XCTAssertNil(try item(h, Fixtures.commentID).attachedTo)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testDeletePlanIsPure() {
        let a = Item(id: "A", kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 10, h: 10)))
        let b = Item(id: "B", kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 50, y: 0, w: 10, h: 10)))
        var child = Item(id: "C", kind: .text, text: TextBoxItem(frame: Frame(x: 1, y: 1, w: 5, h: 5), text: RichText(plain: "x")))
        child.attachedTo = "A"
        let link = Item(id: "L", kind: .connector,
                        connector: ConnectorItem(from: ConnectorEnd(point: Point(10, 5), item: "A", side: 1, t: 0.5),
                                                 to: ConnectorEnd(point: Point(50, 5), item: "B", side: 3, t: 0.5)))
        let one = DeletePlan.make(targets: ["A"], items: [a, b, child, link])
        XCTAssertEqual(one.deleted, ["A", "C"])
        XCTAssertEqual(one.updated.map { $0.id }, ["L"])
        XCTAssertNil(one.updated.first?.connector?.from.item)
        XCTAssertEqual(one.updated.first?.connector?.to.item, "B")
        let both = DeletePlan.make(targets: ["A", "B"], items: [a, b, child, link])
        XCTAssertEqual(both.deleted, ["A", "B", "C", "L"])
        XCTAssertEqual(both.updated, [])
    }

    func testLockedItemsAreRefusedAndNothingChanges() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        edit(h, Fixtures.imageID) { $0.locked = true }
        let before = try h.snapshot()
        for (command, extra) in [("item.delete", [:] as JSONValue), ("item.arrange", ["to": "front"] as JSONValue),
                                 ("item.recolor", ["color": "#2156D9"] as JSONValue)] {
            var params = try XCTUnwrap(extra.objectValue)
            params["refs"] = .array([ref(Fixtures.strokeID), ref(Fixtures.imageID)])
            do {
                try await h.run(command, .object(params))
                XCTFail("\(command) changed a locked item")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
                XCTAssertEqual(e.path, "$.refs[1]")
                XCTAssertTrue(e.hint?.contains("item.setLocked") == true)
            }
        }
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testDeletingTheSelectionUsesAndClearsIt() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        select(h, [Fixtures.strokeID, Fixtures.textID])
        try await h.run("item.delete")                                  // a key command: no refs, the selection
        XCTAssertThrowsError(try item(h, Fixtures.strokeID))
        XCTAssertThrowsError(try item(h, Fixtures.textID))
        XCTAssertTrue(h.session.selection.isEmpty)
        let nothing = try await h.run("item.delete")                    // nothing selected: nothing happens
        XCTAssertEqual(nothing["deleted"], .array([]))
    }

    func testPartOfTheSelectionDeletedKeepsTheRest() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        select(h, [Fixtures.strokeID, Fixtures.imageID])
        try await h.run("item.delete", ["refs": [ref(Fixtures.strokeID)]])
        XCTAssertEqual(h.session.selection.items, [Fixtures.imageID])
        XCTAssertEqual(h.session.selection.bounds, try item(h, Fixtures.imageID).bounds)
    }

    func testOtherCallersMustNameTheItems() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        do {
            try await h.run("item.delete", ["refs": []], as: .ai("chat"))
            XCTFail("an empty delete from the AI went through")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.refs")
        }
        do {
            try await h.run("item.delete", ["refs": ["page:FIXTUREDOC01/FIXTUREPG001"]])
            XCTFail("a page ref was accepted")
        } catch let e as NibError {
            XCTAssertEqual(e.path, "$.refs[0]")
        }
    }

    // MARK: item.arrange

    func testArrangeFrontBackForwardBackwardAndUndo() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let start = try order(h)
        try await h.run("item.arrange", ["refs": [ref(Fixtures.shapeID)], "to": "front"])
        XCTAssertEqual(try order(h).last, Fixtures.shapeID)
        try await h.run("item.arrange", ["refs": [ref(Fixtures.shapeID)], "to": "back"])
        XCTAssertEqual(try order(h).first, Fixtures.shapeID)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try order(h), start)
        // Forward passes the nearest overlapping item above (the connector), not just the next one in the list.
        let out = try await h.run("item.arrange", ["refs": [ref(Fixtures.shapeID)], "to": "forward"])
        XCTAssertEqual(out["moved"], .array([ref(Fixtures.shapeID)]))
        var now = try order(h)
        XCTAssertEqual(now.firstIndex(of: Fixtures.shapeID), try XCTUnwrap(now.firstIndex(of: Fixtures.connectorID)) + 1)
        try await h.run("item.arrange", ["refs": [ref(Fixtures.shapeID)], "to": "backward"])
        now = try order(h)
        XCTAssertEqual(try XCTUnwrap(now.firstIndex(of: Fixtures.shapeID)) + 1, now.firstIndex(of: Fixtures.connectorID))
        // Nothing overlaps below the custom box: a step backward changes nothing.
        let none = try await h.run("item.arrange", ["refs": [ref(Fixtures.customID)], "to": "backward"])
        XCTAssertEqual(none["moved"], .array([]))
    }

    func testArrangePlannerOrdersAndKeys() {
        let ids: [ElementID] = ["A", "B", "C", "D", "E"]
        XCTAssertEqual(ArrangePlanner.reorder(ids, moving: ["B", "D"], to: .front) { _ in true }, ["A", "C", "E", "B", "D"])
        XCTAssertEqual(ArrangePlanner.reorder(ids, moving: ["B", "D"], to: .back) { _ in true }, ["B", "D", "A", "C", "E"])
        XCTAssertEqual(ArrangePlanner.reorder(ids, moving: ["B"], to: .forward) { $0 == "D" }, ["A", "C", "D", "B", "E"])
        XCTAssertEqual(ArrangePlanner.reorder(ids, moving: ["D"], to: .backward) { $0 == "B" }, ["A", "D", "B", "C", "E"])
        XCTAssertEqual(ArrangePlanner.reorder(ids, moving: ["E"], to: .forward) { _ in true }, ids)
        let z: [ElementID: String] = ["A": "V", "B": "W", "C": "X", "E": "Z"]
        let keys = try? XCTUnwrap(ArrangePlanner.keys(for: ["A", "C", "B", "E"], moving: ["B"], z: z))
        XCTAssertEqual(keys?.count, 1)
        XCTAssertGreaterThan(keys?["B"] ?? "", "X")
        XCTAssertLessThan(keys?["B"] ?? "~", "Z")
        // Two fixed neighbours with one key (a merge tie): the page is re-keyed instead.
        XCTAssertNil(ArrangePlanner.keys(for: ["A", "C", "B", "D"], moving: ["B"], z: ["A": "V", "B": "W", "C": "X", "D": "X"]))
        let rekeyed = ArrangePlanner.rekey(["B", "A"], z: ["A": "V", "B": "W"])
        XCTAssertLessThan(rekeyed["B"] ?? "~", rekeyed["A"] ?? "V")
    }

    func testAttachedItemsTravelWithTheirContainer() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        edit(h, Fixtures.textID) { $0.attachedTo = Fixtures.shapeID }
        try await h.run("item.arrange", ["refs": [ref(Fixtures.shapeID)], "to": "front"])
        XCTAssertEqual(Array(try order(h).suffix(2)), [Fixtures.shapeID, Fixtures.textID])
    }

    // MARK: item.recolor

    func testRecolorInkShapesTextAndStickiesInOneUndoStep() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        edit(h, Fixtures.shapeID) { $0.shape?.style.fillColor = RGBA(255, 255, 0, 64) }
        let before = try h.snapshot()
        let out = try await h.run("item.recolor", [
            "refs": [ref(Fixtures.strokeID), ref(Fixtures.shapeID), ref(Fixtures.textID), ref(Fixtures.stickyID),
                     ref(Fixtures.imageID)],
            "color": "#2156D9"
        ])
        let blue = try XCTUnwrap(RGBA(hex: "#2156D9"))
        XCTAssertEqual(try item(h, Fixtures.strokeID).stroke?.style.color, blue)
        XCTAssertEqual(try item(h, Fixtures.shapeID).shape?.style.strokeColor, blue)
        XCTAssertEqual(try item(h, Fixtures.shapeID).shape?.style.fillColor, RGBA(0x21, 0x56, 0xD9, 64))
        XCTAssertEqual(try item(h, Fixtures.textID).text?.text.paragraphs.first?.runs.first?.attrs.color, blue)
        XCTAssertEqual(try item(h, Fixtures.stickyID).sticky?.color, blue)
        XCTAssertEqual(out["skipped"], .array([ref(Fixtures.imageID)]))
        XCTAssertEqual(h.undoDepth(doc), 1)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testRecolorRules() {
        let highlighter = Item(kind: .stroke, stroke: Stroke(style: .defaultHighlighter, points: []))
        XCTAssertEqual(Recolor.apply(highlighter, color: RGBA(1, 2, 3))?.stroke?.style.color,
                       RGBA(1, 2, 3, RGBA.highlighterAlpha))
        var patterned = InkStyle.defaultTape
        patterned.tapePattern = AssetRef("dots.png")
        XCTAssertNil(Recolor.apply(Item(kind: .stroke, stroke: Stroke(style: patterned, points: [])), color: .black))
        let fillOnly = ShapeItemStyle(strokeColor: nil, fillColor: RGBA(0, 0, 0, 128))
        let recoloured = Recolor.outlineAndFill(fillOnly, RGBA(10, 20, 30))
        XCTAssertNil(recoloured.strokeColor)
        XCTAssertEqual(recoloured.fillColor, RGBA(10, 20, 30, 128))
        XCTAssertFalse(Recolor.canRecolor(Item(kind: .image, image: ImageItem(frame: Frame(x: 0, y: 0, w: 1, h: 1),
                                                                                asset: AssetRef("a.png")))))
    }

    func testRecolorRefusesWhatHasNoColourAndBadColours() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        do {
            try await h.run("item.recolor", ["refs": [ref(Fixtures.imageID)], "color": "#000000"])
            XCTFail("an image was recoloured")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        do {
            try await h.run("item.recolor", ["refs": [ref(Fixtures.strokeID)], "color": "blue"])
            XCTFail("a colour name was accepted")
        } catch let e as NibError {
            XCTAssertEqual(e.path, "$.color")
        }
        XCTAssertEqual(h.undoDepth(doc), 0)
    }

    // MARK: item.setLocked

    func testLockAndUnlock() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let before = try h.snapshot()
        let out = try await h.run("item.setLocked", ["refs": [ref(Fixtures.imageID), ref(Fixtures.strokeID)], "locked": true])
        XCTAssertEqual(out["changed"], .array([ref(Fixtures.imageID)]))
        XCTAssertEqual(out["skipped"], .array([ref(Fixtures.strokeID)]))
        XCTAssertTrue(try item(h, Fixtures.imageID).locked)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before)
        try await h.run("item.setLocked", ["refs": [ref(Fixtures.imageID)], "locked": true])
        try await h.run("item.setLocked", ["refs": [ref(Fixtures.imageID)], "locked": false])
        XCTAssertFalse(try item(h, Fixtures.imageID).locked)
        do {
            try await h.run("item.setLocked", ["refs": [ref(Fixtures.strokeID)], "locked": true])
            XCTFail("ink was locked")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    // MARK: selection.screenshot

    func testScreenshotPixelSizeIsRectTimesScale() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        h.app.services.renderer = FakeRenderer()
        let out = try await h.run("selection.screenshot", ["page": "page:FIXTUREDOC01/FIXTUREPG001",
                                                          "rect": [72, 100, 300, 200], "scale": 2])
        let asset = try XCTUnwrap(out["asset"]?.stringValue)
        XCTAssertTrue(asset.hasPrefix("tmp:"))
        XCTAssertEqual(out["pxPerPt"], 2)
        let size = try XCTUnwrap(out["pixelSize"]?.arrayValue?.compactMap { $0.intValue })
        XCTAssertLessThanOrEqual(abs(size[0] - 600), 1)
        XCTAssertLessThanOrEqual(abs(size[1] - 400), 1)
        let url = try XCTUnwrap(h.assets.temporaryURL(AssetRef(String(asset.dropFirst(4)))))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        XCTAssertLessThanOrEqual(abs(image.width - 600), 1)
        XCTAssertLessThanOrEqual(abs(image.height - 400), 1)
    }

    func testScreenshotGoesThroughRenderPageWithTheRegion() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        var received: JSONValue?
        let assets = h.assets
        h.app.commands.register(CommandDescriptor(id: "render.page", title: "Render Page", summary: "Test stand-in.",
                                                  effect: .read, exposure: .ui)) { params, _ in
            received = params
            let png = try XCTUnwrap(UIImage(cgImage: FakeRenderer.blank(CGSize(width: 600, height: 400))).pngData())
            let stored = try assets.putTemporary(png, ext: "png")
            return ["asset": .string("tmp:" + stored.name), "pxPerPt": 2, "region": [72, 100, 300, 200]]
        }
        let out = try await h.run("selection.screenshot", ["page": "page:FIXTUREDOC01/FIXTUREPG003",
                                                          "rect": [72, 100, 300, 200]])
        XCTAssertEqual(received?["page"], "page:FIXTUREDOC01/FIXTUREPG003")
        XCTAssertEqual(received?["region"], [72, 100, 300, 200])
        XCTAssertEqual(received?["scale"], 2)
        XCTAssertEqual(out["pixelSize"], [600, 400])
        XCTAssertEqual(out["rect"], [72, 100, 300, 200])
    }

    func testScreenshotLongEdgeCapAndSelectionDefault() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        h.app.services.renderer = FakeRenderer()
        let big = try await h.run("selection.screenshot", ["page": "page:FIXTUREDOC01/FIXTUREPG001",
                                                          "rect": [0, 0, 1000, 500], "scale": 4])
        let scale = try XCTUnwrap(big["pxPerPt"]?.doubleValue)
        XCTAssertLessThan(scale, 4)
        let size = try XCTUnwrap(big["pixelSize"]?.arrayValue?.compactMap { $0.intValue })
        XCTAssertLessThanOrEqual(size[0], 1568)
        XCTAssertLessThanOrEqual(abs(Double(size[0]) - 1000 * scale), 1)
        // The user from a menu or key: the selection's bounds on the window's page.
        select(h, [Fixtures.imageID], bounds: Rect(x: 320, y: 480, width: 64, height: 64))
        let mine = try await h.run("selection.screenshot")
        XCTAssertEqual(mine["rect"], [320, 480, 64, 64])
        do {
            try await h.run("selection.screenshot", ["page": "page:FIXTUREDOC01/FIXTUREPG001"], as: .ai("chat"))
            XCTFail("a screenshot without a rect")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    // MARK: Object menu entries

    func testObjectMenuForInk() {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        XCTAssertEqual(visible(h, .objectMenu), [])                     // nothing selected: no object menu
        select(h, [Fixtures.strokeID])
        XCTAssertEqual(visible(h, .objectMenu), [
            ObjectMenuIDs.cut, ObjectMenuIDs.copy, ObjectMenuIDs.duplicate, ObjectMenuIDs.delete, ObjectMenuIDs.colour,
            ObjectMenuIDs.arrange(.front), ObjectMenuIDs.arrange(.forward), ObjectMenuIDs.arrange(.backward),
            ObjectMenuIDs.arrange(.back), ObjectMenuIDs.screenshot
        ])                                                                 // ink does not lock; no inspector: no Style
    }

    func testLockedSelectionSwapsDeleteForUnlock() {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        edit(h, Fixtures.imageID) { $0.locked = true }
        select(h, [Fixtures.imageID])
        let ids = visible(h, .objectMenu)
        XCTAssertTrue(ids.contains(ObjectMenuIDs.unlock))
        XCTAssertTrue(ids.contains(ObjectMenuIDs.copy))
        for hidden in [ObjectMenuIDs.delete, ObjectMenuIDs.cut, ObjectMenuIDs.duplicate, ObjectMenuIDs.lock,
                       ObjectMenuIDs.arrange(.front)] {
            XCTAssertFalse(ids.contains(hidden), hidden)
        }
        let unlock = h.app.ui.menus.get(ObjectMenuIDs.unlock)
        XCTAssertEqual(unlock?.quick, true)
        XCTAssertEqual(unlock?.order, h.app.ui.menus.get(ObjectMenuIDs.delete)?.order)
        XCTAssertEqual(unlock?.params(context(h)), ["refs": [ref(Fixtures.imageID)], "locked": false])
    }

    func testReadOnlyWindowOnlyCopiesAndScreenshots() {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        h.session.readOnly = true
        select(h, [Fixtures.shapeID])
        XCTAssertEqual(visible(h, .objectMenu), [ObjectMenuIDs.copy, ObjectMenuIDs.screenshot])
    }

    func testEntryParamsTargetTheSelection() throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        select(h, [Fixtures.shapeID, Fixtures.imageID], bounds: Rect(x: 100, y: 200, width: 284, height: 344))
        let ctx = context(h)
        let refs: JSONValue = [ref(Fixtures.shapeID), ref(Fixtures.imageID)]
        XCTAssertEqual(h.app.ui.menus.get(ObjectMenuIDs.delete)?.params(ctx), ["refs": refs])
        XCTAssertEqual(h.app.ui.menus.get(ObjectMenuIDs.arrange(.back))?.params(ctx), ["refs": refs, "to": "back"])
        // Colour and Lock act on what they can change.
        XCTAssertEqual(h.app.ui.menus.get(ObjectMenuIDs.colour)?.params(ctx)["refs"], [ref(Fixtures.shapeID)])
        XCTAssertEqual(h.app.ui.menus.get(ObjectMenuIDs.lock)?.params(ctx)["refs"], refs)
        XCTAssertEqual(h.app.ui.menus.get(ObjectMenuIDs.screenshot)?.params(ctx),
                       ["page": "page:FIXTUREDOC01/FIXTUREPG001", "rect": [100, 200, 284, 344]])
        XCTAssertEqual(h.app.ui.menus.get(ObjectMenuIDs.arrange(.front))?.submenu, "Arrange")
        XCTAssertEqual(h.app.ui.menus.get(ObjectMenuIDs.delete)?.shortcut, KeyShortcut("delete"))
    }

    func testStyleOpensTheMatchingInspector() throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        h.app.ui.inspectors.register(InspectorDescriptor(id: "test.text", title: "Text Style", icon: "textformat",
                                                         itemKinds: [.text], order: 1, owner: "test") { _ in
            AnyView(EmptyView())
        })
        h.app.ui.inspectors.register(InspectorDescriptor(id: "test.box", title: "Box Style", icon: "square",
                                                         itemKinds: [.text, .shape], order: 2, owner: "test") { _ in
            AnyView(EmptyView())
        })
        select(h, [Fixtures.strokeID])
        XCTAssertFalse(visible(h, .objectMenu).contains(ObjectMenuIDs.style))
        select(h, [Fixtures.textID])
        XCTAssertTrue(visible(h, .objectMenu).contains(ObjectMenuIDs.style))
        XCTAssertEqual(h.app.ui.menus.get(ObjectMenuIDs.style)?.params(context(h)),
                       ["id": "objectmenu.style", "inspector": "test.text"])
        // A mixed selection: the inspector that fits both first, then the one that fits part of it.
        let items = [try item(h, Fixtures.textID), try item(h, Fixtures.shapeID)]
        XCTAssertEqual(InspectorMatcher.inspectors(for: items, in: h.app.ui.inspectors.all).map { $0.id },
                       ["test.box", "test.text"])
        XCTAssertEqual(InspectorMatcher.items(for: try XCTUnwrap(h.app.ui.inspectors.get("test.text")), in: items).map { $0.id },
                       [Fixtures.textID])
    }

    func testMenusHideEntriesWhoseIsVisibleIsFalse() async {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        h.app.ui.menus.register(MenuItemDescriptor(id: "test.never", title: "Never", location: .objectMenu, order: 5,
                                                   owner: "test", command: "item.delete", isVisible: { _ in false }))
        h.app.ui.menus.register(MenuItemDescriptor(id: "test.always", title: "Always", location: .objectMenu, order: 6,
                                                   owner: "test", command: "item.delete"))
        select(h, [Fixtures.strokeID])
        let host = FakeCanvasHost(h)
        let floating = FakeFloatingHost()
        h.session.floatingHost = floating
        let attachment = ObjectMenuAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let ids = attachment.model.entries.map { $0.id }
        XCTAssertTrue(ids.contains("test.always"))
        XCTAssertFalse(ids.contains("test.never"))
        await withPasteboard(false) {
            let pageIDs = h.app.ui.menuItems(.pageLongPress, context(h, point: Point(300, 300))).map { $0.id }
            XCTAssertFalse(pageIDs.contains(ObjectMenuIDs.paste))
        }
    }

    func testPageMenuPasteAndScreenshot() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        try await withPasteboard(true) {
            XCTAssertEqual(visible(h, .pageLongPress, point: Point(200, 300)), [ObjectMenuIDs.paste, ObjectMenuIDs.pageScreenshot])
            let ctx = context(h, point: Point(200, 300))
            XCTAssertEqual(h.app.ui.menus.get(ObjectMenuIDs.paste)?.params(ctx),
                           ["page": "page:FIXTUREDOC01/FIXTUREPG001", "at": [200, 300]])
            XCTAssertEqual(h.app.ui.menus.get(ObjectMenuIDs.pageScreenshot)?.params(ctx),
                           ["tool": .string(ObjectMenuIDs.screenshotTool), "temporary": true])
            h.session.readOnly = true
            XCTAssertEqual(visible(h, .pageLongPress, point: Point(200, 300)), [ObjectMenuIDs.pageScreenshot])
            // Take Screenshot selects the capture tool temporarily.
            h.session.readOnly = false
            try await h.run("tool.select", ["tool": .string(ObjectMenuIDs.screenshotTool), "temporary": true])
            XCTAssertEqual(h.session.tool, ObjectMenuIDs.screenshotTool)
            XCTAssertEqual(h.session.temporaryReturnTool, "pen")
        }
    }

    // MARK: Composition, placement, provenance

    func testComposerSplitsQuickAndGroupsSubmenusAndPlugins() {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        select(h, [Fixtures.shapeID])
        h.app.ui.menus.register(MenuItemDescriptor(id: "dev.plugin.a", title: "Plugin A", location: .objectMenu,
                                                   order: 900, owner: "dev.plugin", command: "dev.plugin.a"))
        let ctx = context(h)
        let entries = h.app.ui.menuItems(.objectMenu, ctx).map { ObjectMenuEntry($0, context: ctx) }
        let split = ObjectMenuComposer.split(entries, maxQuick: 3)
        XCTAssertEqual(split.quick.map { $0.id }, [ObjectMenuIDs.cut, ObjectMenuIDs.copy, ObjectMenuIDs.duplicate])
        XCTAssertEqual(split.more.first?.id, ObjectMenuIDs.delete)             // quick overflow goes to More, in order
        let nodes = ObjectMenuComposer.group(split.more)
        let titles = nodes.map { node -> String in
            switch node {
            case .entry(let e): return e.id
            case .group(let title, _, let list): return title + ":" + list.map { $0.id }.joined(separator: ",")
            }
        }
        XCTAssertTrue(titles.contains("Arrange:" + [ArrangeOrder.front, .forward, .backward, .back]
            .map { ObjectMenuIDs.arrange($0) }.joined(separator: ",")))
        XCTAssertTrue(titles.contains("dev.plugin:dev.plugin.a"))              // a plugin's items under its name
        XCTAssertEqual(ObjectMenuKeys.display(KeyShortcut("]", [.command, .option, .shift])), "⌥⇧⌘]")
        XCTAssertEqual(ObjectMenuKeys.display(KeyShortcut("delete")), "⌫")
        XCTAssertEqual(ObjectMenuKeys.keyboardShortcut(KeyShortcut("l", [.command]))?.modifiers, .command)
    }

    func testPlacementAboveBelowAndClamp() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let bar = CGSize(width: 300, height: 44)
        let above = try XCTUnwrap(ObjectMenuPlacement.place(bar: bar, selection: CGRect(x: 400, y: 400, width: 200, height: 100),
                                                            in: bounds, top: 60, bottom: 16))
        XCTAssertTrue(above.above)
        XCTAssertEqual(above.centre.x, 500)
        XCTAssertEqual(above.centre.y, 400 - ObjectMenuPlacement.gapAbove - 22)
        let below = try XCTUnwrap(ObjectMenuPlacement.place(bar: bar, selection: CGRect(x: 0, y: 80, width: 100, height: 100),
                                                            in: bounds, top: 60, bottom: 16))
        XCTAssertFalse(below.above)
        XCTAssertEqual(below.centre.y, 180 + ObjectMenuPlacement.gapBelow + 22)
        XCTAssertEqual(below.centre.x, 16 + 150)                                  // clamped 16 pt inside the edge
        let tall = try XCTUnwrap(ObjectMenuPlacement.place(bar: bar, selection: CGRect(x: 100, y: 20, width: 300, height: 790),
                                                           in: bounds, top: 60, bottom: 16))
        XCTAssertGreaterThanOrEqual(tall.centre.y - 22, 60)
        XCTAssertNil(ObjectMenuPlacement.place(bar: bar, selection: CGRect(x: 0, y: -500, width: 100, height: 100),
                                               in: bounds, top: 60, bottom: 16))
    }

    func testProvenanceHeader() {
        var made = Item(kind: .stroke, stroke: Stroke(style: .defaultPen, points: []))
        made.createdBy = "ai:chat1"
        made.rev = Rev(wallMs: 1_700_000_000_000, counter: 0, device: 1)
        var mine = Item(kind: .stroke, stroke: Stroke(style: .defaultPen, points: []))
        mine.createdBy = "user"
        XCTAssertNil(Provenance.maker(of: [mine]) { _ in nil })
        let all = Provenance.maker(of: [made]) { _ in nil }
        XCTAssertEqual(all?.all, true)
        XCTAssertEqual(all?.name, "Assistant")
        XCTAssertEqual(all?.wallMs, 1_700_000_000_000)
        XCTAssertTrue(all.map(Provenance.header)?.hasPrefix("Made by Assistant · ") == true)
        XCTAssertEqual(Provenance.maker(of: [made, mine]) { _ in nil }?.all, false)
        var plugin = mine
        plugin.createdBy = "plugin:dev.charts"
        XCTAssertEqual(Provenance.maker(of: [plugin]) { $0 == "dev.charts" ? "Charts" : nil }?.name, "Charts")
    }

    // MARK: menu.showAt

    func testShowAtWithoutAWindowReportsTheEntries() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        try await withPasteboard(true) {
            let out = try await h.run("menu.showAt", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "point": [200, 300]])
            XCTAssertEqual(out["handled"], false)
            XCTAssertEqual(out["items"], ["Paste", "Take Screenshot"])
        }
        do {
            try await h.run("menu.showAt", ["page": "page:FIXTUREDOC01/NOSUCHPAGE01", "point": [1, 1]])
            XCTFail("a missing page")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
    }

    func testLongPressOnALockedItemSelectsIt() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        var selected: JSONValue?
        h.app.commands.register(CommandDescriptor(id: "selection.set", title: "Select", summary: "Test stand-in.",
                                                  effect: .session, exposure: .ui)) { params, _ in
            selected = params["refs"]
            return [:]
        }
        edit(h, Fixtures.imageID) { $0.locked = true }
        let longPress: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [330, 490],
                                    "ref": ref(Fixtures.imageID), "gesture": "longPress"]
        let out = try await h.run("menu.showAt", longPress)
        XCTAssertEqual(out["handled"], true)
        XCTAssertEqual(selected, [ref(Fixtures.imageID)])
        let other: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [110, 210],
                                "ref": ref(Fixtures.shapeID), "gesture": "longPress"]
        let unhandled = try await h.run("menu.showAt", other)
        XCTAssertEqual(unhandled["handled"], false)                     // an unlocked item: the other handlers decide
    }

    // MARK: The canvas attachment

    func testAttachmentPresentsTheObjectMenuWhenSomethingIsSelected() throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let host = FakeCanvasHost(h)
        let floating = FakeFloatingHost()
        h.session.floatingHost = floating
        let attachment = ObjectMenuAttachment()
        attachment.attach(to: host)
        XCTAssertFalse(attachment.model.isShown)
        select(h, [Fixtures.shapeID], bounds: Rect(x: 100, y: 200, width: 160, height: 90))
        XCTAssertTrue(attachment.model.isShown)
        XCTAssertTrue(floating.isPresenting(ObjectMenuIDs.overlay))
        XCTAssertTrue(floating.isPresenting(ObjectMenuIDs.colourPopover))
        XCTAssertEqual(attachment.model.anchor, CGRect(x: 100, y: 200, width: 160, height: 90))
        XCTAssertEqual(floating.anchors[ObjectMenuIDs.overlay], CGRect(x: 100, y: 200, width: 160, height: 0))
        XCTAssertTrue(attachment.model.entries.map { $0.id }.contains(ObjectMenuIDs.delete))
        XCTAssertEqual(attachment.model.swatches.count, 12)
        XCTAssertEqual(attachment.model.currentSwatch, nil)              // the fixture shape's outline is not an ink
        // Deselecting (a tap away, a delete) takes the menu away.
        h.session.selection = Selection()
        XCTAssertFalse(attachment.model.isShown)
        XCTAssertFalse(attachment.model.hasEntries)
        attachment.detach(from: host)
        XCTAssertFalse(floating.isPresenting(ObjectMenuIDs.overlay))
    }

    func testTheMenuStepsAsideWhileThePageMoves() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let host = FakeCanvasHost(h)
        let floating = FakeFloatingHost()
        h.session.floatingHost = floating
        let attachment = ObjectMenuAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        select(h, [Fixtures.imageID], bounds: Rect(x: 320, y: 480, width: 64, height: 64))
        XCTAssertTrue(attachment.model.isShown)
        host.zoomScale = 2
        attachment.canvasDidChange(host)
        XCTAssertFalse(attachment.model.isShown)
        XCTAssertEqual(attachment.model.anchor, CGRect(x: 640, y: 960, width: 128, height: 128))
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(attachment.model.isShown)
    }

    func testRightClickMenus() async throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let host = FakeCanvasHost(h)
        let attachment = ObjectMenuAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        select(h, [Fixtures.shapeID], bounds: Rect(x: 100, y: 200, width: 160, height: 90))
        let overSelection = try XCTUnwrap(attachment.contextMenu(at: CGPoint(x: 150, y: 240)))
        let titles = overSelection.menu.children.map { $0.title }
        XCTAssertTrue(titles.contains("Delete"))
        XCTAssertTrue(titles.contains("Arrange"))
        XCTAssertEqual(overSelection.highlight, CGRect(x: 100, y: 200, width: 160, height: 90))
        try await withPasteboard(true) {
            let empty = try XCTUnwrap(attachment.contextMenu(at: CGPoint(x: 500, y: 800)))
            XCTAssertEqual(empty.menu.children.map { $0.title }, ["Paste", "Take Screenshot"])
            let onImage = try XCTUnwrap(attachment.contextMenu(at: CGPoint(x: 350, y: 510)))
            XCTAssertTrue(onImage.menu.children.map { $0.title }.contains("Lock"))
        }
    }

    func testUIMenusCarryCheckmarksShortcutsAndColours() throws {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        var checked = MenuItemDescriptor(id: "test.checked", title: "Snap", location: .objectMenu, order: 950,
                                         owner: FeatObjectMenuFeature.id, command: "item.delete")
        checked.isChecked = { _ in true }
        checked.contextTitle = { _ in "Snap to Grid" }
        h.app.ui.menus.register(checked)
        select(h, [Fixtures.strokeID])
        let host = FakeCanvasHost(h)
        let attachment = ObjectMenuAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let built = try XCTUnwrap(attachment.contextMenu(at: CGPoint(x: 100, y: 121)))
        let elements = built.menu.children
        let snap = try XCTUnwrap(elements.first { $0.title == "Snap to Grid" } as? UIAction)
        XCTAssertEqual(snap.state, .on)
        let delete = try XCTUnwrap(elements.first { $0.title == "Delete" } as? UIAction)
        XCTAssertTrue(delete.attributes.contains(.destructive))
        XCTAssertEqual(delete.subtitle, "⌫")
        let colour = try XCTUnwrap(elements.first { $0.title == "Colour" } as? UIMenu)
        XCTAssertEqual(colour.children.count, 13)                         // 12 inks and Custom…
    }

    func testCapsuleRendersInLightDarkAndLargeText() {
        let h = Harness(features: [FeatObjectMenuFeature.self])
        select(h, [Fixtures.textID])
        let host = FakeCanvasHost(h)
        let attachment = ObjectMenuAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let bar = ObjectMenuBar(model: attachment.model, maxQuick: ObjectMenuComposer.regularQuick)
        let images = NibSnapshot.images(bar, size: CGSize(width: 420, height: 52))
        XCTAssertEqual(images.count, NibSnapshot.Variant.allCases.count)
        for variant in NibSnapshot.Variant.allCases {
            let size = NibSnapshot.fittingSize(bar, width: 800, variant: variant)
            XCTAssertLessThanOrEqual(size.height, 52.5, "\(variant)")        // chrome stops growing at the type cap
            XCTAssertGreaterThanOrEqual(size.height, 44, "\(variant)")
        }
    }

    // MARK: Screenshot tool

    func testScreenshotToolRectAndTap() {
        XCTAssertEqual(ScreenshotTool.rect(Point(300, 400), Point(100, 150)), Rect(x: 100, y: 150, width: 200, height: 250))
        let h = Harness(features: [FeatObjectMenuFeature.self])
        let host = FakeCanvasHost(h)
        h.session.selectTemporarily(ObjectMenuIDs.screenshotTool)
        let tool = ScreenshotTool()
        tool.touchesBegan(CanvasSample(page: Fixtures.page1, location: Point(100, 100)), host: host)
        XCTAssertEqual(host.overlayLayer.sublayers?.count ?? 0, 1)       // the dashed frame
        tool.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(100.5, 100.5)), host: host)
        XCTAssertEqual(host.overlayLayer.sublayers?.count ?? 0, 0)
        XCTAssertEqual(h.session.tool, "pen")                             // a tap leaves without capturing
    }
}
