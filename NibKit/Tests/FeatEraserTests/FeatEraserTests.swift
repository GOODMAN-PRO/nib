import XCTest
import UIKit
import Combine
import SwiftUI
import NibContracts
import NibDesign
import NibTesting
@testable import FeatEraser

@MainActor
final class FeatEraserTests: XCTestCase {
    private var page1: String { NodeRef.page(Fixtures.docID, Fixtures.page1).description }
    private var page2: String { NodeRef.page(Fixtures.docID, Fixtures.page2).description }

    private func path(_ points: [(Double, Double)]) -> JSONValue {
        .array(points.map { JSONValue.array([.number($0.0), .number($0.1)]) })
    }

    /// A 100 pt horizontal ball-pen line (1 pt spacing, 2 pt nib) for page 2 of the fixture notebook.
    private func line(_ id: String, y: Float, tool: InkTool = .pen, layer: Int = 0, locked: Bool = false, z: String = "V") -> Item {
        let points = (0...100).map { StrokePoint(x: Float($0), y: y, t: Float($0) * 0.01, width: 2, height: 2) }
        let style = InkStyle(tool: tool, pen: tool == .pen ? .ball : nil, width: 2)
        return Item(id: NibID(id), kind: .stroke, z: z, layer: layer, locked: locked,
                    stroke: Stroke(style: style, points: points, t0: 1_700_000_000))
    }

    /// Installs items on the (still unloaded) empty fixture page 2.
    private func seedPage2(_ h: Harness, _ items: [Item]) {
        h.persistence.pageItems[Fixtures.docID, default: [:]][Fixtures.page2] = items
    }

    private func items(_ h: Harness, _ page: PageID = Fixtures.page1) throws -> [Item] {
        try h.app.workspace.items(Fixtures.docID, page: page)
    }

    /// Waits (up to 3 s) for queued work such as `app.perform` or the size debounce.
    private func eventually(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 200_000_000) }

    private func assertInvalid(_ h: Harness, _ command: String, _ params: JSONValue,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await h.run(command, params)
            XCTFail("\(command) accepted \(params.jsonString())", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams, e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Conformance and registration

    func testCommandsConformWithUndoRoundTrips() async {
        let problems = await CommandConformance.check(features: [FeatEraserFeature.self], owners: [FeatEraserFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersToolShortcutMenusSheetAndSettings() {
        let h = Harness(features: [FeatEraserFeature.self])
        for id in ["ink.erase", "ink.scribbleErase", "page.clear", "page.deleteItems"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, FeatEraserFeature.id, id)
        }
        XCTAssertNotNil(h.app.ui.canvasTools.get("eraser"))
        let item = h.app.ui.toolbar.get("eraser")
        XCTAssertEqual(item?.toolID, "eraser")
        XCTAssertEqual(item?.shortcut, KeyShortcut("e"))
        XCTAssertNotNil(item?.settings)
        XCTAssertNotNil(item?.activeToolMenu)
        XCTAssertEqual(h.app.ui.panels.get(FeatEraserFeature.deleteItemsPanel)?.placement, .sheet)
        XCTAssertEqual(h.app.ui.panels.get(FeatEraserFeature.deleteItemsPanel)?.providesHeader, true,
                       "the sheet draws its own header")

        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1)
        let more = h.app.ui.menuItems(.documentMore, context)
        let clear = more.first { $0.command == "page.clear" }
        XCTAssertEqual(clear?.params(context), ["page": .string(page1)])
        XCTAssertEqual(clear?.destructive, true)
        XCTAssertEqual(more.first { $0.command == "panel.open" }?.params(context), ["id": .string(FeatEraserFeature.deleteItemsPanel)])
        h.session.readOnly = true
        XCTAssertTrue(h.app.ui.menuItems(.documentMore, context).filter { $0.owner == FeatEraserFeature.id }.isEmpty)

        for name in ["eraser.mode", "eraser.size", "eraser.autoDeselect", "eraser.filter.pen", "eraser.filter.tape"] {
            XCTAssertEqual(h.app.settings.descriptor(name)?.owner, FeatEraserFeature.id, "F010 owns \(name)")
        }
        XCTAssertEqual(EraserSettings.filter(h.app.settings), Set(InkTool.allCases))
    }

    func testTheSharedEraserKeysAreTheOnesOtherFeaturesRead() {
        let h = Harness(features: [FeatEraserFeature.self])
        XCTAssertEqual(EraserSettings.mode(h.app.settings), .standard)
        XCTAssertEqual(EraserSettings.size(h.app.settings), 14)
        // The Zoom Window (F038) and the Pencil hover preview (F043) write and read the NibSettings keys.
        h.app.settings.set(NibSettings.eraserMode, "precision")
        h.app.settings.set(NibSettings.eraserSize, 28)
        h.app.settings.set(NibSettings.eraserFilter(.tape), false)
        XCTAssertEqual(EraserSettings.mode(h.app.settings), .precision)
        XCTAssertEqual(EraserSettings.size(h.app.settings), 28)
        XCTAssertEqual(EraserSettings.filter(h.app.settings), [.pen, .pencil, .highlighter])
        h.app.settings.set(NibSettings.eraserMode, "pixel")
        h.app.settings.set(NibSettings.eraserSize, 500)
        XCTAssertEqual(EraserSettings.mode(h.app.settings), .standard, "an unknown mode erases like the default")
        XCTAssertEqual(EraserSettings.size(h.app.settings), EraserSettings.sizeRange.upperBound)
        XCTAssertEqual(h.app.settings.undeclaredNames.filter { $0.hasPrefix("eraser.") }, [])
    }

    // MARK: ink.erase

    func testStandardEraseSplitsTheFixtureStrokeIntoFreshStrokesAndUndoRestores() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let before = try h.snapshot()
        let original = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        let next = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID).z
        let r = try await h.run("ink.erase", ["page": .string(page1), "path": path([(100, 100), (100, 140)]),
                                              "radius": 3, "mode": "standard"])
        XCTAssertEqual(r, ["removed": 1, "created": 2])
        XCTAssertNil(r["refs"], "split pieces are internal: counts only")

        let pieces = try items(h).filter { $0.kind == .stroke && $0.stroke?.style.tool == .pen }
        XCTAssertEqual(pieces.count, 2)
        XCTAssertFalse(pieces.contains { $0.id == Fixtures.strokeID })
        XCTAssertEqual(Set(pieces.map { $0.id }).count, 2, "fresh, distinct ids")
        XCTAssertEqual(Set(pieces.map { $0.z }).count, 2, "every piece has its own z key")
        for piece in pieces {
            XCTAssertTrue(piece.z > original.z && piece.z < next, "pieces stay where the stroke was in the z-order")
            XCTAssertEqual(piece.layer, original.layer)
            XCTAssertEqual(piece.stroke?.style, original.stroke?.style)
            XCTAssertEqual(piece.stroke?.t0, original.stroke?.t0)
        }
        let xs = pieces.flatMap { $0.stroke?.points.map { $0.x } ?? [] }
        XCTAssertFalse(xs.contains(100), "the touched point is gone")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "one gesture, one undo step")

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try items(h).filter { $0.stroke?.style.tool == .pen }.count, 2)
    }

    func testNextZFindsTheFirstItemAboveAKey() {
        let items = ["B", "D", "F"].map { Item(id: NibID($0), kind: .stroke, z: $0, stroke: Stroke(style: InkStyle(tool: .pen), points: [])) }
        XCTAssertEqual(EraseSupport.nextZ(above: "A", in: items), "B")
        XCTAssertEqual(EraseSupport.nextZ(above: "B", in: items), "D")
        XCTAssertEqual(EraseSupport.nextZ(above: "C", in: items), "D")
        XCTAssertNil(EraseSupport.nextZ(above: "F", in: items))
        XCTAssertNil(EraseSupport.nextZ(above: "A", in: []))
    }

    func testPrecisionEraseKeepsWidthsAndIsScopedToTheActiveLayerAndUnlockedInk() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        seedPage2(h, [line("PEN", y: 10, z: "V"), line("HIL", y: 20, tool: .highlighter, z: "W"),
                      line("LCK", y: 30, locked: true, z: "X"), line("LAY", y: 40, layer: 1, z: "Y")])
        let params: JSONValue = ["page": .string(page2), "path": path([(50, 0), (50, 50)]), "radius": 3, "mode": "precision"]

        let first = try await h.run("ink.erase", params)
        XCTAssertEqual(first, ["removed": 2, "created": 4])
        let left = try items(h, Fixtures.page2)
        XCTAssertTrue(left.contains { $0.id == "LCK" }, "locked ink is never erased")
        XCTAssertTrue(left.contains { $0.id == "LAY" }, "other layers are left alone")
        let cut = left.filter { $0.id != "LCK" && $0.id != "LAY" }
        XCTAssertEqual(cut.count, 4)
        for piece in cut {
            let points = try XCTUnwrap(piece.stroke?.points)
            XCTAssertTrue(points.allSatisfy { $0.width == 2 && $0.height == 2 }, "widths are kept")
            // The ball pen's 1 pt half nib + 3 pt radius: nothing is left within 4 pt of the eraser's centre line.
            XCTAssertTrue(points.allSatisfy { abs($0.x - 50) >= 3.999 })
        }

        h.session.activeLayer = 1
        let second = try await h.run("ink.erase", params)
        XCTAssertEqual(second, ["removed": 1, "created": 2])
    }

    func testEraseFilterOnlyErasesTheChosenInk() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        seedPage2(h, [line("PEN", y: 10, z: "V"), line("HIL", y: 20, tool: .highlighter, z: "W")])
        let r = try await h.run("ink.erase", ["page": .string(page2), "path": path([(50, 0), (50, 50)]), "radius": 3,
                                              "mode": "stroke", "filter": ["highlighter"]])
        XCTAssertEqual(r, ["removed": 1, "created": 0])
        XCTAssertEqual(try items(h, Fixtures.page2).map { $0.id }, ["PEN"])
    }

    func testShapesAreErasedWholeUnlessTheyHoldChildrenAndAnchoredConnectorsLetGo() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let before = try h.snapshot()
        let r = try await h.run("ink.erase", ["page": .string(page1), "path": path([(100, 180), (100, 300)]),
                                              "radius": 2, "mode": "precision"])
        XCTAssertEqual(r, ["removed": 1, "created": 0])
        let left = try items(h)
        XCTAssertFalse(left.contains { $0.id == Fixtures.shapeID })
        let connector = try XCTUnwrap(left.first { $0.id == Fixtures.connectorID }?.connector)
        XCTAssertNil(connector.from.item, "the end anchored to the erased shape is released")
        XCTAssertEqual(connector.from.point, Point(260, 245))
        XCTAssertEqual(connector.to.item, Fixtures.stickyID)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)

        let parent = Item(id: "BOX", kind: .shape, z: "V", shape: ShapeItem(shape: .rectangle, frame: Frame(x: 20, y: 20, w: 40, h: 40)))
        let child = Item(id: "LABEL", kind: .text, z: "W", attachedTo: "BOX",
                         text: TextBoxItem(frame: Frame(x: 25, y: 25, w: 30, h: 20), text: RichText(plain: "Box")))
        let other = Harness(features: [FeatEraserFeature.self])
        seedPage2(other, [parent, child])
        let skipped = try await other.run("ink.erase", ["page": .string(page2), "path": path([(20, 0), (20, 100)]),
                                                        "radius": 2, "mode": "stroke"])
        XCTAssertEqual(skipped, ["removed": 0, "created": 0])
        XCTAssertEqual(other.undoDepth(Fixtures.docID), 0, "nothing erased, nothing to undo")
    }

    func testEraseRejectsBadInput() async {
        let h = Harness(features: [FeatEraserFeature.self])
        await assertInvalid(h, "ink.erase", ["page": "doc:FIXTUREDOC01", "path": path([(1, 1)]), "radius": 3, "mode": "standard"])
        await assertInvalid(h, "ink.erase", ["page": .string(page1), "path": [], "radius": 3, "mode": "standard"])
        await assertInvalid(h, "ink.erase", ["page": .string(page1), "path": path([(1, 1)]), "radius": 0, "mode": "standard"])
        await assertInvalid(h, "ink.erase", ["page": .string(page1), "path": path([(1, 1)]), "radius": 3, "mode": "pixel"])
        await assertInvalid(h, "ink.erase", ["page": .string(page1), "path": path([(1, 1)]), "radius": 501, "mode": "standard"])
        // Over-long paths are refused before any geometry runs.
        let long = path((0...NibLimits.maxErasePathPoints).map { (Double($0 % 500), 10.0) })
        await assertInvalid(h, "ink.erase", ["page": .string(page1), "path": long, "radius": 3, "mode": "standard"])
        await assertInvalid(h, "ink.scribbleErase", ["page": .string(page1), "points": long])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        do {
            _ = try await h.run("ink.erase", ["page": "page:FIXTUREDOC01/NOSUCHPAGE01", "path": path([(1, 1)]),
                                              "radius": 3, "mode": "standard"])
            XCTFail("erased on a missing page")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: ink.scribbleErase

    func testScribbleEraseRemovesThePenStrokeItCovers() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let before = try h.snapshot()
        let r = try await h.run("ink.scribbleErase", ["page": .string(page1),
                                                      "points": path([(70, 116), (150, 118), (70, 121), (150, 124), (70, 127)])])
        XCTAssertEqual(r, ["removed": 1, "created": 0])
        let left = try items(h)
        XCTAssertFalse(left.contains { $0.id == Fixtures.strokeID })
        XCTAssertTrue(left.contains { $0.id == Fixtures.tapeID }, "tape is not handwriting")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)

        let miss = try await h.run("ink.scribbleErase", ["page": .string(page1), "points": path([(300, 700), (340, 704), (300, 708)])])
        XCTAssertEqual(miss, ["removed": 0, "created": 0])
    }

    // MARK: page.clear

    func testClearPageConfirmationKeepsCancelVisibleOnIPadWithoutChangingThePage() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let before = try h.snapshot()
        let host = UIHostingController(rootView: NibDropletContainer {
            NibBudPopover(id: "test.eraser.settings", source: "test.eraser",
                          isPresented: .constant(true), title: "Eraser") {
                EraserSettingsView(app: h.app, session: h.session, confirmingClear: true)
            }
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1376, height: 1032))
        window.rootViewController = host
        window.isHidden = false
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        await eventually { self.confirmation(in: window) != nil }
        let panel = try XCTUnwrap(confirmation(in: window))
        panel.layoutIfNeeded()
        XCTAssertNil(host.presentedViewController, "Confirmation must render without a modal UIKit presentation")
        XCTAssertTrue(panel.accessibilityViewIsModal, "VoiceOver must stay inside the confirmation")
        let cancel = try confirmationButton("confirmation.cancel", in: panel)
        let clear = try confirmationButton("confirmation.confirm", in: panel)
        XCTAssertEqual(cancel.titleLabel?.text, "Cancel")
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertEqual(clear.titleLabel?.text, "Clear Page")
        XCTAssertTrue(clear.isEnabled)
        XCTAssertEqual(clear.configuration?.baseForegroundColor, NibUIColor.destructive)
        assertRendered(cancel, in: window)
        assertRendered(clear, in: window)
        XCTAssertEqual(try h.snapshot(), before, "Opening confirmation must not clear any items")
        cancel.sendActions(for: .touchUpInside)
        await eventually { self.confirmation(in: window) == nil }
        XCTAssertNil(confirmation(in: window), "Dismissing confirmation must release the editor")
        XCTAssertNil(panel.superview)
        XCTAssertNil(panel.window)
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "Dismissal must not create an edit or undo entry")
    }

    private func confirmation(in view: UIView) -> NibConfirmationPanel? {
        if let panel = view as? NibConfirmationPanel { return panel }
        return view.subviews.lazy.compactMap { self.confirmation(in: $0) }.first
    }

    private func confirmationButton(_ identifier: String, in view: UIView) throws -> UIButton {
        func buttons(_ view: UIView) -> [UIButton] {
            (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        return try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier == identifier })
    }

    private func assertRendered(_ button: UIButton, in window: UIWindow,
                                file: StaticString = #filePath, line: UInt = #line) {
        button.layoutIfNeeded()
        let label = button.titleLabel
        XCTAssertTrue(label.map {
            !$0.isHidden && $0.alpha > 0 && !$0.bounds.isEmpty && $0.window === window
        } ?? false, "The action must actually be rendered, not only registered", file: file, line: line)
        let rect = button.convert(button.bounds, to: window)
        XCTAssertTrue(window.bounds.contains(rect), "The entire action must be visible", file: file, line: line)
        let hit = window.hitTest(CGPoint(x: rect.midX, y: rect.midY), with: nil)
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                      "The visible action must receive taps, got \(String(describing: hit))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.bounds.height, NibMetrics.hitTarget, file: file, line: line)
    }

    func testClearPageConfirmationRendersInCompactAndAccessibleLayoutsAndClearsOnce() async throws {
        let layouts: [(String, CGSize, UIContentSizeCategory, UIUserInterfaceStyle, UIAccessibilityContrast)] = [
            ("Compact", CGSize(width: 390, height: 844), .large, .light, .normal),
            ("Light", CGSize(width: 1376, height: 1032), .large, .light, .normal),
            ("Dark", CGSize(width: 1376, height: 1032), .large, .dark, .normal),
            ("Increase Contrast", CGSize(width: 1376, height: 1032), .large, .light, .high),
            ("AX3", CGSize(width: 1376, height: 1032), .accessibilityExtraExtraExtraLarge, .light, .normal)
        ]
        for (name, size, category, style, contrast) in layouts {
            let h = Harness(features: [FeatEraserFeature.self])
            let before = try h.snapshot()
            let host = UIHostingController(rootView: EraserSettingsView(app: h.app, session: h.session,
                                                                        confirmingClear: true))
            host.traitOverrides.preferredContentSizeCategory = category
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.traitOverrides.userInterfaceStyle = style
            window.traitOverrides.accessibilityContrast = contrast
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            await eventually { self.confirmation(in: window) != nil }
            let panel = try XCTUnwrap(confirmation(in: window))
            panel.layoutIfNeeded()
            let cancel = try confirmationButton("confirmation.cancel", in: panel)
            let clear = try confirmationButton("confirmation.confirm", in: panel)
            assertRendered(cancel, in: window)
            assertRendered(clear, in: window)
            let buttonFont = UIFont.systemFont(ofSize: NibUIFont.button.pointSize, weight: .semibold)
            let expectedButtonSize = UIFontMetrics(forTextStyle: .subheadline)
                .scaledFont(for: buttonFont, compatibleWith: panel.traitCollection).pointSize
            XCTAssertEqual(cancel.titleLabel?.font.pointSize ?? 0, expectedButtonSize, accuracy: 0.5)
            XCTAssertEqual(clear.titleLabel?.font.pointSize ?? 0, expectedButtonSize, accuracy: 0.5)
            let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = "Clear Page confirmation - " + name
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(try h.snapshot(), before)
            clear.sendActions(for: .touchUpInside)
            clear.sendActions(for: .touchUpInside)
            await eventually { (try? self.items(h).isEmpty) == true }
            XCTAssertNil(confirmation(in: window))
            XCTAssertNil(panel.window)
            XCTAssertTrue(try items(h).isEmpty)
            XCTAssertNotNil(try h.app.workspace.content(Fixtures.docID).livePages.first { $0.id == Fixtures.page1 })
            XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
            XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
            XCTAssertEqual(try h.snapshot(), before)
        }
    }

    func testClearPageConfirmationReleasesEditorCallbacksOnEveryExit() async throws {
        for exit in ["confirmation.cancel", "confirmation.confirm", "escape", "disappear", "dismantle"] {
            let presenter = ClearPageConfirmation.Presenter()
            var editor: UIViewController? = UIViewController()
            weak var retainedEditor = editor
            presenter.requested = true
            presenter.clear = { [editor] in _ = editor?.view }
            presenter.dismissed = { [editor] in _ = editor?.view }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1376, height: 1032))
            editor?.addChild(presenter)
            editor?.view.addSubview(presenter.view)
            presenter.didMove(toParent: editor)
            window.rootViewController = editor
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            presenter.schedulePresentation()
            await eventually { self.confirmation(in: window) != nil }
            let panel = try XCTUnwrap(confirmation(in: window))
            switch exit {
            case "escape": XCTAssertTrue(panel.accessibilityPerformEscape())
            case "disappear":
                presenter.beginAppearanceTransition(false, animated: false)
                presenter.endAppearanceTransition()
            case "dismantle": ClearPageConfirmation.dismantleUIViewController(presenter, coordinator: ())
            default: try confirmationButton(exit, in: panel).sendActions(for: .touchUpInside)
            }
            XCTAssertNil(panel.superview, exit)
            XCTAssertNil(presenter.clear, exit)
            XCTAssertNil(presenter.dismissed, exit)
            window.isHidden = true
            window.rootViewController = nil
            editor = nil
            await eventually { retainedEditor == nil }
            XCTAssertNil(retainedEditor, "Dismissing confirmation must release the editor: \(exit)")
        }
    }

    func testClearPageRemovesEveryItemKeepsThePageAndUndoes() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let before = try h.snapshot()
        let count = try items(h).count
        let r = try await h.run("page.clear", ["page": .string(page1)])
        XCTAssertEqual(r, ["removed": .number(Double(count)), "created": 0])
        XCTAssertTrue(try items(h).isEmpty)
        XCTAssertNotNil(try h.app.workspace.content(Fixtures.docID).livePages.first { $0.id == Fixtures.page1 })
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)

        let empty = try await h.run("page.clear", ["page": .string(page2)])
        XCTAssertEqual(empty, ["removed": 0, "created": 0])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "clearing an empty page records nothing")
    }

    func testClearingALargePageIsOneBatchAndOneUndoStep() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let count = 5_000
        var seeded = (0..<count).map { i -> Item in
            let x = Float(i % 500), y = Float(i / 500) * 20
            let points = [StrokePoint(x: x, y: y, t: 0, width: 1, height: 1), StrokePoint(x: x + 1, y: y, t: 0.01, width: 1, height: 1)]
            return Item(id: NibID(String(format: "S%05d", i)), kind: .stroke, z: String(format: "V%05d", i),
                        stroke: Stroke(style: InkStyle(tool: .pen, width: 1), points: points))
        }
        // A connector anchored to one of them lets go when it goes.
        seeded.append(Item(id: "LINK", kind: .connector, z: "W",
                          connector: ConnectorItem(from: ConnectorEnd(point: Point(0, 0), item: "S00000"),
                                                   to: ConnectorEnd(point: Point(40, 40)))))
        seedPage2(h, seeded)
        // Page 2 without revisions (undo writes fresh ones); cheaper than a whole-document snapshot at this size.
        func page2Items() throws -> [Item] {
            try items(h, Fixtures.page2).map { item -> Item in
                var bare = item
                bare.rev = .zero
                return bare
            }
        }
        let before = try page2Items()
        XCTAssertEqual(before.count, count + 1)
        let r = try await h.run("page.deleteItems", ["page": .string(page2), "kinds": ["pen"], "scope": "page"])
        XCTAssertEqual(r, ["removed": .number(Double(count)), "created": 0])
        let left = try items(h, Fixtures.page2)
        XCTAssertEqual(left.map { $0.id }, ["LINK"])
        XCTAssertNil(left.first?.connector?.from.item)
        XCTAssertEqual(left.first?.connector?.from.point, Point(0, 0))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try page2Items(), before)

        let cleared = try await h.run("page.clear", ["page": .string(page2)])
        XCTAssertEqual(cleared, ["removed": .number(Double(count + 1)), "created": 0])
        XCTAssertTrue(try items(h, Fixtures.page2).isEmpty)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "one step each: the delete was undone, the clear is new")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try page2Items(), before)
    }

    // MARK: page.deleteItems

    func testDeleteSpecificItemsByKindOnAPageOrTheWholeDocument() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let before = try h.snapshot()
        let onPage = try await h.run("page.deleteItems", ["page": .string(page1), "kinds": ["pen", "tape", "image"], "scope": "page"])
        XCTAssertEqual(onPage, ["removed": 3, "created": 0])
        let left = Set(try items(h).map { $0.id })
        XCTAssertFalse(left.contains(Fixtures.strokeID) || left.contains(Fixtures.tapeID) || left.contains(Fixtures.imageID))
        XCTAssertTrue(left.contains(Fixtures.textID))

        let whole = try await h.run("page.deleteItems", ["doc": "doc:FIXTUREDOC01", "kinds": ["shape", "sticky"], "scope": "document"])
        XCTAssertEqual(whole, ["removed": 2, "created": 0])
        let connector = try XCTUnwrap(try items(h).first { $0.id == Fixtures.connectorID }?.connector)
        XCTAssertNil(connector.from.item)
        XCTAssertNil(connector.to.item)

        // Scope "page" with only a document uses the window's current page.
        let current = try await h.run("page.deleteItems", ["doc": "doc:FIXTUREDOC01", "kinds": ["comment"], "scope": "page"])
        XCTAssertEqual(current, ["removed": 1, "created": 0])

        while h.app.bus.undo(Fixtures.docID) {}
        XCTAssertEqual(try h.snapshot(), before)

        await assertInvalid(h, "page.deleteItems", ["page": .string(page1), "kinds": ["banana"], "scope": "page"])
        await assertInvalid(h, "page.deleteItems", ["page": .string(page1), "kinds": [], "scope": "page"])
        await assertInvalid(h, "page.deleteItems", ["kinds": ["pen"], "scope": "page"])
        await assertInvalid(h, "page.deleteItems", ["page": .string(page1), "kinds": ["pen"], "scope": "shelf"])
    }

    func testDeleteItemsSheetBuildsParamsAndCountsFromReads() async throws {
        XCTAssertEqual(DeleteItemsGroup.params(doc: Fixtures.docID, page: Fixtures.page1, groups: [.handwriting, .tape], scope: .page),
                       ["page": .string(page1), "kinds": ["pen", "pencil", "tape"], "scope": "page"])
        XCTAssertEqual(DeleteItemsGroup.params(doc: Fixtures.docID, page: nil, groups: [.shapes], scope: .document),
                       ["doc": "doc:FIXTUREDOC01", "kinds": ["connector", "shape"], "scope": "document"])
        XCTAssertNil(DeleteItemsGroup.params(doc: Fixtures.docID, page: nil, groups: [.images], scope: .page))
        XCTAssertNil(DeleteItemsGroup.params(doc: Fixtures.docID, page: Fixtures.page1, groups: [], scope: .page))

        let h = Harness(features: [FeatEraserFeature.self])
        let before = try h.snapshot()
        let params = try XCTUnwrap(DeleteItemsGroup.params(doc: Fixtures.docID, page: Fixtures.page1,
                                                           groups: [.handwriting, .tape], scope: .page))
        XCTAssertEqual(DeleteItemsSheet.count(params, app: h.app, session: h.session), 2)
        let preview = try await h.app.bus.execute(Invocation(command: "page.deleteItems", params: params, session: h.session, dryRun: true))
        XCTAssertEqual(preview.value["removed"]?.intValue, 2, "the sheet counts what the command deletes")
        let whole = DeleteItemsGroup.params(doc: Fixtures.docID, page: nil, groups: [.shapes, .sticky], scope: .document)
        XCTAssertEqual(DeleteItemsSheet.count(whole, app: h.app, session: h.session), 3)
        XCTAssertEqual(DeleteItemsSheet.count(nil, app: h.app, session: h.session), 0)
        XCTAssertEqual(try h.snapshot(), before, "counting changes nothing")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    // MARK: The canvas tool

    func testEraserToolHidesWhileDraggingThenCommitsOneEraseAndAutoDeselects() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        h.app.settings.set(NibSettings.eraserMode, EraserMode.standard.rawValue)
        h.app.settings.set(NibSettings.eraserSize, 6)
        h.app.settings.set(EraserSettings.autoDeselect, true)
        h.session.tool = "pen"
        h.session.tool = "eraser"
        let host = FakeCanvasHost(h)
        let tool = EraserTool()
        tool.activate(host)

        func sample(_ x: Double, _ y: Double) -> CanvasSample { CanvasSample(page: Fixtures.page1, location: Point(x, y)) }
        tool.touchesBegan(sample(100, 100), host: host)
        XCTAssertNil(host.hidden[Fixtures.page1])
        tool.touchesMoved([sample(100, 110), sample(100, 125), sample(100, 140)], host: host)
        XCTAssertEqual(host.hidden[Fixtures.page1] ?? [], [Fixtures.strokeID], "the touched stroke is hidden while dragging")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "nothing is committed before the lift")
        XCTAssertFalse(try items(h).isEmpty)

        XCTAssertFalse(tool.isSticky, "Auto-deselect makes the eraser a one-use tool")
        var finished: [JSONValue] = []
        let sub = h.app.events.subscribe { if $0.type == NibEventType.toolFinished { finished.append($0.payload ?? .null) } }
        defer { sub.cancel() }
        tool.touchesEnded(sample(100, 140), host: host)
        await tool.pendingCommit?.value
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "one ink.erase per gesture")
        XCTAssertEqual(try items(h).filter { $0.stroke?.style.tool == .pen }.count, 2)
        XCTAssertEqual(host.renderWaits, [Fixtures.page1], "the preview stays until the canvas drew the committed ink")
        XCTAssertNil(host.hidden[Fixtures.page1], "hidden items are shown again once the erase is committed")
        XCTAssertEqual(h.session.tool, "pen", "Auto-deselect returns to the previous tool")
        XCTAssertEqual(finished.map { $0["tool"] ?? .null }, [JSONValue.string("eraser")], "the lift is reported as one use")
    }

    func testWithoutAutoDeselectTheEraserStaysUnlessItWasPickedTemporarily() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        h.app.settings.set(NibSettings.eraserSize, 6)
        let host = FakeCanvasHost(h)
        let tool = EraserTool()
        tool.activate(host)
        XCTAssertTrue(tool.isSticky)
        func erase(at y: Double) async {
            tool.tap(CanvasSample(page: Fixtures.page1, location: Point(100, y)), host: host)
            await tool.pendingCommit?.value
        }
        h.session.tool = "pen"
        h.session.tool = "eraser"
        await erase(at: 122)
        XCTAssertEqual(h.session.tool, "eraser", "a sticky eraser stays after an erase")

        h.session.tool = "lasso"
        try await h.run(CommandIDs.toolSelect, ["tool": "eraser", "temporary": true])
        XCTAssertEqual(h.session.temporaryReturnTool, "lasso")
        await erase(at: 780)                                    // a miss is still one use
        XCTAssertEqual(h.session.tool, "lasso", "a temporary eraser hands back after one use")
        XCTAssertNil(h.session.temporaryReturnTool)
        XCTAssertEqual(host.renderWaits, [Fixtures.page1], "only a gesture that erased something waits for the render")

        // A tool picked while the erase ran is left alone.
        h.session.tool = "eraser"
        tool.tap(CanvasSample(page: Fixtures.page1, location: Point(100, 124)), host: host)
        h.session.tool = "highlighter"
        await tool.pendingCommit?.value
        XCTAssertEqual(h.session.tool, "highlighter")
    }

    func testAGestureFollowsThePenOverAnotherPageInsteadOfCuttingStraightAcross() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        h.app.settings.set(NibSettings.eraserMode, EraserMode.standard.rawValue)
        h.app.settings.set(NibSettings.eraserSize, 6)
        // A 40 pt vertical line at x = 50 near the top of page 2 (below page 1 on the fake canvas).
        let points = (0...40).map { StrokePoint(x: 50, y: Float($0), t: Float($0) * 0.01, width: 2, height: 2) }
        seedPage2(h, [Item(id: "VERT", kind: .stroke, z: "V",
                           stroke: Stroke(style: InkStyle(tool: .pen, pen: .ball, width: 2), points: points))])
        let page1Before = try items(h)
        let host = FakeCanvasHost(h)
        let tool = EraserTool()
        tool.activate(host)
        // Starts left of the line on page 2, goes up over the bottom of page 1, comes back down right of the line.
        tool.touchesBegan(CanvasSample(page: Fixtures.page2, location: Point(20, 20)), host: host)
        tool.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(20, 830)),
                           CanvasSample(page: Fixtures.page1, location: Point(80, 830))], host: host)
        tool.touchesEnded(CanvasSample(page: Fixtures.page2, location: Point(80, 20)), host: host)
        await tool.pendingCommit?.value
        XCTAssertEqual(try items(h, Fixtures.page2).map { $0.id }, ["VERT"], "the eraser went around the line")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)

        // The same detour ending on the line erases it there, on the page the gesture started on.
        tool.touchesBegan(CanvasSample(page: Fixtures.page2, location: Point(20, 20)), host: host)
        tool.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(20, 830)),
                           CanvasSample(page: Fixtures.page1, location: Point(50, 830))], host: host)
        tool.touchesEnded(CanvasSample(page: Fixtures.page2, location: Point(50, 20)), host: host)
        await tool.pendingCommit?.value
        XCTAssertFalse(try items(h, Fixtures.page2).contains { $0.id == "VERT" })
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertEqual(try items(h), page1Before, "nothing on the page the pen passed over is erased")
    }

    func testTheHiddenInkComesBackEvenWhenTheCanvasNeverRendersAgain() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        h.app.settings.set(NibSettings.eraserSize, 6)
        let host = SilentCanvasHost(FakeCanvasHost(h))
        let tool = EraserTool()
        tool.activate(host)
        tool.tap(CanvasSample(page: Fixtures.page1, location: Point(100, 122)), host: host)
        XCTAssertEqual(host.base.hidden[Fixtures.page1] ?? [], [Fixtures.strokeID])
        await tool.pendingCommit?.value
        XCTAssertEqual(host.renderRequests, 1)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertNil(host.base.hidden[Fixtures.page1], "the render timeout shows the page again")
    }

    func testInkHiddenOnOnePageIsShownAgainWhenTheNextGestureIsOnAnotherPage() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        h.app.settings.set(NibSettings.eraserSize, 6)
        let host = FakeCanvasHost(h)
        let tool = EraserTool()
        tool.activate(host)
        tool.touchesBegan(CanvasSample(page: Fixtures.page1, location: Point(100, 100)), host: host)
        tool.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(100, 140))], host: host)
        tool.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(100, 140)), host: host)
        let first = try XCTUnwrap(tool.pendingCommit)
        XCTAssertEqual(host.hidden[Fixtures.page1] ?? [], [Fixtures.strokeID])
        // The next touch lands on page 2 before the first commit's clean-up ran.
        tool.touchesBegan(CanvasSample(page: Fixtures.page2, location: Point(50, 50)), host: host)
        tool.touchesEnded(CanvasSample(page: Fixtures.page2, location: Point(50, 50)), host: host)
        await first.value
        await tool.pendingCommit?.value
        XCTAssertNil(host.hidden[Fixtures.page1], "the first gesture's clean-up shows its page again")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertNoThrow(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID))
        XCTAssertNil(host.hidden[Fixtures.page1], "ink restored by undo is visible")
    }

    func testTapErasesWhereTheEraserLands() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        h.app.settings.set(NibSettings.eraserMode, EraserMode.standard.rawValue)
        h.app.settings.set(NibSettings.eraserSize, 6)
        let host = FakeCanvasHost(h)
        let tool = EraserTool()
        tool.activate(host)
        tool.tap(CanvasSample(page: Fixtures.page1, location: Point(100, 122)), host: host)
        await tool.pendingCommit?.value
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "one tap, one ink.erase")
        XCTAssertEqual(try items(h).filter { $0.stroke?.style.tool == .pen }.count, 2, "the tapped stroke is cut there")
        XCTAssertNil(host.hidden[Fixtures.page1])
    }

    func testZoomedFarOutALargeEraserStaysWithinWhatInkEraseTakes() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        h.app.settings.set(NibSettings.eraserSize, 60)
        let host = FakeCanvasHost(h)
        host.zoomScale = 0.05                                  // 60 pt on screen = a 600 pt radius on the page
        let tool = EraserTool()
        tool.activate(host)
        tool.touchesBegan(CanvasSample(page: Fixtures.page1, location: Point(100, 122)), host: host)
        tool.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(100, 122)), host: host)
        await tool.pendingCommit?.value
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "the radius is clamped, so ink.erase accepts it")
        XCTAssertNil(try items(h).first { $0.id == Fixtures.strokeID })
    }

    func testAScrubLongerThanOneInkEraseCallIsStillOneUndoStep() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        h.app.settings.set(NibSettings.eraserMode, EraserMode.standard.rawValue)
        h.app.settings.set(NibSettings.eraserSize, 6)
        let before = try h.snapshot()
        let host = FakeCanvasHost(h)
        let tool = EraserTool()
        tool.activate(host)
        func sample(_ x: Double, _ y: Double) -> CanvasSample { CanvasSample(page: Fixtures.page1, location: Point(x, y)) }
        // Cuts the fixture stroke first, scrubs an empty spot for a whole call's worth of points, then crosses the tape:
        // the path goes out in two ink.erase calls and each of them erases something.
        tool.touchesBegan(sample(100, 100), host: host)
        var moves = [sample(100, 140)]
        moves += (0..<NibLimits.maxErasePathPoints).map { sample(300, $0 % 2 == 0 ? 300 : 301) }
        moves += [sample(170, 580), sample(170, 620)]
        tool.touchesMoved(moves, host: host)
        tool.touchesEnded(sample(170, 620), host: host)
        await tool.pendingCommit?.value
        let left = try items(h)
        XCTAssertEqual(left.filter { $0.stroke?.style.tool == .pen }.count, 2)
        XCTAssertFalse(left.contains { $0.id == Fixtures.tapeID }, "the second call erased the tape")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "both calls share one undo group")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testEraserToolCancelShowsEverythingAndErasesNothing() throws {
        let h = Harness(features: [FeatEraserFeature.self])
        h.app.settings.set(NibSettings.eraserSize, 6)
        let host = FakeCanvasHost(h)
        let tool = EraserTool()
        tool.activate(host)
        tool.touchesBegan(CanvasSample(page: Fixtures.page1, location: Point(100, 100)), host: host)
        tool.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(100, 140))], host: host)
        XCTAssertNotNil(host.hidden[Fixtures.page1])
        tool.touchesCancelled(host: host)
        XCTAssertNil(host.hidden[Fixtures.page1])
        XCTAssertNil(tool.pendingCommit)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    // MARK: Settings model (popover and options bar)

    func testEraserPopoverReopensAndClosedSettingsReleasePresetAndCanvasTouches() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let settings = try XCTUnwrap(h.app.ui.toolbar.get("eraser")?.settings?(h.session))
        func root(presented: Bool) -> some View {
            NibDropletContainer {
                NibBudPopover(id: "test.eraser.settings", source: "test.eraser",
                              isPresented: .constant(presented), title: "Eraser") { settings }
            }
        }
        let host = UIHostingController(rootView: root(presented: false))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1376, height: 1032))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for presented in [false, true, false, true, false] {
            host.rootView = root(presented: presented)
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                host.view.layoutIfNeeded()
                let panels = scrollViews(host.view)
                if !panels.isEmpty && panels.allSatisfy({ $0.isUserInteractionEnabled == presented
                    && $0.accessibilityElementsHidden == !presented }) { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let panels = scrollViews(host.view)
            XCTAssertFalse(panels.isEmpty)
            for panel in panels {
                XCTAssertEqual(panel.isUserInteractionEnabled, presented, "reopened mode/filter controls accept touches")
                XCTAssertEqual(panel.accessibilityElementsHidden, !presented)
                if !presented {
                    XCTAssertNil(panel.hitTest(CGPoint(x: panel.bounds.midX, y: panel.bounds.midY), with: nil),
                                 "the closed popover must not intercept size presets or filtered erase gestures")
                }
            }
        }
    }

    func testReloadPreservesUnacknowledgedModeFilterAndSizeChoices() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let model = EraserOptions(app: h.app)
        let bar = EraserOptions(app: h.app)
        model.mode = .stroke
        model.only(.pencil)
        model.selectSize(28)
        // A notification for another eraser setting can reload the model before settings.set runs.
        model.reload()
        XCTAssertEqual(model.mode, .stroke)
        XCTAssertEqual(model.filter, [.pencil])
        XCTAssertEqual(model.size, 28)

        // A second choice must win over both an old command completion and a queued store notification.
        model.only(.tape)
        model.selectSize(6)
        model.reload()
        XCTAssertEqual(model.filter, [.tape])
        XCTAssertEqual(model.size, 6)
        await model.pendingSettingsWrite?.value
        await eventually { bar.mode == .stroke && bar.filter == [.tape] && bar.size == 6 }
        XCTAssertEqual(EraserSettings.mode(h.app.settings), .stroke)
        XCTAssertEqual(EraserSettings.filter(h.app.settings), [.tape])
        XCTAssertEqual(EraserSettings.size(h.app.settings), 6)
        XCTAssertEqual(bar.mode, .stroke)
        XCTAssertEqual(bar.filter, [.tape])
        XCTAssertEqual(bar.size, 6)
    }

    func testFinishedSizeChoiceFlushesSliderAndCannotBeOverwrittenByItsDebounce() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let model = EraserOptions(app: h.app)
        model.size = 52
        model.selectSize(6)
        await model.pendingSettingsWrite?.value
        XCTAssertEqual(EraserSettings.size(h.app.settings), 6, "preset commits without waiting for the slider timer")
        await settle()
        XCTAssertEqual(EraserSettings.size(h.app.settings), 6, "a cancelled slider write cannot replace the preset")
        model.size = 54
        model.flushSizeWrite() // Removing the settings view finishes the drag.
        await model.pendingSettingsWrite?.value
        XCTAssertEqual(EraserSettings.size(h.app.settings), 54)
    }

    func testFilterChoicesReachCanvasAndEachWholeStrokeEraseUndoesIndependently() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let originals = InkTool.allCases.enumerated().map { index, ink in
            line("INK\(index)", y: Float(10 + index * 20), tool: ink, z: "V\(index)")
        }
        seedPage2(h, originals + [line("UNTOUCHED", y: 150, z: "W")])
        h.session.page = Fixtures.page2
        h.session.tool = "eraser"
        let host = FakeCanvasHost(h), tool = EraserTool()
        tool.activate(host)
        let model = EraserOptions(app: h.app)
        model.mode = .stroke
        for (index, ink) in InkTool.allCases.enumerated() {
            if !model.filter.contains(ink) { model.toggle(ink) }
            for other in InkTool.allCases where other != ink && model.filter.contains(other) { model.toggle(other) }
            model.reload()
            XCTAssertEqual(model.filter, [ink])
            await model.pendingSettingsWrite?.value
            let before = try h.snapshot()
            tool.touchesBegan(CanvasSample(page: Fixtures.page2, location: Point(50, 0)), host: host)
            tool.touchesEnded(CanvasSample(page: Fixtures.page2, location: Point(50, 90)), host: host)
            await tool.pendingCommit?.value
            XCTAssertEqual(Set(try items(h, Fixtures.page2).map(\.id)),
                           Set((originals + [line("UNTOUCHED", y: 150, z: "W")]).map(\.id)).subtracting([NibID("INK\(index)")]),
                           "only the enabled \(ink.rawValue) stroke is removed")
            XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
            XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
            XCTAssertEqual(try h.snapshot(), before)
        }
    }

    func testSizeChoicesChangeCanvasCutDiameterAtZoomAndUndoRestoresOriginal() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        seedPage2(h, [line("SIZE", y: 50)])
        h.session.page = Fixtures.page2
        h.session.tool = "eraser"
        let host = FakeCanvasHost(h), tool = EraserTool()
        host.zoomScale = 2
        tool.activate(host)
        let model = EraserOptions(app: h.app)
        model.mode = .precision
        var previousGap = 0.0
        for size in EraserSettings.presets + [54] {
            model.selectSize(size)
            await model.pendingSettingsWrite?.value
            let before = try h.snapshot()
            tool.tap(CanvasSample(page: Fixtures.page2, location: Point(50, 50)), host: host)
            await tool.pendingCommit?.value
            let pieces = try items(h, Fixtures.page2).compactMap(\.stroke).sorted { $0.points[0].x < $1.points[0].x }
            XCTAssertEqual(pieces.count, 2)
            let left = try XCTUnwrap(pieces.first?.points.last)
            let right = try XCTUnwrap(pieces.last?.points.first)
            let gap = Double(right.x - left.x)
            XCTAssertGreaterThan(gap, previousGap)
            XCTAssertEqual(gap, size / host.zoomScale + 2, accuracy: 0.1, "screen diameter plus the ink nib")
            previousGap = gap
            XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
            XCTAssertEqual(try h.snapshot(), before)
        }
    }

    func testDeleteSheetHandwritingChoiceRespectsScopeAndUndoRestoresAllPages() async throws {
        for scope in DeleteItemsScope.allCases {
            let h = Harness(features: [FeatEraserFeature.self])
            seedPage2(h, [line("OTHERPEN", y: 10), line("OTHERPENCIL", y: 30, tool: .pencil, z: "W"),
                          line("OTHERHIGHLIGHT", y: 50, tool: .highlighter, z: "X")])
            let first = try items(h), second = try items(h, Fixtures.page2)
            let before = try h.snapshot()
            var groups: Set<DeleteItemsGroup> = []
            groups[member: .handwriting] = true
            let params = try XCTUnwrap(DeleteItemsGroup.params(doc: h.session.document, page: h.session.page,
                                                               groups: groups, scope: scope))
            let count = DeleteItemsSheet.count(params, app: h.app, session: h.session)
            let result = try await h.run(CommandIDs.pageDeleteItems, params)
            XCTAssertEqual(result["removed"]?.intValue, count)
            func keeps(_ item: Item) -> Bool { item.stroke?.style.tool != .pen && item.stroke?.style.tool != .pencil }
            XCTAssertEqual(try items(h), first.filter(keeps))
            XCTAssertEqual(try items(h, Fixtures.page2), scope == .page ? second : second.filter(keeps))
            XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
            XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
            XCTAssertEqual(try h.snapshot(), before)
        }
    }

    func testEraserOptionsWriteThroughSettingsKeepOneFilterOnAndNeverWriteBack() async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let model = EraserOptions(app: h.app)
        var writes: [String] = []
        let observer = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: h.app.settings)
            .sink { note in writes.append(note.userInfo?["name"] as? String ?? "") }
        defer { observer.cancel() }

        model.toggle(.pen)
        await eventually { !h.app.settings.get(NibSettings.eraserFilter(.pen)) }
        XCTAssertFalse(h.app.settings.get(NibSettings.eraserFilter(.pen)), "a chip writes eraser.filter.pen")

        model.only(.highlighter)
        await eventually { EraserSettings.filter(h.app.settings) == [.highlighter] }
        XCTAssertEqual(EraserSettings.filter(h.app.settings), [.highlighter], "Erase Highlighter Only")
        model.toggle(.highlighter)
        await settle()
        XCTAssertEqual(model.filter, [.highlighter], "the last filter chip stays on")
        XCTAssertEqual(EraserSettings.filter(h.app.settings), [.highlighter])

        writes = []
        model.size = 20
        model.size = 21
        model.size = 22
        await eventually { h.app.settings.get(NibSettings.eraserSize) == 22 }
        await settle()
        XCTAssertEqual(h.app.settings.get(NibSettings.eraserSize), 22)
        XCTAssertEqual(writes.filter { $0 == "eraser.size" }.count, 1, "a slider drag writes once, after it rests")

        writes = []
        h.app.settings.set(NibSettings.eraserMode, EraserMode.precision.rawValue)
        await eventually { model.mode == .precision }
        await settle()
        XCTAssertEqual(model.mode, .precision, "the model follows the store")
        XCTAssertEqual(writes, ["eraser.mode"], "reading values back never writes them")
    }
}

/// A canvas that never reports a render (`afterNextRender` bodies are dropped); everything else is the fake's.
@MainActor
private final class SilentCanvasHost: CanvasHost {
    let base: FakeCanvasHost
    private(set) var renderRequests = 0

    init(_ base: FakeCanvasHost) { self.base = base }

    var app: NibApp { base.app }
    var session: EditorSession { base.session }
    var documentID: DocumentID { base.documentID }
    var zoomScale: Double { base.zoomScale }
    var canvasView: UIView { base.canvasView }
    var overlayLayer: CALayer { base.overlayLayer }
    func viewPoint(_ p: Point, page: PageID) -> CGPoint { base.viewPoint(p, page: page) }
    func pagePoint(_ v: CGPoint) -> (page: PageID, point: Point)? { base.pagePoint(v) }
    func pageFrame(_ page: PageID) -> CGRect? { base.pageFrame(page) }
    func setHidden(_ ids: Set<ElementID>, page: PageID) { base.setHidden(ids, page: page) }
    func invalidate(page: PageID, rect: Rect?) { base.invalidate(page: page, rect: rect) }
    func commitStroke(_ stroke: Stroke, page: PageID) { base.commitStroke(stroke, page: page) }
    func cancelWetStroke() { base.cancelWetStroke() }
    func attachLiveView(_ view: UIView?, item: ElementID, page: PageID) { base.attachLiveView(view, item: item, page: page) }
    func afterNextRender(page: PageID, _ body: @escaping @MainActor () -> Void) { renderRequests += 1 }
}
