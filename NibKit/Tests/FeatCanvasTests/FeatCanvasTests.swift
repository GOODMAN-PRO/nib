import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibTesting
import NibDesign
@testable import FeatCanvas

/// The canvas (F006) end to end on the fixture documents: registration, the view.* and canvas.* commands on a live
/// canvas, attachments, decorations, the CanvasHost hooks (contracts-v2 G14), tiles from the renderer, boards and
/// horizontal paging.
@MainActor
final class FeatCanvasTests: XCTestCase {
    private let windowSize = CGSize(width: 834, height: 1194)

    // MARK: Helpers

    /// Opens the editor the feature registered for `doc`'s kind in a window-sized view, laid out.
    @discardableResult
    private func makeCanvas(_ h: Harness, doc: DocumentID = Fixtures.docID, page: PageID? = nil,
                            input: ((CanvasHostImpl) -> Void)? = nil, size: CGSize? = nil) throws -> CanvasViewController {
        let content = try h.app.workspace.content(doc)
        h.session.document = doc
        h.session.page = page ?? content.livePages.first?.id
        let descriptor = try XCTUnwrap(h.app.ui.editors.get(content.meta.kind.rawValue), "no editor for \(content.meta.kind)")
        // The input half (F101) is swapped for the test's probe (or none) while this canvas opens.
        let saved = CanvasInputHooks.install
        CanvasInputHooks.install = input
        defer { CanvasInputHooks.install = saved }
        let vc = try XCTUnwrap(descriptor.make(doc, h.session, h.app) as? CanvasViewController)
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(origin: .zero, size: size ?? windowSize)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        if !vc.didInitialLayout { vc.viewDidLayoutSubviews() }
        XCTAssertTrue(vc.didInitialLayout)
        return vc
    }

    /// Where a page point is in the window (the scroll view's frame).
    private func windowPoint(_ vc: CanvasViewController, _ p: Point, _ page: PageID) -> CGPoint {
        let v = vc.host.viewPoint(p, page: page)
        return CGPoint(x: v.x - vc.scrollView.bounds.minX, y: v.y - vc.scrollView.bounds.minY)
    }

    /// The part of the window the chrome leaves free, in scroll view coordinates.
    private func unobscured(_ vc: CanvasViewController) -> CGRect {
        let b = vc.scrollView.bounds
        let i = vc.scrollView.chromeInsets
        return CGRect(x: b.minX + i.left, y: b.minY + i.top, width: b.width - i.left - i.right,
                      height: b.height - i.top - i.bottom)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func assertThrows(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    /// A stand-in for F007's `ink.addStrokes`: writes the strokes on the page and returns their refs.
    private func registerInkStandIn(_ h: Harness) {
        h.app.commands.register(CommandDescriptor(
            id: CommandIDs.inkAddStrokes, title: "Add Strokes", summary: "Test stand-in for ink.addStrokes.",
            params: .obj(["page": .ref, "strokes": .arr(.anything())], required: ["page", "strokes"]),
            effect: .edit)) { params, ctx in
            guard case let .page(doc, page)? = NodeRef(params["page"]?.stringValue ?? "") else {
                throw NibError.invalid("page")
            }
            let strokes = try (params["strokes"] ?? .array([])).decode([Stroke].self)
            let written = try ctx.mutate { tx in
                try tx.put(strokes.map { Item(kind: .stroke, stroke: $0) }, doc: doc, page: page)
            }
            return ["refs": .array(written.map { .string(NodeRef.item(doc, page, $0.id).description) })]
        }
    }

    private func stroke(y: Float = 200) -> Stroke {
        Stroke(style: .defaultPen, points: (0..<12).map { StrokePoint(x: Float(100 + $0 * 6), y: y, t: Float($0) * 0.01) },
               t0: 1_700_000_500)
    }

    // MARK: Registration

    func testRegistersEditorsCommandsAttachmentOverlaysAndKeys() {
        let h = Harness(features: [FeatCanvasFeature.self])
        XCTAssertEqual(FeatCanvasFeature.id, "canvas")
        for kind in [DocumentKind.notebook, .whiteboard] {
            XCTAssertEqual(h.app.ui.editors.get(kind.rawValue)?.owner, "canvas", "\(kind)")
        }
        XCTAssertNil(h.app.ui.editors.get(DocumentKind.textDocument.rawValue))
        // contracts-v2.1: every command registers under its catalogue constant.
        XCTAssertEqual([ViewGoToPage.descriptor.id, ViewZoom.descriptor.id, ViewScrollBy.descriptor.id,
                        ViewReveal.descriptor.id, CanvasDecorate.descriptor.id, CanvasClearDecorations.descriptor.id],
                       [CommandIDs.viewGoToPage, CommandIDs.viewZoom, CommandIDs.viewScrollBy, CommandIDs.viewReveal,
                        CommandIDs.canvasDecorate, CommandIDs.canvasClearDecorations])
        for id in ["view.goToPage", "view.zoom", "view.scrollBy", "view.reveal", "canvas.decorate", "canvas.clearDecorations"] {
            let d = h.app.commands.descriptor(id)
            XCTAssertEqual(d?.owner, "canvas", id)
            XCTAssertEqual(d?.effect, .session, id)
            XCTAssertFalse(d?.examples.isEmpty ?? true, id)
        }
        let decorations = h.app.ui.canvasAttachments.get(DecorationAttachment.id)
        XCTAssertEqual(decorations?.owner, "canvas")
        XCTAssertEqual(decorations?.docKinds, [.notebook, .whiteboard])
        XCTAssertTrue(DecorationStore.shared(h.app) === h.app.services.get(DecorationStore.serviceKey, as: DecorationStore.self))

        let pageHUD = h.app.ui.chromeOverlays.get(CanvasChrome.pageHUD)
        XCTAssertEqual(pageHUD?.placement, .bottomTrailing)
        XCTAssertEqual(pageHUD?.surface, .hud)
        XCTAssertEqual(pageHUD?.docKinds, [.notebook, .whiteboard], "a board's page HUD shows its zoom")
        let zoomHUD = h.app.ui.chromeOverlays.get(CanvasChrome.zoomHUD)
        XCTAssertEqual(zoomHUD?.placement, .top)
        XCTAssertEqual(zoomHUD?.isInteractive, false)

        let down = h.app.content.keyCommands.get("canvas.pan.down")
        XCTAssertEqual(down?.shortcut, KeyShortcut("down", [.option]))
        XCTAssertEqual(down?.command, "view.scrollBy")
        XCTAssertEqual(down?.params["dy"]?.doubleValue, 0.9)
        XCTAssertEqual(down?.params["unit"]?.stringValue, "window")
        XCTAssertEqual(down?.scope, .canvas)
        for id in ["canvas.pan.up", "canvas.pan.left", "canvas.pan.right"] {
            XCTAssertEqual(h.app.content.keyCommands.get(id)?.command, "view.scrollBy", id)
        }
    }

    /// Shell v2 (contracts-v2.2 key routing): the ⌥-arrow pans are live only in a notebook or whiteboard while no text
    /// is being edited, win their shortcuts there, take priority over the system's ⌥-arrow, and reach `view.scrollBy`
    /// with their own params (the command finds the window from the session the shell passes).
    func testPanKeysAreLiveOnlyOnTheCanvasOfNotebooksAndWhiteboards() {
        let h = Harness(features: [FeatCanvasFeature.self])
        let pans = CanvasKeys.pans.compactMap { h.app.content.keyCommands.get($0.id) }
        XCTAssertEqual(pans.count, 4)
        let all = h.app.content.keyCommands.all
        for kind in [DocumentKind.notebook, .whiteboard] {
            let context = KeyCommandContext(docKind: kind, hasTabs: true)
            let live = Set(KeyCommandRouting.active(all, in: context).map { $0.id })
            for pan in pans {
                XCTAssertTrue(live.contains(pan.id), "\(pan.id) in \(kind)")
                XCTAssertTrue(KeyCommandRouting.overridesSystemKeys(pan, in: context), pan.id)
                XCTAssertEqual(pan.resolvedParams(for: h.session), pan.params, pan.id)
            }
            let editing = KeyCommandContext(docKind: kind, isEditingText: true, hasTabs: true)
            XCTAssertTrue(pans.allSatisfy { !$0.isActive(in: editing) }, "text being edited keeps ⌥-arrow in \(kind)")
        }
        for context in [KeyCommandContext(docKind: .textDocument), KeyCommandContext(docKind: .studySet),
                        KeyCommandContext(docKind: nil, hasTabs: true)] {
            XCTAssertTrue(pans.allSatisfy { !$0.isActive(in: context) }, "\(context)")
        }
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatCanvasFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Opening

    func testNotebookOpensAtFitWidthOnTheCurrentPage() throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        XCTAssertTrue(h.session.editor === vc)
        XCTAssertTrue(vc.canvasHost === vc.host)
        XCTAssertTrue(vc.host.canvasView === vc.scrollView, "canvasView is the scroll view")
        XCTAssertTrue(vc.host.fixedOverlayView === vc.fixedOverlay)
        XCTAssertTrue(vc.fixedOverlay.superview === vc.view)
        XCTAssertEqual(vc.mode, .stack(.vertical))
        XCTAssertEqual(vc.scrollView.pages, [Fixtures.page1, Fixtures.page2, Fixtures.pdfPage])
        XCTAssertEqual(vc.scrollView.layout.slotStarts[1] - PageSize.a4.height, 16, accuracy: 1e-9, "16 pt between pages")
        XCTAssertEqual(vc.zoom, vc.fitZoom, accuracy: 1e-9)
        XCTAssertEqual(vc.zoomLimits.lowerBound, 0.5)
        XCTAssertEqual(vc.zoomLimits.upperBound, 8)
        XCTAssertEqual(h.session.page, Fixtures.page1)

        // DESIGN.md §14.2: at fit a portrait window shows the page its width less the desk margins, centred, with its
        // top just below the bars.
        let margin: CGFloat = vc.isCompact ? 12 : 16
        let frame = try XCTUnwrap(vc.host.pageFrame(Fixtures.page1))
        XCTAssertEqual(frame.width, windowSize.width - 2 * margin, accuracy: 0.5)
        XCTAssertEqual(frame.midX - vc.scrollView.bounds.minX, windowSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(frame.minY - vc.scrollView.bounds.minY, vc.scrollView.chromeInsets.top, accuracy: 0.5)
        XCTAssertEqual(vc.scrollView.chromeInsets.top, 8 + 44 + 12, accuracy: 0.5, "below the nav bar")
        // The scroll indicator (draggable, D-118) runs between the bars and the bottom inset.
        XCTAssertTrue(vc.scrollView.showsVerticalScrollIndicator)
        XCTAssertEqual(vc.scrollView.verticalScrollIndicatorInsets, vc.scrollView.chromeInsets)

        // Only the pages near the window have views; paper shadows sit under them.
        XCTAssertNotNil(vc.scrollView.pageViews[Fixtures.page1])
        XCTAssertNotNil(vc.scrollView.pageViews[Fixtures.page2])
        XCTAssertNil(vc.scrollView.pageViews[Fixtures.pdfPage])
        // No renderer in this app: the pages show their paper and nothing else, and that is not an error.
        XCTAssertEqual(vc.scrollView.pageViews[Fixtures.page1]?.contentAlpha, 0)
        XCTAssertTrue(vc.failedPages.isEmpty)

        // The HUD reads "1 / 3".
        XCTAssertEqual(vc.hud.pageIndex, 0)
        XCTAssertEqual(vc.hud.pageCount, 3)
        XCTAssertEqual(vc.hud.primaryText, "1")
        XCTAssertEqual(vc.hud.secondaryText, "/ 3")
        XCTAssertEqual(vc.hud.zoomPercent, ZoomRules.percent(vc.zoom))
    }

    func testTopDockAutomaticallyKeepsFittedPageBelowOptionsInBothAppearances() async throws {
        for (size, compact) in [(CGSize(width: 834, height: 1194), false),
                                (CGSize(width: 844, height: 390), true)] {
            for appearance in [UIUserInterfaceStyle.light, .dark] {
                let h = Harness(features: [FeatCanvasFeature.self])
                // Stand in for the toolbar screen without importing another feature's implementation.
                h.app.ui.screens.toolbarView = { _, _ in AnyView(EmptyView()) }
                h.app.settings.setJSON(CommandIDs.toolbarDock, ["edge": "bottom", "along": 0.5])
                let vc = try makeCanvas(h, page: Fixtures.page2, size: size)
                defer { vc.closeCanvas() }
                vc.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
                vc.overrideUserInterfaceStyle = appearance
                vc.view.setNeedsLayout()
                vc.view.layoutIfNeeded()
                _ = try await h.run("view.zoom", ["fit": true])
                let originalTop = vc.scrollView.chromeInsets.top

                h.app.settings.setJSON(CommandIDs.toolbarDock, ["edge": "top", "along": 0.5])
                await waitUntil("top dock clearance") {
                    vc.view.layoutIfNeeded()
                    return vc.scrollView.chromeInsets.top > originalTop
                }
                XCTAssertEqual(vc.scrollView.chromeInsets.bottom, vc.view.safeAreaInsets.bottom + NibSpacing.l,
                               accuracy: 0.5, "top docking releases the empty bottom palette rail")
                // Docking alone must keep the fitted page clear of both the palette and its options.
                let safe = vc.view.safeAreaInsets
                let paletteRegion = DropletDockModel.region(
                    size: vc.view.bounds.size,
                    safeArea: EdgeInsets(top: safe.top, leading: safe.left, bottom: safe.bottom, trailing: safe.right),
                    compact: compact)
                let pageTop = windowPoint(vc, .zero, Fixtures.page2).y
                XCTAssertGreaterThanOrEqual(pageTop, paletteRegion.minY + NibMetrics.paletteThickness
                                            + NibMetrics.barHeight + NibSpacing.m - 0.5)
                XCTAssertEqual(pageTop, vc.scrollView.chromeInsets.top, accuracy: 0.5)
                XCTAssertEqual(vc.zoom, vc.fitZoom, accuracy: 1e-9)
                XCTAssertEqual(h.session.page, Fixtures.page2)
                XCTAssertGreaterThan(vc.view.bounds.height - vc.scrollView.chromeInsets.top
                                     - vc.scrollView.chromeInsets.bottom, vc.view.bounds.height / 2)

                // Docking back automatically uses the released clearance on the same page.
                h.app.settings.setJSON(CommandIDs.toolbarDock, ["edge": "bottom", "along": 0.5])
                await waitUntil("bottom dock clearance") {
                    vc.view.layoutIfNeeded()
                    return vc.scrollView.chromeInsets.top == originalTop
                }
                XCTAssertEqual(vc.zoom, vc.fitZoom, accuracy: 1e-9)
                XCTAssertEqual(windowPoint(vc, .zero, Fixtures.page2).y, originalTop, accuracy: 0.5)
                XCTAssertEqual(h.session.page, Fixtures.page2)
            }
        }
    }

    func testLandscapeOpeningTextClearsBottomOptionsAndLassoChevron() async throws {
        let size = CGSize(width: 874, height: 402)
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            for settingsOnly in [false, true] {
                let h = Harness(features: [FeatCanvasFeature.self])
                h.app.ui.screens.toolbarView = { _, _ in AnyView(EmptyView()) }
                h.app.settings.setJSON(CommandIDs.toolbarDock, ["edge": "bottom", "along": 0.5])
                var openingTool = ToolbarItemDescriptor(
                    id: "test.openingTool", title: "Opening Tool", icon: "", group: .lasso, order: 0,
                    owner: "test", toolID: h.session.tool,
                    settings: { _ in AnyView(EmptyView()) })
                if !settingsOnly { openingTool.activeToolMenu = { _ in AnyView(EmptyView()) } }
                h.app.ui.toolbar.register(openingTool)
                // The heading and two-line opening paragraph have enough blank header to recover useful height.
                let title = Item(kind: .text, text: TextBoxItem(
                    frame: Frame(x: 72, y: 72, w: 400, h: 32), text: RichText(plain: "Motion & forces")))
                let body = Item(kind: .text, text: TextBoxItem(
                    frame: Frame(x: 72, y: 128, w: 440, h: 40),
                    text: RichText(plain: "Understanding how objects move\nVelocity, acceleration and Newton's laws")))
                _ = try await h.insert([title, body], page: Fixtures.page2)
                let vc = try makeCanvas(h, page: Fixtures.page2, size: size)
                defer { vc.closeCanvas() }
                vc.traitOverrides.horizontalSizeClass = .compact
                vc.overrideUserInterfaceStyle = appearance
                vc.view.setNeedsLayout()
                vc.view.layoutIfNeeded()
                let region = DropletDockModel.region(size: size, safeArea: EdgeInsets(), compact: true)
                XCTAssertGreaterThanOrEqual(vc.scrollView.chromeInsets.bottom,
                    size.height - region.maxY + NibMetrics.paletteThickness + NibMetrics.barHeight + NibSpacing.l,
                    "both a full options bar and a settings-only chevron reserve the entire arm before measurement")
                // Apply EditorHost's measured landscape geometry directly so this regression is independent of
                // the test runner's physical device/orientation. Hosted automatic refits are tested below.
                let bottomExtra = NibMetrics.barHeight - 1
                for tabs in [CGFloat.zero, NibMetrics.tabCapsuleHeight, 0] {
                    vc.scrollView.chromeInsets = CanvasChromeInsets.resolve(
                        safeArea: UIEdgeInsets(top: tabs, left: 62, bottom: 21 + bottomExtra, right: 62),
                        additional: UIEdgeInsets(top: tabs, left: 0, bottom: bottomExtra, right: 0),
                        compact: true, topDocked: false, fallbackTop: nil)
                    vc.reloadAll()
                    vc.setZoom(vc.fitZoom, anchor: nil, centreFit: true)
                    let clearance = unobscured(vc)
                    let transform = try XCTUnwrap(vc.host.pageTransform(Fixtures.page2))
                    let headingRect = h.app.content.paintBounds(for: title).cg.applying(transform)
                    let bodyRect = h.app.content.paintBounds(for: body).cg.applying(transform)
                    XCTAssertGreaterThanOrEqual(headingRect.minY, clearance.minY)
                    XCTAssertLessThanOrEqual(bodyRect.maxY, clearance.maxY,
                                             "the full paragraph clears the options lens, including with tabs")
                    XCTAssertEqual(vc.scrollView.chromeInsets.bottom,
                                   21 + bottomExtra + NibMetrics.canvasBottomInsetCompact)
                    XCTAssertEqual(vc.zoom, vc.fitZoom, accuracy: 1e-9)
                    XCTAssertEqual(h.session.page, Fixtures.page2)
                    let position = windowPoint(vc, Point(72, 128), Fixtures.page2)
                    vc.reloadAll()
                    XCTAssertEqual(windowPoint(vc, Point(72, 128), Fixtures.page2).y, position.y, accuracy: 0.5)
                }
                vc.scrollBy(dx: 0, dy: 24, windowFractions: false, animated: false)
                let manualPosition = windowPoint(vc, Point(72, 128), Fixtures.page2)
                vc.scrollView.chromeInsets.bottom += NibSpacing.m
                vc.reloadAll()
                XCTAssertEqual(windowPoint(vc, Point(72, 128), Fixtures.page2).y, manualPosition.y, accuracy: 0.5,
                               "a later options measurement does not move a manually chosen reading position")
                // Explicit fit uses the opening content again; a blank page still starts at its top edge.
                vc.setZoom(vc.fitZoom, anchor: nil, centreFit: true)
                let titleBounds = h.app.content.paintBounds(for: title)
                XCTAssertEqual(windowPoint(vc, Point(titleBounds.x, titleBounds.y), Fixtures.page2).y,
                               vc.scrollView.chromeInsets.top + NibSpacing.m, accuracy: 0.5)
                vc.goToPage(Fixtures.pdfPage, animated: false)
                XCTAssertEqual(windowPoint(vc, .zero, Fixtures.pdfPage).y, vc.scrollView.chromeInsets.top, accuracy: 0.5)
            }
        }
    }

    func testMeasuredChromeAndTabsRefitUntouchedPagesAndPreserveManualAnchors() throws {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834),
                     CGSize(width: 844, height: 390)] {
            for (zoomIn, pan) in [(false, false), (false, true), (true, false), (true, true)] {
                let h = Harness(features: [FeatCanvasFeature.self])
                h.app.ui.screens.toolbarView = { _, _ in AnyView(EmptyView()) }
                h.app.settings.setJSON(CommandIDs.toolbarDock, ["edge": "top", "along": 0.5])
                let vc = try makeCanvas(h, page: Fixtures.page2, size: size)
                defer { vc.closeCanvas() }
                if zoomIn {
                    vc.setZoom(vc.fitZoom * 2, anchor: nil, centreFit: false)
                }
                if pan { vc.scrollBy(dx: 0, dy: 160, windowFractions: false, animated: false) }
                let point = Point(200, 200)
                // Model EditorHost's measured clearance, then add/remove the optional tab band.
                // Keep the canvas in a real window so UIKit incorporates additionalSafeAreaInsets.
                let window = UIWindow(frame: CGRect(origin: .zero, size: size))
                window.rootViewController = vc
                window.isHidden = false
                defer { window.isHidden = true; window.rootViewController = nil }
                window.layoutIfNeeded()
                vc.view.layoutIfNeeded()
                let hostedAnchor = windowPoint(vc, point, Fixtures.page2)
                let hostedZoom = vc.zoom
                for extra in [CGFloat(120), 120 + NibMetrics.tabCapsuleHeight, 120, 0] {
                    vc.additionalSafeAreaInsets.top = extra
                    vc.view.setNeedsLayout()
                    vc.view.layoutIfNeeded()
                    let laidOutAnchor = windowPoint(vc, point, Fixtures.page2)
                    if zoomIn || pan {
                        XCTAssertEqual(laidOutAnchor.x, hostedAnchor.x, accuracy: 0.5)
                        XCTAssertEqual(laidOutAnchor.y, hostedAnchor.y, accuracy: 0.5)
                        XCTAssertEqual(vc.zoom, hostedZoom, accuracy: 1e-9)
                    } else {
                        XCTAssertEqual(windowPoint(vc, .zero, Fixtures.page2).y,
                                       vc.scrollView.chromeInsets.top, accuracy: 0.5)
                        XCTAssertEqual(vc.zoom, vc.fitZoom, accuracy: 1e-9)
                    }
                    // The shell's reload must retain the newly fitted position or the manual reading anchor.
                    let laidOutZoom = vc.zoom
                    vc.reloadAll()
                    let after = windowPoint(vc, point, Fixtures.page2)
                    XCTAssertEqual(after.x, laidOutAnchor.x, accuracy: 0.5)
                    XCTAssertEqual(after.y, laidOutAnchor.y, accuracy: 0.5)
                    XCTAssertEqual(vc.zoom, laidOutZoom, accuracy: 1e-9)
                    XCTAssertEqual(h.session.page, Fixtures.page2)
                    if extra > 0 {
                        XCTAssertEqual(vc.scrollView.chromeInsets.top,
                                       vc.view.safeAreaInsets.top + NibMetrics.barTopGap
                                       + NibMetrics.barHeight + NibSpacing.m, accuracy: 0.5)
                    }
                }
            }
        }
    }

    func testDockChangePreservesManualZoomAndPanIncludingPanAtFitWidth() async throws {
        for zoomIn in [false, true] {
            let h = Harness(features: [FeatCanvasFeature.self])
            h.app.ui.screens.toolbarView = { _, _ in AnyView(EmptyView()) }
            h.app.settings.setJSON(CommandIDs.toolbarDock, ["edge": "bottom", "along": 0.5])
            let vc = try makeCanvas(h, size: CGSize(width: 844, height: 390))
            defer { vc.closeCanvas() }
            vc.traitOverrides.horizontalSizeClass = .compact
            vc.view.setNeedsLayout()
            vc.view.layoutIfNeeded()
            if zoomIn { vc.setZoom(vc.fitZoom * 2, anchor: nil, centreFit: false) }
            vc.scrollBy(dx: zoomIn ? 40 : 0, dy: 160, windowFractions: false, animated: false)
            let point = Point(200, 200)
            let before = windowPoint(vc, point, Fixtures.page1)
            let zoom = vc.zoom
            let top = vc.scrollView.chromeInsets.top

            h.app.settings.setJSON(CommandIDs.toolbarDock, ["edge": "top", "along": 0.5])
            await waitUntil("manual view's new chrome inset") {
                vc.view.layoutIfNeeded()
                return vc.scrollView.chromeInsets.top > top
            }
            let after = windowPoint(vc, point, Fixtures.page1)
            XCTAssertEqual(after.x, before.x, accuracy: 0.5)
            XCTAssertEqual(after.y, before.y, accuracy: 0.5)
            XCTAssertEqual(vc.zoom, zoom, accuracy: 1e-9)

            // Explicit fit restores the page-first position after manual navigation.
            _ = try await h.run("view.zoom", ["fit": true])
            XCTAssertEqual(windowPoint(vc, .zero, Fixtures.page1).y, vc.scrollView.chromeInsets.top, accuracy: 0.5)
        }
    }

    func testGeometryRoundTripsThroughPageTransformAndConvert() throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let host = vc.host
        let p = Point(123.5, 456.25)
        let v = host.viewPoint(p, page: Fixtures.page1)
        let t = try XCTUnwrap(host.pageTransform(Fixtures.page1))
        let viaTransform = CGPoint(x: p.x, y: p.y).applying(t)
        XCTAssertEqual(viaTransform.x, v.x, accuracy: 1e-6)
        XCTAssertEqual(viaTransform.y, v.y, accuracy: 1e-6)
        XCTAssertEqual(Double(t.a), host.zoomScale, accuracy: 1e-9)
        let back = try XCTUnwrap(host.pagePoint(v))
        XCTAssertEqual(back.page, Fixtures.page1)
        XCTAssertEqual(back.point.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(back.point.y, p.y, accuracy: 1e-6)
        // pageFrame is the page's rect in the same (scroll view bounds) coordinates.
        let frame = try XCTUnwrap(host.pageFrame(Fixtures.page1))
        XCTAssertEqual(frame.origin.x, t.tx, accuracy: 1e-6)
        XCTAssertEqual(frame.origin.y, t.ty, accuracy: 1e-6)
        // A point on page 1 in page 2's coordinates: one slot (page height + gap) up.
        let c = try XCTUnwrap(host.convert(Point(10, 20), from: Fixtures.page1, to: Fixtures.page2))
        XCTAssertEqual(c.x, 10, accuracy: 1e-9)
        XCTAssertEqual(c.y, 20 - (PageSize.a4.height + 16), accuracy: 1e-9)
        XCTAssertEqual(host.convert(Point(1, 2), from: Fixtures.page2, to: Fixtures.page2), Point(1, 2))
        XCTAssertNil(host.convert(Point(1, 2), from: Fixtures.page1, to: "NOSUCHPAGE01"))
        // Nothing in the gap between pages.
        let gap = host.viewPoint(Point(100, PageSize.a4.height + 8), page: Fixtures.page1)
        XCTAssertNil(host.pagePoint(gap))
    }

    func testEditingInteractionIsOffUnlessTextIsBeingEdited() throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        XCTAssertEqual(vc.editingInteractionConfiguration, UIEditingInteractionConfiguration.none)
        h.session.isEditingText = true
        XCTAssertEqual(vc.editingInteractionConfiguration, UIEditingInteractionConfiguration.default)
    }

    // MARK: view.goToPage

    func testGoToPageScrollsThePageToTheTop() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let r = try await h.run("view.goToPage", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(r["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG002")
        XCTAssertEqual(r["index"]?.intValue, 1)
        XCTAssertEqual(r["count"]?.intValue, 3)
        XCTAssertEqual(h.session.page, Fixtures.page2)
        let f2 = try XCTUnwrap(vc.host.pageFrame(Fixtures.page2))
        XCTAssertEqual(f2.minY - vc.scrollView.bounds.minY, vc.scrollView.chromeInsets.top, accuracy: 0.5)
        XCTAssertEqual(vc.hud.pageIndex, 1)

        let last = try await h.run("view.goToPage", ["index": -1])
        XCTAssertEqual(last["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG003")
        XCTAssertEqual(h.session.page, Fixtures.pdfPage)
        XCTAssertNotNil(vc.scrollView.pageViews[Fixtures.pdfPage])

        let first = try await h.run("view.goToPage", ["index": 0, "doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(first["index"]?.intValue, 0)
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertEqual(h.session.zoom, vc.zoom, accuracy: 1e-9)

        await assertThrows(.invalidParams) { _ = try await h.run("view.goToPage", ["index": 3]) }
        await assertThrows(.invalidParams) { _ = try await h.run("view.goToPage", [:]) }
        await assertThrows(.notFound) { _ = try await h.run("view.goToPage", ["page": "page:FIXTUREDOC01/NOSUCHPAGE01"]) }
    }

    func testGoToPageWithoutAnEditorMovesTheSessionPage() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        XCTAssertNil(h.session.editor)
        let r = try await h.run("view.goToPage", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(r["index"]?.intValue, 1)
        XCTAssertEqual(h.session.page, Fixtures.page2)
        // Zooming needs a canvas.
        await assertThrows(.unavailable) { _ = try await h.run("view.zoom", ["scale": 2]) }
        await assertThrows(.unavailable) { _ = try await h.run("view.scrollBy", ["dx": 0, "dy": 100]) }
    }

    func testCanvasFollowsSessionPageChangesMadeElsewhere() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        h.session.page = Fixtures.page2
        await waitUntil("the canvas to scroll to page 2") {
            guard let f = vc.host.pageFrame(Fixtures.page2) else { return false }
            return abs(f.minY - vc.scrollView.bounds.minY - vc.scrollView.chromeInsets.top) < 0.5
        }
        XCTAssertEqual(vc.displayedPage, Fixtures.page2)
    }

    // MARK: view.zoom

    func testZoomScaleFitActualStepAndLimits() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let two = try await h.run("view.zoom", ["scale": 2])
        XCTAssertEqual(two["scale"]?.doubleValue ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(two["percent"]?.intValue, 200)
        XCTAssertEqual(two["min"]?.doubleValue, 0.5)
        XCTAssertEqual(two["max"]?.doubleValue, 8)
        XCTAssertEqual(vc.host.zoomScale, 2, accuracy: 1e-9)
        XCTAssertEqual(h.session.zoom, 2, accuracy: 1e-9)
        XCTAssertEqual(vc.hud.zoomPercent, 200)

        let fit = try await h.run("view.zoom", ["fit": true])
        XCTAssertEqual(fit["scale"]?.doubleValue ?? 0, vc.fitZoom, accuracy: 1e-9)

        _ = try await h.run("view.zoom", ["actual": true])
        XCTAssertEqual(vc.zoom, 1, accuracy: 1e-9)
        _ = try await h.run("view.zoom", ["step": "in"])
        XCTAssertEqual(vc.zoom, 1.25, accuracy: 1e-9)
        _ = try await h.run("view.zoom", ["step": "out"])
        XCTAssertEqual(vc.zoom, 1, accuracy: 1e-9)

        // 50–800 %.
        _ = try await h.run("view.zoom", ["scale": 12])
        XCTAssertEqual(vc.zoom, 8, accuracy: 1e-9)
        _ = try await h.run("view.zoom", ["scale": 0.1])
        XCTAssertEqual(vc.zoom, 0.5, accuracy: 1e-9)

        await assertThrows(.invalidParams) { _ = try await h.run("view.zoom", [:]) }
        await assertThrows(.invalidParams) { _ = try await h.run("view.zoom", ["step": "sideways"]) }
    }

    func testZoomAroundAPagePointKeepsItStill() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let p = Point(100, 100)
        let before = windowPoint(vc, p, Fixtures.page1)
        _ = try await h.run("view.zoom", ["scale": 3, "at": [100, 100], "page": "page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertEqual(vc.zoom, 3, accuracy: 1e-9)
        let after = windowPoint(vc, p, Fixtures.page1)
        XCTAssertEqual(after.x, before.x, accuracy: 0.5)
        XCTAssertEqual(after.y, before.y, accuracy: 0.5)
    }

    func testDoubleTapTogglesBetweenFitAndTwiceFit() throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let recognizer = vc.host.doubleTapZoomRecognizer
        XCTAssertEqual(recognizer.numberOfTapsRequired, 2)
        XCTAssertTrue(recognizer.view === vc.scrollView)
        XCTAssertEqual(recognizer.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)], "fingers only")
        let fit = vc.fitZoom
        let point = vc.host.viewPoint(Point(300, 400), page: Fixtures.page1)
        let before = windowPoint(vc, Point(300, 400), Fixtures.page1)
        vc.host.zoomToggle(at: point)
        XCTAssertEqual(vc.zoom, fit * 2, accuracy: 1e-9)
        let after = windowPoint(vc, Point(300, 400), Fixtures.page1)
        XCTAssertEqual(after.x, before.x, accuracy: 0.5)
        XCTAssertEqual(after.y, before.y, accuracy: 0.5)
        vc.host.zoomToggle(at: vc.host.viewPoint(Point(300, 400), page: Fixtures.page1))
        XCTAssertEqual(vc.zoom, fit, accuracy: 1e-9)
        // The Pencil never scrolls or zooms.
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        XCTAssertFalse(vc.scrollView.panGestureRecognizer.allowedTouchTypes.contains(pencil))
        XCTAssertFalse(vc.scrollView.pinchGestureRecognizer?.allowedTouchTypes.contains(pencil) ?? false)
    }

    // MARK: view.scrollBy

    func testScrollByMovesByPagePointsOrWindowFractions() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let z = vc.zoom
        let y0 = vc.scrollView.contentOffset.y
        let r = try await h.run("view.scrollBy", ["dx": 0, "dy": 200])
        XCTAssertEqual(vc.scrollView.contentOffset.y - y0, 200 * z, accuracy: 0.5)
        XCTAssertEqual(r["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG001")
        // The session's visible rect is the part of the page under the unobscured window, in page points.
        let visible = try XCTUnwrap(h.session.visibleRect)
        XCTAssertEqual(visible.y, 200, accuracy: 0.5)
        XCTAssertEqual(visible.x, 0, accuracy: 0.5)
        XCTAssertEqual(visible.width, PageSize.a4.width, accuracy: 0.5)
        XCTAssertEqual(r["visibleRect"]?.arrayValue?.count ?? r["visibleRect"]?.objectValue?.count, 4)

        let y1 = vc.scrollView.contentOffset.y
        _ = try await h.run("view.scrollBy", ["dx": 0, "dy": 0.5, "unit": "window"])
        XCTAssertEqual(vc.scrollView.contentOffset.y - y1, windowSize.height / 2, accuracy: 0.5)

        // Never past the ends.
        _ = try await h.run("view.scrollBy", ["dx": 0, "dy": -100_000])
        XCTAssertEqual(vc.scrollView.contentOffset.y, -vc.scrollView.adjustedContentInset.top, accuracy: 0.5)
        await assertThrows(.invalidParams) { _ = try await h.run("view.scrollBy", ["dx": 0]) }
    }

    // MARK: view.reveal

    func testRevealScrollsAnItemIntoViewAndFlashesIt() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        _ = try await h.run("view.goToPage", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.customID)
        let hit = h.app.content.hitBounds(for: item)
        let r = try await h.run("view.reveal", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECUS01"])
        XCTAssertEqual(r["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(try r["rect"]?.decode(Rect.self), hit)
        let t = try XCTUnwrap(vc.host.pageTransform(Fixtures.page1))
        let onScreen = hit.cg.applying(t)
        XCTAssertTrue(unobscured(vc).contains(onScreen), "the item is on screen")
        // The flash: an outlined wash just around the item, which takes no touches.
        let flash = vc.scrollView.subviews.first { $0.layer.borderWidth > 0 && $0.frame.contains(onScreen) }
        XCTAssertNotNil(flash)
        XCTAssertEqual(flash?.isUserInteractionEnabled, false)

        _ = try await h.run("view.reveal", ["ref": "page:FIXTUREDOC01/FIXTUREPG003"])
        XCTAssertEqual(h.session.page, Fixtures.pdfPage)
        _ = try await h.run("view.reveal", ["ref": "outline:FIXTUREDOC01/FIXTUREOUT01"])
        XCTAssertEqual(h.session.page, Fixtures.page1)
        await assertThrows(.invalidParams) { _ = try await h.run("view.reveal", ["ref": "nonsense"]) }
    }

    // MARK: Attachments

    func testAttachmentLifecycleFollowsTheCanvasAndTheRegistry() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let probe = ProbeAttachment()
        let boardOnly = ProbeAttachment()
        h.app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "test.probe", owner: "test", order: 10) { _ in probe })
        h.app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "test.boardOnly", owner: "test", order: 20,
                                                                       docKinds: [.whiteboard]) { _ in boardOnly })
        let vc = try makeCanvas(h)
        XCTAssertEqual(probe.attached, 1)
        XCTAssertTrue(probe.marker.superview === vc.scrollView, "its view lives in canvasView")
        XCTAssertEqual(boardOnly.attached, 0, "only for the kinds it asks for")
        XCTAssertEqual(vc.attachmentHost.entries.map { $0.id }, ["test.probe", DecorationAttachment.id])
        XCTAssertTrue(vc.host.attachments.first === probe)

        // canvasDidChange on zoom, scroll, selection.
        var before = probe.changes
        _ = try await h.run("view.zoom", ["scale": 2])
        XCTAssertGreaterThan(probe.changes, before)
        before = probe.changes
        _ = try await h.run("view.scrollBy", ["dx": 0, "dy": 50])
        XCTAssertGreaterThan(probe.changes, before)
        before = probe.changes
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID])
        await waitUntil("canvasDidChange on the selection change") { probe.changes > before }
        // … and on commits.
        before = probe.changes
        try await h.insert([Item(kind: .shape, shape: ShapeItem(shape: .ellipse, frame: Frame(x: 300, y: 300, w: 40, h: 40)))])
        await waitUntil("canvasDidChange on a commit") { probe.changes > before }

        // A feature or plugin registering late is attached; re-registering replaces it; unregistering detaches.
        let late = ProbeAttachment()
        h.app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "test.late", owner: "test", order: 1000) { _ in late })
        await waitUntil("the late attachment") { late.attached == 1 }
        XCTAssertEqual(vc.attachmentHost.entries.map { $0.id }, ["test.probe", DecorationAttachment.id, "test.late"])
        let replacement = ProbeAttachment()
        h.app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "test.late", owner: "test", order: 1000) { _ in replacement })
        await waitUntil("the replacement") { replacement.attached == 1 }
        XCTAssertEqual(late.detached, 1)
        h.app.ui.canvasAttachments.unregister(id: "test.late")
        await waitUntil("the detach") { replacement.detached == 1 }
        XCTAssertNil(vc.attachmentHost.attachment(id: "test.late"))

        // Closing detaches everything.
        vc.closeCanvas()
        XCTAssertTrue(vc.isClosed)
        XCTAssertEqual(probe.detached, 1)
        XCTAssertNil(probe.marker.superview)
        XCTAssertTrue(vc.attachmentHost.entries.isEmpty)
        XCTAssertNil(h.session.editor)
        before = probe.changes
        _ = try? await h.run("view.zoom", ["scale": 3])
        XCTAssertEqual(probe.changes, before, "a closed canvas tells nobody anything")
    }

    func testDocumentClosedEventClosesTheCanvas() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let probe = ProbeAttachment()
        h.app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "test.probe", owner: "test") { _ in probe })
        let vc = try makeCanvas(h)
        h.app.events.emit(NibEventType.docClosed, doc: Fixtures.docID)
        await waitUntil("the canvas to close") { vc.isClosed }
        XCTAssertEqual(probe.detached, 1)
    }

    // MARK: Decorations

    func testDecorationStoreExpiresReplacesAndScopesByOwner() {
        let store = DecorationStore()
        var clock = Date(timeIntervalSince1970: 1_000)
        store.now = { clock }
        var notified = 0
        let observation = store.observe { notified += 1 }
        let box = DisplayList(ops: [DisplayOp(op: .rect, rect: Rect(x: 0, y: 0, width: 10, height: 10), stroke: .black)])
        store.add(owner: "user", id: "hint", doc: Fixtures.docID, page: Fixtures.page1, display: box, ttl: 5)
        store.add(owner: "user", id: "hint", doc: Fixtures.docID, page: Fixtures.page1, display: box, ttl: 5)
        store.add(owner: "plugin:dev.test", id: "hint", doc: Fixtures.docID, page: Fixtures.page1, display: box, ttl: 20)
        XCTAssertEqual(notified, 3)
        XCTAssertEqual(store.decorations(doc: Fixtures.docID, page: Fixtures.page1).count, 2, "one per caller and id")
        XCTAssertEqual(store.pages(doc: Fixtures.docID), [Fixtures.page1])
        clock = clock.addingTimeInterval(6)
        XCTAssertEqual(store.decorations(doc: Fixtures.docID, page: Fixtures.page1).map { $0.key.owner }, ["plugin:dev.test"])
        XCTAssertEqual(store.purgeExpired(), 1)
        XCTAssertEqual(store.remove(owner: "someone else"), 0)
        XCTAssertEqual(store.remove(id: "hint", owner: "plugin:dev.test"), 1)
        XCTAssertEqual(store.liveCount, 0)
        // ttl is clamped to 0.05…3600 s.
        let d = store.add(owner: "user", id: "long", doc: Fixtures.docID, page: Fixtures.page2, display: box, ttl: 1_000_000)
        XCTAssertEqual(d.expiresAt.timeIntervalSince(clock), DecorationStore.maxTTL, accuracy: 1e-6)
        observation.cancel()
    }

    func testDecorationDisappearsWhenItsTTLRunsOut() async {
        let store = DecorationStore()
        var changes = 0
        let observation = store.observe { changes += 1 }
        store.add(owner: "user", id: "blink", doc: Fixtures.docID, page: Fixtures.page1, display: DisplayList(ops: []), ttl: 0.1)
        XCTAssertEqual(store.liveCount, 1)
        await waitUntil("the decoration to expire") { store.decorations.isEmpty }
        XCTAssertEqual(changes, 2, "added, then expired")
        observation.cancel()
    }

    func testDecorateCommandsDrawOnTheCanvasAndScopeClearingByCaller() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let store = DecorationStore.shared(h.app)
        let attachment = try XCTUnwrap(vc.attachmentHost.attachment(id: DecorationAttachment.id) as? DecorationAttachment)

        let r = try await h.run("canvas.decorate", CanvasDecorate.example)
        XCTAssertEqual(r["id"]?.stringValue, "hint")
        XCTAssertEqual(r["ttl"]?.doubleValue, 5)
        XCTAssertEqual(r["expiresAt"]?.doubleValue ?? 0, Date().timeIntervalSince1970 + 5, accuracy: 2)
        XCTAssertEqual(attachment.decoratedPages, [Fixtures.page1])

        // Another caller's decoration with the same id is its own; a page off screen gets no layer until shown.
        _ = try await h.run("canvas.decorate", CanvasDecorate.example, as: .ai("chat1"))
        var offscreen = CanvasDecorate.example
        if case .object(var o) = offscreen {
            o["page"] = "page:FIXTUREDOC01/FIXTUREPG003"
            o["id"] = "far"
            offscreen = .object(o)
        }
        _ = try await h.run("canvas.decorate", offscreen)
        XCTAssertEqual(store.decorations(doc: Fixtures.docID, page: Fixtures.page1).count, 2)
        XCTAssertEqual(attachment.decoratedPages, [Fixtures.page1])
        _ = try await h.run("view.goToPage", ["page": "page:FIXTUREDOC01/FIXTUREPG003"])
        XCTAssertTrue(attachment.decoratedPages.contains(Fixtures.pdfPage))

        // The AI clears only its own; the user clears anyone's.
        let ai = try await h.run("canvas.clearDecorations", [:], as: .ai("chat1"))
        XCTAssertEqual(ai["removed"]?.intValue, 1)
        XCTAssertEqual(store.decorations(doc: Fixtures.docID, page: Fixtures.page1).count, 1)
        let one = try await h.run("canvas.clearDecorations", ["id": "far"])
        XCTAssertEqual(one["removed"]?.intValue, 1)
        XCTAssertFalse(attachment.decoratedPages.contains(Fixtures.pdfPage))
        let all = try await h.run("canvas.clearDecorations", [:])
        XCTAssertEqual(all["removed"]?.intValue, 1)
        XCTAssertEqual(store.liveCount, 0)
        XCTAssertTrue(attachment.decoratedPages.isEmpty)

        // Validation.
        var badID = CanvasDecorate.example
        if case .object(var o) = badID {
            o["id"] = "no spaces!"
            badID = .object(o)
        }
        await assertThrows(.invalidParams) { _ = try await h.run("canvas.decorate", badID) }
        var missingPage = CanvasDecorate.example
        if case .object(var o) = missingPage {
            o["page"] = "page:FIXTUREDOC01/NOSUCHPAGE01"
            missingPage = .object(o)
        }
        await assertThrows(.notFound) { _ = try await h.run("canvas.decorate", missingPage) }
        var tooMany = CanvasDecorate.example
        if case .object(var o) = tooMany {
            let op: JSONValue = ["op": "rect", "rect": [0, 0, 1, 1]]
            o["display"] = ["ops": .array(Array(repeating: op, count: DecorationStore.maxOps + 1))]
            tooMany = .object(o)
        }
        await assertThrows(.invalidParams) { _ = try await h.run("canvas.decorate", tooMany) }
    }

    func testDecorationsThatWouldBeExpensiveToDrawAreRejected() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        try makeCanvas(h)
        func decorate(_ ops: [JSONValue]) -> JSONValue {
            ["page": "page:FIXTUREDOC01/FIXTUREPG001", "id": "big", "display": ["ops": .array(ops)]]
        }
        func rejects(_ ops: [JSONValue], at index: Int, line: UInt = #line) async {
            do {
                _ = try await h.run("canvas.decorate", decorate(ops))
                XCTFail("expected invalid_params", line: line)
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams, e.description, line: line)
                XCTAssertEqual(e.path, "$.display.ops[\(index)]", line: line)
                XCTAssertNotNil(e.hint, line: line)
            } catch {
                XCTFail("unexpected \(error)", line: line)
            }
        }
        let box: JSONValue = ["op": "rect", "rect": [0, 0, 10, 10], "stroke": "#000000FF"]
        // A million points square of dots one point apart: 10^12 dots.
        await rejects([box, ["op": "dots", "rect": [0, 0, 1_000_000, 1_000_000], "spacing": 1]], at: 1)
        await rejects([["op": "hlines", "rect": [0, 0, 100, 100_000], "spacing": 1, "stroke": "#000000FF"]], at: 0)
        let huge = (0...DecorationRules.maxPoints).map { i -> JSONValue in [.number(Double(i % 500)), .number(Double(i / 500))] }
        await rejects([box, box, ["op": "polyline", "points": .array(huge), "stroke": "#000000FF"]], at: 2)
        await rejects([["op": "rect", "rect": [0, 0, 1e9, 10], "stroke": "#000000FF"]], at: 0)
        await rejects([["op": "text", "rect": [0, 0, 100, 20],
                        "text": .string(String(repeating: "a", count: DecorationRules.maxTextLength + 1))]], at: 0)
        await rejects([["op": "line", "points": [[0, 0], [1_000_000, 0]], "stroke": "#000000FF", "dash": [0.01, 0.01]]],
                      at: 0)
        await rejects([["op": "dots", "rect": [0, 0, 100, 100], "spacing": 10, "radius": 5_000]], at: 0)
        XCTAssertEqual(DecorationStore.shared(h.app).liveCount, 0)
        // A page's worth of pattern is fine.
        _ = try await h.run("canvas.decorate", decorate([["op": "dots", "rect": [0, 0, 595, 842], "spacing": 24,
                                                          "radius": 1, "fill": "#000000FF"],
                                                         ["op": "hlines", "rect": [0, 0, 595, 842], "spacing": 24,
                                                          "stroke": "#000000FF", "dash": [6, 4]]]))
        XCTAssertEqual(DecorationStore.shared(h.app).liveCount, 1)
    }

    // MARK: Strokes and the render hooks (contracts-v2 G14)

    func testCommitStrokeWritesThroughInkAddStrokesThenRunsAfterNextRender() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        registerInkStandIn(h)
        let vc = try makeCanvas(h)
        var order: [String] = []
        var created: ElementID?
        let committed = expectation(description: "commit")
        let rendered = expectation(description: "render")
        vc.host.commitStroke(stroke(), page: Fixtures.page2) { result in
            if case .success(let id) = result { created = id }
            order.append("committed")
            committed.fulfill()
        }
        vc.host.afterNextRender(page: Fixtures.page2) {
            order.append("rendered")
            rendered.fulfill()
        }
        await fulfillment(of: [committed, rendered], timeout: 5)
        XCTAssertEqual(order, ["committed", "rendered"])
        let id = try XCTUnwrap(created)
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(items.map { $0.id }, [id])
        XCTAssertEqual(items.first?.kind, .stroke)

        // With nothing pending the body still runs, on a later turn.
        var ran = false
        vc.host.afterNextRender(page: Fixtures.page1) { ran = true }
        XCTAssertFalse(ran)
        await waitUntil("afterNextRender with nothing pending") { ran }
    }

    func testStrokeProcessorsRunFirstAndCanDropTheStroke() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        registerInkStandIn(h)
        let vc = try makeCanvas(h)
        let shift = ShiftProcessor()
        h.app.content.strokeProcessors.register(StrokeProcessorEntry(id: "test.shift", order: 1, owner: "test", processor: shift))
        let shifted = expectation(description: "shifted")
        vc.host.commitStroke(stroke(y: 200), page: Fixtures.page2) { _ in shifted.fulfill() }
        await fulfillment(of: [shifted], timeout: 5)
        let written = try XCTUnwrap(h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).first?.stroke)
        XCTAssertEqual(written.points.first?.y, 210, "the processor's change was committed")
        XCTAssertEqual(shift.pages, [Fixtures.page2])

        h.app.content.strokeProcessors.register(StrokeProcessorEntry(id: "test.drop", order: 2, owner: "test", processor: DropProcessor()))
        var outcome: Result<ElementID?, NibError>?
        let dropped = expectation(description: "dropped")
        vc.host.commitStroke(stroke(), page: Fixtures.page2) { result in
            outcome = result
            dropped.fulfill()
        }
        await fulfillment(of: [dropped], timeout: 5)
        if case .success(let id)? = outcome { XCTAssertNil(id) } else { XCTFail("a dropped stroke succeeds with nil") }
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).count, 1)
    }

    func testReadOnlyRefusesStrokes() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        registerInkStandIn(h)
        let vc = try makeCanvas(h)
        h.session.readOnly = true
        XCTAssertFalse(vc.host.isInkEnabled)
        var outcome: Result<ElementID?, NibError>?
        vc.host.commitStroke(stroke(), page: Fixtures.page2) { outcome = $0 }
        guard case .failure(let e)? = outcome else { return XCTFail("expected a failure") }
        XCTAssertEqual(e.code, .permissionDenied)
        XCTAssertTrue(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).isEmpty)
    }

    func testFailingCommitReportsTheError() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        // No ink feature: ink.addStrokes does not exist.
        var outcome: Result<ElementID?, NibError>?
        let done = expectation(description: "done")
        vc.host.commitStroke(stroke(), page: Fixtures.page2) { result in
            outcome = result
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        guard case .failure? = outcome else { return XCTFail("expected a failure") }
    }

    func testFinishToolUseReturnsFromANonStickyToolAndToolsAreActivated() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let tool = ProbeTool()
        h.app.ui.canvasTools.register(CanvasToolDescriptor(id: ProbeTool.toolID, title: "Probe", owner: "test") { tool })
        let vc = try makeCanvas(h)
        XCTAssertEqual(h.session.tool, "pen")
        XCTAssertNil(vc.host.activeTool, "no pen tool is registered in this test")
        h.session.tool = ProbeTool.toolID
        await waitUntil("the probe tool to activate") { tool.activations == 1 }
        XCTAssertTrue(vc.host.activeTool === tool)
        vc.host.finishToolUse(tool)
        XCTAssertEqual(h.session.tool, "pen", "a non-sticky tool returns to the previous tool")
        await waitUntil("the probe tool to deactivate") { tool.deactivations == 1 }
        XCTAssertNil(vc.host.activeTool)
    }

    func testInkingSignalIsInWindowCoordinates() throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let r = Rect(x: 50, y: 60, width: 30, height: 10)
        vc.host.beginInking(page: Fixtures.page1, strokeBounds: r)
        XCTAssertTrue(h.session.inking.isInking)
        let t = try XCTUnwrap(vc.host.pageTransform(Fixtures.page1))
        let expected = r.cg.applying(t)
        let bounds = try XCTUnwrap(h.session.inking.strokeBounds)
        XCTAssertEqual(bounds.minX, expected.minX, accuracy: 1e-6)
        XCTAssertEqual(bounds.width, expected.width, accuracy: 1e-6)
        vc.host.updateInking(page: Fixtures.page1, strokeBounds: Rect(x: 50, y: 60, width: 80, height: 10))
        XCTAssertEqual(h.session.inking.strokeBounds?.width ?? 0, 80 * vc.zoom, accuracy: 1e-6)
        vc.host.endInking()
        XCTAssertFalse(h.session.inking.isInking)
        XCTAssertNil(h.session.inking.strokeBounds)
    }

    // MARK: Tiles

    func testTilesAreRequestedOnTheRenderersGridAtTheZoomLevel() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let renderer = RecordingRenderer()
        h.app.services.renderer = renderer
        let vc = try makeCanvas(h)
        let level = CanvasTileGrid.level(for: vc.zoom * Double(vc.scrollView.screenScale))
        let scale = CanvasTileGrid.scale(level: level)
        await waitUntil("page 1 tiles") {
            renderer.requests.contains { $0.page == Fixtures.page1 && $0.region != nil && $0.scale == scale }
        }
        for r in renderer.requests {
            XCTAssertEqual(r.doc, Fixtures.docID)
            XCTAssertEqual(r.purpose, .screen)
            XCTAssertEqual(r.layers, Set(0..<NibLimits.layerCount))
            XCTAssertTrue(r.background)
            XCTAssertTrue(r.hidden.isEmpty)
            guard let region = r.region else { continue }
            // Exactly one grid tile at its bucket scale: the request the renderer answers from its tile cache.
            let side = 512 / r.scale
            XCTAssertEqual(region.width, side, accuracy: 1e-9)
            XCTAssertEqual(region.height, side, accuracy: 1e-9)
            XCTAssertEqual(region.x / side, (region.x / side).rounded(), accuracy: 1e-9)
            XCTAssertEqual(region.y / side, (region.y / side).rounded(), accuracy: 1e-9)
        }
        // A whole-page preview at the preview level.
        let previewScale = CanvasTileGrid.scale(level: CanvasTileGrid.previewLevel(pageSize: .a4))
        XCTAssertTrue(renderer.requests.contains { $0.page == Fixtures.page1 && $0.region == nil && $0.scale == previewScale })
        // The visible part of page 1 is covered.
        let v = vc.scrollView.visibleLayoutRect
        let origin = try XCTUnwrap(vc.scrollView.layoutOrigin(Fixtures.page1))
        let tiles = renderer.requests.filter { $0.page == Fixtures.page1 && $0.scale == scale }.compactMap { $0.region }
        let x0 = max(v.minX - origin.x, 0) + 1, y0 = max(v.minY - origin.y, 0) + 1
        let x1 = min(v.maxX - origin.x, PageSize.a4.width) - 1, y1 = min(v.maxY - origin.y, PageSize.a4.height) - 1
        for corner in [Point(x0, y0), Point(x1, y0), Point(x0, y1), Point(x1, y1)] {
            XCTAssertTrue(tiles.contains { $0.contains(corner) }, "no tile covers \(corner)")
        }
        await waitUntil("page 1 to settle") { vc.scrollView.pageViews[Fixtures.page1]?.isSettled ?? false }
        XCTAssertTrue(vc.scrollView.pageViews[Fixtures.page1]?.hasPreview ?? false)
        // The page's content came in with its first bitmap (DESIGN.md §14.18); the paper was there all along.
        XCTAssertEqual(vc.scrollView.pageViews[Fixtures.page1]?.hasShownContent, true)
        XCTAssertEqual(vc.scrollView.pageViews[Fixtures.page1]?.contentAlpha, 1)

        // Zooming in re-bakes at the new level when the zoom ends.
        _ = try await h.run("view.zoom", ["scale": 4])
        let newScale = CanvasTileGrid.scale(level: CanvasTileGrid.level(for: 4 * Double(vc.scrollView.screenScale)))
        XCTAssertGreaterThan(newScale, scale)
        await waitUntil("tiles at the new level") { renderer.requests.contains { $0.region != nil && $0.scale == newScale } }
    }

    func testHiddenLayersAndHiddenItemsRedrawTheTiles() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let renderer = RecordingRenderer()
        h.app.services.renderer = renderer
        let vc = try makeCanvas(h)
        await waitUntil("first tiles") { renderer.requests.contains { $0.region != nil } }

        // G3: this window hides layer 1.
        h.session.hiddenLayers = [1]
        await waitUntil("tiles without layer 1") {
            renderer.requests.contains { $0.region != nil && $0.layers == Set(0..<NibLimits.layerCount).subtracting([1]) }
        }
        XCTAssertEqual(vc.host.visibleLayers, [0, 2, 3, 4])

        await waitUntil("every page to settle") { vc.scrollView.pageViews.values.allSatisfy { $0.isSettled } }

        // setHidden (a drag preview) redraws only the tiles under the item, without it.
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        let dirty = h.app.content.paintBounds(for: item)
        let count = renderer.requests.count
        vc.host.setHidden([Fixtures.strokeID], page: Fixtures.page1)
        XCTAssertEqual(vc.host.hiddenItems[Fixtures.page1], [Fixtures.strokeID])
        await waitUntil("tiles without the stroke") {
            renderer.requests.dropFirst(count).contains { $0.hidden == [Fixtures.strokeID] }
        }
        for r in renderer.requests.dropFirst(count) where r.region != nil {
            XCTAssertTrue(r.region?.intersects(dirty) ?? false, "only tiles under the item are redrawn")
        }
        vc.host.setHidden([], page: Fixtures.page1)
        XCTAssertNil(vc.host.hiddenItems[Fixtures.page1])
    }

    func testCommitsInvalidateThePaintedArea() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let renderer = RecordingRenderer()
        h.app.services.renderer = renderer
        let vc = try makeCanvas(h)
        await waitUntil("first tiles") { renderer.requests.contains { $0.region != nil } }
        await waitUntil("page 1 to settle") { vc.scrollView.pageViews[Fixtures.page1]?.isSettled ?? false }
        let item = Item(kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 300, y: 300, w: 50, h: 50)))
        let count = renderer.requests.count
        let written = try await h.insert([item], page: Fixtures.page1)
        let painted = h.app.content.paintBounds(for: try XCTUnwrap(written.first))
        await waitUntil("the renderer's cache invalidated") {
            renderer.invalidations.contains { $0.page == Fixtures.page1 && ($0.rect?.contains(painted) ?? true) }
        }
        await waitUntil("the tiles under the shape redrawn") {
            renderer.requests.dropFirst(count).contains { $0.region?.intersects(painted) ?? false }
        }
    }

    func testANewBackgroundRedrawsThePageInPlaceWithoutAScroll() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let renderer = RecordingRenderer()
        h.app.services.renderer = renderer
        // template.apply / page.setBackground stand-in: a new background, same size.
        h.app.commands.register(CommandDescriptor(id: "test.setBackground", title: "Set Background",
                                                  summary: "Test helper.", effect: .edit)) { _, ctx in
            try ctx.mutate { tx in
                guard var page = try tx.content(Fixtures.docID).page(Fixtures.page1) else {
                    throw NibError.notFound("page")
                }
                page.background = .ofColor(RGBA(255, 244, 214))
                _ = try tx.put(page, doc: Fixtures.docID)
            }
            return .null
        }
        let vc = try makeCanvas(h)
        await waitUntil("page 1 to settle") {
            guard let v = vc.scrollView.pageViews[Fixtures.page1] else { return false }
            return v.isSettled && v.contentAlpha == 1 && v.hasPreview
        }
        let view = try XCTUnwrap(vc.scrollView.pageViews[Fixtures.page1])
        let keys = view.tileKeys
        XCTAssertFalse(keys.isEmpty)
        let count = renderer.requests.count

        _ = try await h.run("test.setBackground")
        XCTAssertTrue(vc.scrollView.pageViews[Fixtures.page1] === view)
        XCTAssertEqual(view.tileKeys, keys, "the tiles stay, to be redrawn in place")
        XCTAssertEqual(view.contentAlpha, 1, "the page never blanks")
        XCTAssertTrue(renderer.invalidations.contains { $0.page == Fixtures.page1 && $0.rect == nil })
        await waitUntil("page 1 redrawn with its new background") {
            renderer.requests.dropFirst(count).contains { $0.page == Fixtures.page1 && $0.region != nil }
        }
        await waitUntil("page 1 to settle again") { view.isSettled }
        XCTAssertFalse(view.tileKeys.isEmpty)
        XCTAssertEqual(view.contentAlpha, 1)
        XCTAssertTrue(view.hasPreview)
        XCTAssertEqual(view.record?.background, .ofColor(RGBA(255, 244, 214)))
    }

    func testALayerHiddenBeforeTheCanvasOpensComesBackWhenShown() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let renderer = RecordingRenderer()
        h.app.services.renderer = renderer
        // The window's layer visibility was restored before its editor was made.
        h.session.hiddenLayers = [1]
        let vc = try makeCanvas(h)
        let all = Set(0..<NibLimits.layerCount)
        await waitUntil("tiles without layer 1") {
            renderer.requests.contains { $0.region != nil && $0.layers == all.subtracting([1]) }
        }
        await waitUntil("every page to settle") { vc.scrollView.pageViews.values.allSatisfy { $0.isSettled } }
        let count = renderer.requests.count
        h.session.hiddenLayers = []
        await waitUntil("tiles with every layer") {
            renderer.requests.dropFirst(count).contains { $0.region != nil && $0.layers == all }
        }
    }

    func testDirtyRectsUnionBeforeAndAfterPaintBounds() {
        let h = Harness(features: [FeatCanvasFeature.self])
        let a = Item(kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 10, h: 10)))
        var b = a
        b.shape?.frame = Frame(x: 100, y: 100, w: 10, h: 10)
        let cs = Changeset(seq: 1, principal: .user, group: "g", label: "Move", command: "test.move",
                           mutations: [.item(Fixtures.docID, Fixtures.page1, before: a, after: b),
                                       .item(Fixtures.docID, Fixtures.page2, before: nil, after: a),
                                       .item(Fixtures.whiteboardID, Fixtures.boardID, before: nil, after: b)])
        let dirty = CanvasViewController.dirtyRects(cs, doc: Fixtures.docID, content: h.app.content)
        XCTAssertEqual(Set(dirty.keys), [Fixtures.page1, Fixtures.page2])
        XCTAssertEqual(dirty[Fixtures.page1], h.app.content.paintBounds(for: a).union(h.app.content.paintBounds(for: b)))
        XCTAssertEqual(dirty[Fixtures.page2], h.app.content.paintBounds(for: a))
    }

    // MARK: Live views

    func testLiveViewsSitOverTheirItemAndHideWithIt() throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let live = UIView()
        vc.host.attachLiveView(live, item: Fixtures.imageID, page: Fixtures.page1)
        let pageView = try XCTUnwrap(vc.scrollView.pageViews[Fixtures.page1])
        XCTAssertTrue(live.superview === pageView.liveViewContainer)
        XCTAssertEqual(live.center.x, 352, accuracy: 1e-9)
        XCTAssertEqual(live.center.y, 512, accuracy: 1e-9)
        XCTAssertEqual(live.bounds.size, CGSize(width: 64, height: 64))
        vc.host.setHidden([Fixtures.imageID], page: Fixtures.page1)
        XCTAssertTrue(live.isHidden)
        vc.host.setHidden([], page: Fixtures.page1)
        XCTAssertFalse(live.isHidden)
        vc.host.attachLiveView(nil, item: Fixtures.imageID, page: Fixtures.page1)
        XCTAssertNil(live.superview)
        XCTAssertEqual(vc.host.liveViewCount, 0)
    }

    // MARK: Whiteboard

    /// Pixel coverage inside the viewport catches a world-origin error that tile-key and minimap checks cannot.
    private func boardSnapshot(_ vc: CanvasViewController) -> UIImage {
        vc.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: vc.view.bounds.size, format: format).image { context in
            vc.view.layer.render(in: context.cgContext)
        }
    }

    private func boardPixel(_ image: UIImage, at point: Point, canvas vc: CanvasViewController,
                            file: StaticString = #filePath, line: UInt = #line) throws -> RGBA {
        let position = vc.scrollView.convert(vc.host.viewPoint(point, page: Fixtures.boardID), to: vc.view)
        XCTAssertTrue(vc.view.bounds.contains(position), "sample must be inside the viewport", file: file, line: line)
        return try XCTUnwrap(NibSnapshot.pixel(image, at: position), file: file, line: line)
    }

    func testWhiteboardViewportSnapshotShowsItemsAndDotsBeforeTilesArrive() throws {
        for size in [windowSize, CGSize(width: 390, height: 844)] {
            let h = Harness(features: [FeatCanvasFeature.self])
            let vc = try makeCanvas(h, doc: Fixtures.whiteboardID, size: size)
            defer { vc.closeCanvas() }
            let view = try XCTUnwrap(vc.scrollView.pageViews[Fixtures.boardID])
            XCTAssertEqual(vc.zoom, 1, accuracy: 1e-9)
            XCTAssertFalse(view.tileKeys.isEmpty, "opening at unchanged 100 % must request visible tiles")
            XCTAssertFalse(view.hasShownContent, "this snapshot precedes the first asynchronous render")
            let image = boardSnapshot(vc)
            let paper = try boardPixel(image, at: Point(235, 175), canvas: vc)
            let item = try boardPixel(image, at: Point(105, 65), canvas: vc)
            let dot = try boardPixel(image, at: Point(240, 180), canvas: vc)
            XCTAssertNotEqual(item, paper, "a pending board must show the item sketch, never empty paper")
            XCTAssertNotEqual(dot, paper, "the dot grid must be visible before tiles arrive")
        }
    }

    func testWhiteboardViewportSnapshotShowsRenderedItemsAfterZoomAndWorldGrowth() async throws {
        for size in [windowSize, CGSize(width: 390, height: 844)] {
            let h = Harness(features: [FeatCanvasFeature.self])
            h.app.services.renderer = BoardSnapshotRenderer()
            let vc = try makeCanvas(h, doc: Fixtures.whiteboardID, size: size)
            defer { vc.closeCanvas() }
            func assertRenderedItem() async throws {
                let view = try XCTUnwrap(vc.scrollView.pageViews[Fixtures.boardID])
                await waitUntil("whiteboard tiles") { view.isSettled && view.hasShownContent }
                let pixel = try boardPixel(boardSnapshot(vc), at: Point(105, 65), canvas: vc)
                XCTAssertGreaterThan(Int(pixel.g), Int(pixel.r) + 40, "the rendered item must occupy the viewport")
            }
            try await assertRenderedItem()
            _ = try await h.run("view.zoom", ["scale": 0.5])
            try await assertRenderedItem()
            _ = try await h.run("view.zoom", ["actual": true])
            try await assertRenderedItem()
            let world = try XCTUnwrap(vc.board).rect
            _ = try await h.run("view.scrollBy", ["dx": -70_000, "dy": 0])
            XCTAssertLessThan(try XCTUnwrap(vc.board).rect.minX, world.minX)
            _ = try await h.run("view.zoom", ["fit": true])
            try await assertRenderedItem()
        }
    }

    func testWhiteboardIsOneInfiniteWorldWithBoardZoomLimits() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h, doc: Fixtures.whiteboardID)
        XCTAssertEqual(vc.mode, .world(Fixtures.boardID))
        XCTAssertEqual(vc.scrollView.pages, [Fixtures.boardID])
        XCTAssertEqual(vc.zoomLimits, ZoomRules.boardRange)
        XCTAssertEqual(vc.zoom, 1, accuracy: 1e-9, "a board opens at 100 %")
        XCTAssertFalse(vc.scrollView.showsVerticalScrollIndicator, "an infinite board has no extent to indicate")
        // DESIGN.md §14.17: the page HUD shows the zoom instead of a page number.
        XCTAssertTrue(vc.hud.showsPageHUD)
        XCTAssertTrue(vc.hud.isBoard)
        XCTAssertEqual(vc.hud.primaryText, vc.hud.zoomText)
        XCTAssertNil(vc.hud.secondaryText)
        XCTAssertEqual(vc.hud.accessibilityLabel, "Zoom")

        // The content is centred in the window.
        let shape = try h.app.workspace.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: Fixtures.boardShapeID)
        let content = try XCTUnwrap(vc.currentBoardContent())
        XCTAssertEqual(content, h.app.content.paintBounds(for: shape))
        let c = windowPoint(vc, content.center, Fixtures.boardID)
        XCTAssertEqual(c.x, windowSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(c.y, windowSize.height / 2, accuracy: 0.5)
        XCTAssertTrue(try XCTUnwrap(vc.board).rect.contains(content))

        // World coordinates go negative.
        let far = Point(-2500, -1800)
        let back = try XCTUnwrap(vc.host.pagePoint(vc.host.viewPoint(far, page: Fixtures.boardID)))
        XCTAssertEqual(back.page, Fixtures.boardID)
        XCTAssertEqual(back.point.x, far.x, accuracy: 1e-6)
        XCTAssertEqual(back.point.y, far.y, accuracy: 1e-6)

        // Fit shows all of the content (at most 400 %), still centred.
        let fit = try await h.run("view.zoom", ["fit": true])
        let expected = ZoomRules.boardFit(content: content, viewport: vc.scrollView.bounds.size)
        XCTAssertEqual(fit["scale"]?.doubleValue ?? 0, expected, accuracy: 1e-9)
        XCTAssertEqual(fit["min"]?.doubleValue, 0.05)
        XCTAssertEqual(fit["max"]?.doubleValue, 4)
        let c2 = windowPoint(vc, content.center, Fixtures.boardID)
        XCTAssertEqual(c2.x, windowSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(c2.y, windowSize.height / 2, accuracy: 0.5)

        // 5–400 %.
        _ = try await h.run("view.zoom", ["scale": 0.01])
        XCTAssertEqual(vc.zoom, 0.05, accuracy: 1e-9)
        _ = try await h.run("view.zoom", ["scale": 9])
        XCTAssertEqual(vc.zoom, 4, accuracy: 1e-9)
    }

    func testBoardWorldGrowsAheadOfTheWindowAndKeepsThePointUnderIt() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h, doc: Fixtures.whiteboardID)
        let world = try XCTUnwrap(vc.board).rect
        func centre() throws -> Point {
            let b = vc.scrollView.bounds
            return try XCTUnwrap(vc.host.pagePoint(CGPoint(x: b.midX, y: b.midY))).point
        }
        let start = try centre()
        _ = try await h.run("view.scrollBy", ["dx": -70_000, "dy": 0])
        let grown = try XCTUnwrap(vc.board).rect
        XCTAssertLessThan(grown.minX, world.minX, "the world grew to the left")
        let now = try centre()
        XCTAssertEqual(now.x, start.x - 70_000, accuracy: 1)
        XCTAssertEqual(now.y, start.y, accuracy: 1)
        // Page coordinates are still world coordinates after the growth.
        let back = try XCTUnwrap(vc.host.pagePoint(vc.host.viewPoint(Point(-69_000, 40), page: Fixtures.boardID)))
        XCTAssertEqual(back.point.x, -69_000, accuracy: 1e-6)
        XCTAssertEqual(back.point.y, 40, accuracy: 1e-6)

        // A pan longer than the world (the minimap, the assistant) grows it first, so it lands where it was asked.
        _ = try await h.run("view.scrollBy", ["dx": 0, "dy": 300_000])
        let far = try centre()
        XCTAssertEqual(far.x, now.x, accuracy: 1)
        XCTAssertEqual(far.y, now.y + 300_000, accuracy: 1)
        // …up to the board's reach.
        _ = try await h.run("view.scrollBy", ["dx": 0, "dy": 5_000_000])
        XCTAssertLessThanOrEqual(try XCTUnwrap(vc.board).rect.maxY, BoardWorld.reach + 1e-6)
        XCTAssertLessThanOrEqual(try centre().y, BoardWorld.reach)
    }

    // MARK: Horizontal paging

    func testHorizontalPagingShowsOnePageAtATimeAndSnapsToNeighbours() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        h.app.commands.register(CommandDescriptor(id: "test.pageHorizontally", title: "Page Horizontally",
                                                  summary: "Test helper.", effect: .edit)) { _, ctx in
            try ctx.mutate { tx in
                var meta = try tx.content(Fixtures.docID).meta
                meta.scrollDirection = .horizontal
                try tx.putMeta(meta)
            }
            return .null
        }
        _ = try await h.run("test.pageHorizontally")
        let vc = try makeCanvas(h)
        let sv = vc.scrollView
        XCTAssertEqual(vc.mode, .stack(.horizontal))
        XCTAssertEqual(sv.decelerationRate, .fast)

        // At fit one whole page fills the window, centred; its neighbour is off screen.
        let f1 = try XCTUnwrap(vc.host.pageFrame(Fixtures.page1))
        let f2 = try XCTUnwrap(vc.host.pageFrame(Fixtures.page2))
        XCTAssertEqual(f1.midX - sv.bounds.minX, windowSize.width / 2, accuracy: 0.5)
        XCTAssertLessThanOrEqual(f1.height, windowSize.height - sv.chromeInsets.top - sv.chromeInsets.bottom + 0.5)
        XCTAssertGreaterThanOrEqual(f2.minX - sv.bounds.minX, windowSize.width - 0.5)

        // ⌥→ turns the page.
        _ = try await h.run("view.scrollBy", ["dx": 0.9, "dy": 0, "unit": "window"])
        XCTAssertEqual(h.session.page, Fixtures.page2)
        let g2 = try XCTUnwrap(vc.host.pageFrame(Fixtures.page2))
        XCTAssertEqual(g2.midX - sv.bounds.minX, windowSize.width / 2, accuracy: 0.5)

        // A flick moves one page, a slow drag settles back, a flick back goes back.
        func settle(velocity: CGFloat, shift: CGFloat) -> CGFloat {
            vc.scrollViewWillBeginDragging(sv)
            var target = CGPoint(x: sv.contentOffset.x + shift, y: sv.contentOffset.y)
            withUnsafeMutablePointer(to: &target) { p in
                vc.scrollViewWillEndDragging(sv, withVelocity: CGPoint(x: velocity, y: 0), targetContentOffset: p)
            }
            vc.scrollViewDidEndDragging(sv, willDecelerate: false)
            return target.x
        }
        func centred(_ i: Int) -> CGFloat {
            let s = sv.layout.slot(i)
            return sv.viewRect(layout: Rect(x: s.start, y: 0, width: s.end - s.start, height: 1)).midX - windowSize.width / 2
        }
        XCTAssertEqual(settle(velocity: 2, shift: 40), centred(2), accuracy: 0.5)
        XCTAssertEqual(settle(velocity: 0, shift: 100), sv.contentOffset.x, accuracy: 0.5)
        XCTAssertEqual(settle(velocity: -2, shift: -40), centred(0), accuracy: 0.5)
    }

    // MARK: Accessibility

    func testPagesListTheirReadableItemsForVoiceOver() throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let pageView = try XCTUnwrap(vc.scrollView.pageViews[Fixtures.page1])
        let elements = try XCTUnwrap(pageView.accessibilityElements)
        let labels = elements.compactMap { ($0 as? UIAccessibilityElement)?.accessibilityLabel }
        XCTAssertEqual(labels, ["Page 1 of 3", "Text", "Sticky note", "Comment", "Maths", "Image"])
        let comment = try XCTUnwrap(elements.compactMap { $0 as? CanvasItemElement }.first { $0.accessibilityLabel == "Comment" })
        XCTAssertEqual(comment.accessibilityValue, "Fixture: Check this")
        XCTAssertTrue(comment.accessibilityTraits.contains(.button))
        let pin = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.commentID)
        XCTAssertEqual(comment.accessibilityFrameInContainerSpace, h.app.content.hitBounds(for: pin).cg)
        // A hidden layer's items are not read.
        h.session.hiddenLayers = Set(0..<NibLimits.layerCount)
        pageView.invalidateAccessibility()
        XCTAssertEqual(pageView.accessibilityElements?.count, 1)
    }

    func testLinksAreVoiceOverElementsThatFollowTheLink() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        var followed: [JSONValue] = []
        h.app.commands.register(CommandDescriptor(id: "link.follow", title: "Follow Link", summary: "Test stand-in.",
                                                  params: .obj(["url": .str()]), effect: .session)) { params, _ in
            followed.append(params)
            return .null
        }
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("Read "),
                                                          TextRun("the docs", TextAttributes(link: TextLink(url: "https://example.com")))])])
        try await h.insert([Item(kind: .text, text: TextBoxItem(frame: Frame(x: 72, y: 72, w: 300, h: 40), text: text))],
                           page: Fixtures.page2)
        let vc = try makeCanvas(h)
        let pageView = try XCTUnwrap(vc.scrollView.pageViews[Fixtures.page2])
        let elements = (pageView.accessibilityElements ?? []).compactMap { $0 as? CanvasItemElement }
        XCTAssertEqual(elements.first?.accessibilityValue, "Read the docs")
        let link = try XCTUnwrap(elements.first { $0.accessibilityTraits.contains(.link) })
        XCTAssertEqual(link.accessibilityLabel, "the docs")
        XCTAssertTrue(link.accessibilityActivate())
        await waitUntil("link.follow") { !followed.isEmpty }
        XCTAssertEqual(followed.first?["url"]?.stringValue, "https://example.com")
    }

    func testLinkRunsAndFollowParams() {
        let url = TextLink(url: "https://nib.app")
        let page = TextLink(document: "OTHERDOC0001", page: "OTHERPAGE001")
        let audio = TextLink(document: "OTHERDOC0001", audioClip: "OTHERCLIP001", audioTime: 12.5)
        let text = RichText(paragraphs: [
            Paragraph(runs: [TextRun("See "), TextRun("the ", TextAttributes(link: url)), TextRun("site", TextAttributes(bold: true, link: url))]),
            Paragraph(runs: [TextRun("page two", TextAttributes(link: page)), TextRun(" "), TextRun("at 0:12", TextAttributes(link: audio))])
        ])
        let runs = CanvasAccessibility.links(in: text)
        XCTAssertEqual(runs.map { $0.0 }, ["the site", "page two", "at 0:12"])
        XCTAssertEqual(CanvasAccessibility.followParams(url), ["url": "https://nib.app"])
        XCTAssertEqual(CanvasAccessibility.followParams(page), ["doc": "doc:OTHERDOC0001", "page": "page:OTHERDOC0001/OTHERPAGE001"])
        XCTAssertEqual(CanvasAccessibility.followParams(audio), ["clip": "audio:OTHERDOC0001/OTHERCLIP001", "t": 12.5])
        XCTAssertNil(CanvasAccessibility.followParams(TextLink()))
    }

    // MARK: HUD

    func testPageAndZoomHUDs() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let ctx = ChromeContext(app: h.app, session: h.session, kind: .notebook)
        let pageHUD = try XCTUnwrap(h.app.ui.chromeOverlays.get(CanvasChrome.pageHUD))
        let zoomHUD = try XCTUnwrap(h.app.ui.chromeOverlays.get(CanvasChrome.zoomHUD))
        XCTAssertTrue(pageHUD.isVisible(ctx))
        XCTAssertFalse(zoomHUD.isVisible(ctx), "the zoom HUD shows only while pinching")
        vc.hud.setPinching(true)
        XCTAssertTrue(zoomHUD.isVisible(ctx))
        vc.hud.setPinching(false)

        // Scrubbing the HUD goes through view.goToPage.
        vc.hud.go(to: 2)
        await waitUntil("page 3") { vc.hud.pageIndex == 2 }
        XCTAssertEqual(h.session.page, Fixtures.pdfPage)
        XCTAssertEqual(vc.hud.primaryText, "3")
        vc.hud.step(forward: false)
        await waitUntil("page 2") { vc.hud.pageIndex == 1 }

        // On iPhone the page HUD steps aside while scrolling.
        vc.hud.setScrolling(true, compact: true)
        XCTAssertFalse(vc.hud.showsPageHUD)
        vc.hud.setScrolling(false, compact: true)
        XCTAssertTrue(vc.hud.showsPageHUD)
        vc.hud.setScrolling(true, compact: false)
        XCTAssertTrue(vc.hud.showsPageHUD)

        vc.closeCanvas()
        XCTAssertFalse(pageHUD.isVisible(ctx), "no HUD without an open canvas")
    }

    // MARK: Input half seam

    func testInputHalfHearsAboutChangesAndAnyInputModePansWithTwoFingers() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let probe = ProbeInput()
        let vc = try makeCanvas(h, input: { host in host.inputController = probe })
        XCTAssertTrue(vc.host.inputController === probe)
        XCTAssertTrue(vc.host.wetInkContainer.superview === vc.scrollView)
        let pan = vc.scrollView.panGestureRecognizer
        XCTAssertEqual(pan.minimumNumberOfTouches, 1)

        let changes = probe.changes, zoomEnds = probe.zoomEnds, pages = probe.pageChanges
        _ = try await h.run("view.zoom", ["scale": 2])
        XCTAssertGreaterThan(probe.changes, changes)
        XCTAssertEqual(probe.zoomEnds, zoomEnds + 1)
        _ = try await h.run("view.goToPage", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertGreaterThan(probe.pageChanges, pages)

        // "Disconnect Apple Pencil": fingers draw, two fingers pan.
        h.app.settings.set(NibSettings.stylusMode, .anyInput)
        await waitUntil("two-finger panning") { pan.minimumNumberOfTouches == 2 }
        // Read-only always pans with one finger and disables ink.
        h.session.readOnly = true
        await waitUntil("the read-only change") { probe.readOnlyChanges == 1 }
        XCTAssertEqual(pan.minimumNumberOfTouches, 1)
        XCTAssertFalse(vc.host.isInkEnabled)

        vc.host.cancelWetStroke()
        XCTAssertEqual(probe.cancels, 1)
        vc.closeCanvas()
        XCTAssertEqual(probe.closes, 1)
        XCTAssertNil(vc.host.inputController)
    }

    // MARK: The current page

    func testTheRequestedPageStaysCurrentWhileItShowsUntilTheUserScrolls() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        _ = try await h.run("view.zoom", ["scale": 0.5])
        _ = try await h.run("view.goToPage", ["index": -1])
        // Zoomed out, the last page cannot scroll up to the bars and page 2 holds the middle of the window; the page
        // asked for is still the current page (D-064, D-125).
        let sv = vc.scrollView
        let middle = CGPoint(x: sv.bounds.midX, y: unobscured(vc).midY)
        XCTAssertEqual(vc.host.pagePoint(middle)?.page, Fixtures.page2)
        XCTAssertEqual(h.session.page, Fixtures.pdfPage)
        XCTAssertEqual(vc.displayedPage, Fixtures.pdfPage)
        XCTAssertEqual(vc.hud.pageIndex, 2)
        XCTAssertEqual(vc.hud.primaryText, "3")

        // The user takes over: the page in the middle of the window is current again.
        vc.scrollViewWillBeginDragging(sv)
        sv.contentOffset = CGPoint(x: sv.contentOffset.x, y: sv.contentOffset.y - 1)
        vc.scrollViewDidEndDragging(sv, willDecelerate: false)
        XCTAssertEqual(vc.displayedPage, Fixtures.page2)
        XCTAssertEqual(h.session.page, Fixtures.page2)
        XCTAssertEqual(vc.hud.pageIndex, 1)
    }

    // MARK: Adding pages (D-053)

    /// A stand-in for F022's `page.add` at the end of a document, honouring the caller's `id`.
    private func registerPageAddStandIn(_ h: Harness) {
        h.app.commands.register(CommandDescriptor(
            id: CommandIDs.pageAdd, title: "Add Page", summary: "Test stand-in for page.add.",
            params: .obj(["doc": .ref, "position": .str(), "id": .str()], required: ["doc"]), effect: .edit)) { params, ctx in
            let doc = NodeRef.documentID(from: params["doc"]?.stringValue ?? "")
            let id = NibID(params["id"]?.stringValue ?? NibID.make().raw)
            try ctx.mutate { tx in
                let order = try tx.content(doc).orderKey(.end, relativeTo: nil)
                _ = try tx.put(PageRecord(id: id, order: order), doc: doc)
            }
            return ["ref": .string(NodeRef.page(doc, id).description)]
        }
    }

    func testAddingAPageFromTheCanvasShowsTheNewPage() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let pageView = try XCTUnwrap(vc.scrollView.pageViews[Fixtures.page1])
        let summary = try XCTUnwrap(pageView.accessibilityElements?.first as? UIAccessibilityElement)
        XCTAssertEqual(summary.accessibilityCustomActions?.count ?? 0, 0, "no Add Page without page.add")

        registerPageAddStandIn(h)
        pageView.invalidateAccessibility()
        let actions = (pageView.accessibilityElements?.first as? UIAccessibilityElement)?.accessibilityCustomActions
        XCTAssertEqual(actions?.map { $0.name }, ["Add Page"], "VoiceOver's equivalent of pulling past the last page")

        // Pulling past the last page and letting go (or the Add Page action) adds a page at the end and shows it.
        vc.addPage()
        await waitUntil("the new page") { (try? h.app.workspace.content(Fixtures.docID).livePages.count) == 4 }
        let added = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).livePages.last).id
        await waitUntil("the canvas to show the new page") { h.session.page == added }
        XCTAssertEqual(vc.scrollView.pages.last, added)
        XCTAssertEqual(vc.displayedPage, added)
        XCTAssertEqual(vc.hud.primaryText, "4")
        XCTAssertEqual(vc.hud.secondaryText, "/ 4")

        // Read-only documents take no new pages.
        h.session.readOnly = true
        vc.addPage()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).livePages.count, 4)
    }

    // MARK: Boards reach far

    func testRevealGrowsABoardToAnItemPlacedFarAway() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h, doc: Fixtures.whiteboardID)
        let before = try XCTUnwrap(vc.board).rect
        // Placed far off after the board opened (the assistant, a collaborator).
        let far = Item(kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 400_000, y: -250_000, w: 120, h: 80)))
        let written = try await h.insert([far], page: Fixtures.boardID, doc: Fixtures.whiteboardID)
        let item = try XCTUnwrap(written.first)
        let hit = h.app.content.hitBounds(for: item)
        XCTAssertFalse(before.contains(hit))

        let r = try await h.run("view.reveal", ["ref": .string(NodeRef.item(Fixtures.whiteboardID, Fixtures.boardID, item.id).description)])
        XCTAssertEqual(try r["rect"]?.decode(Rect.self), hit)
        XCTAssertTrue(try XCTUnwrap(vc.board).rect.contains(hit), "the world grew to take the item")
        let t = try XCTUnwrap(vc.host.pageTransform(Fixtures.boardID))
        XCTAssertTrue(vc.scrollView.bounds.contains(hit.cg.applying(t)), "the item is on screen")
    }

    func testBoardFitShowsTheContentAsItIsNowAfterADeletion() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h, doc: Fixtures.whiteboardID)
        let shape = try h.app.workspace.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: Fixtures.boardShapeID)
        let base = h.app.content.paintBounds(for: shape)
        let viewport = vc.scrollView.bounds.size
        let far = Item(kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 20_000, y: 15_000, w: 120, h: 80)))
        let written = try await h.insert([far], page: Fixtures.boardID, doc: Fixtures.whiteboardID)
        let farItem = try XCTUnwrap(written.first)
        let both = base.union(h.app.content.paintBounds(for: farItem))
        XCTAssertEqual(vc.currentBoardContent(), both)
        let wide = try await h.run("view.zoom", ["fit": true])
        XCTAssertEqual(wide["scale"]?.doubleValue ?? 0, ZoomRules.boardFit(content: both, viewport: viewport), accuracy: 1e-9)

        h.app.commands.register(CommandDescriptor(id: "test.deleteFar", title: "Delete", summary: "Test helper.",
                                                  effect: .edit)) { _, ctx in
            try ctx.mutate { tx in try tx.delete(items: [farItem.id], doc: Fixtures.whiteboardID, page: Fixtures.boardID) }
            return .null
        }
        _ = try await h.run("test.deleteFar")
        XCTAssertEqual(vc.currentBoardContent(), base, "the content bounds shrink when an item goes")
        let fit = try await h.run("view.zoom", ["fit": true])
        let expected = ZoomRules.boardFit(content: base, viewport: viewport)
        XCTAssertEqual(fit["scale"]?.doubleValue ?? 0, expected, accuracy: 1e-9)
        XCTAssertGreaterThan(expected, wide["scale"]?.doubleValue ?? 0)
        let c = windowPoint(vc, base.center, Fixtures.boardID)
        XCTAssertEqual(c.x, windowSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(c.y, windowSize.height / 2, accuracy: 0.5)
    }

    // MARK: Scrubber (D-118)

    func testScrubberTakesTouchesOnlyAtItsThumbAndStepsBackWhileWriting() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        h.app.commands.register(CommandDescriptor(id: "test.pageHorizontally", title: "Page Horizontally",
                                                  summary: "Test helper.", effect: .edit)) { _, ctx in
            try ctx.mutate { tx in
                var meta = try tx.content(Fixtures.docID).meta
                meta.scrollDirection = .horizontal
                try tx.putMeta(meta)
            }
            return .null
        }
        _ = try await h.run("test.pageHorizontally")
        let vc = try makeCanvas(h)
        let s = vc.scrubber
        XCTAssertFalse(s.isHidden)
        XCTAssertTrue(s.superview === vc.fixedOverlay, "it stays put while the pages scroll")
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.index, 0)
        s.layoutIfNeeded()
        let thumb = s.thumbHitRect
        XCTAssertGreaterThanOrEqual(thumb.width, 44)
        XCTAssertGreaterThanOrEqual(thumb.height, 44)
        XCTAssertTrue(s.point(inside: CGPoint(x: thumb.midX, y: thumb.midY), with: nil))
        XCTAssertFalse(s.point(inside: CGPoint(x: s.bounds.midX, y: s.bounds.maxY - 4), with: nil),
                       "away from the thumb the Pencil writes on the page")
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        for g in s.gestureRecognizers ?? [] { XCTAssertFalse(g.allowedTouchTypes.contains(pencil)) }

        // VoiceOver adjusts it: the next page, through view.goToPage.
        XCTAssertTrue(s.accessibilityTraits.contains(.adjustable))
        s.accessibilityIncrement()
        await waitUntil("page 2") { h.session.page == Fixtures.page2 }
        XCTAssertEqual(s.index, 1)

        // While the Pencil is down it recedes and takes no touches; it comes back after the Pencil lifts.
        h.session.inking.begin()
        XCTAssertFalse(s.isUserInteractionEnabled)
        XCTAssertLessThan(s.alpha, 1)
        h.session.inking.end()
        await waitUntil("the scrubber to come back") { s.isUserInteractionEnabled && s.alpha == 1 }
    }

    // MARK: Decorations follow the canvas cheaply

    func testDecorationsMoveWithScrollingAndRedrawOnlyForANewZoom() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        let attachment = try XCTUnwrap(vc.attachmentHost.attachment(id: DecorationAttachment.id) as? DecorationAttachment)
        _ = try await h.run("canvas.decorate", CanvasDecorate.example)
        let layer = try XCTUnwrap(attachment.layer(for: Fixtures.page1))
        let redraws = layer.redraws
        XCTAssertGreaterThan(redraws, 0)
        let t0 = try XCTUnwrap(vc.host.pageTransform(Fixtures.page1))
        XCTAssertEqual(layer.frame.minY, layer.drawnRect.applying(t0).minY, accuracy: 1e-6)
        XCTAssertEqual(layer.drawnZoom, t0.a, accuracy: 1e-9)

        _ = try await h.run("view.scrollBy", ["dx": 0, "dy": 20])
        XCTAssertEqual(layer.redraws, redraws, "a small scroll only moves the layer")
        let t1 = try XCTUnwrap(vc.host.pageTransform(Fixtures.page1))
        XCTAssertEqual(layer.frame.minY, layer.drawnRect.applying(t1).minY, accuracy: 1e-6)

        _ = try await h.run("view.zoom", ["scale": 3])
        XCTAssertGreaterThan(layer.redraws, redraws, "a new zoom draws again")
        XCTAssertEqual(layer.drawnZoom, 3, accuracy: 1e-9)
        // At 300 % only the part of the page around the window is drawn.
        XCTAssertLessThan(layer.drawnRect.height, PageSize.a4.height)
    }

    func testAPinchOnlyScalesTheDecorationBitmapUntilItEnds() {
        let l = DecorationLayer()
        let lists = [DisplayList(ops: [DisplayOp(op: .rect, rect: Rect(x: 10, y: 10, width: 50, height: 20), stroke: .black)])]
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        l.update(needed: CGRect(x: 0, y: 0, width: 300, height: 400), page: page, transform: .identity, lists: lists,
                 generation: 1, assets: nil, doc: Fixtures.docID)
        XCTAssertEqual(l.redraws, 1)
        let drawn = l.drawnRect
        let pinch = CGAffineTransform(scaleX: 2, y: 2)
        l.update(needed: CGRect(x: 0, y: 0, width: 150, height: 200), page: page, transform: pinch, lists: lists,
                 generation: 1, assets: nil, doc: Fixtures.docID, zooming: true)
        XCTAssertEqual(l.redraws, 1, "mid-pinch the bitmap only scales")
        XCTAssertEqual(l.drawnRect, drawn)
        XCTAssertEqual(l.drawnZoom, 1)
        XCTAssertEqual(l.frame, drawn.applying(pinch))
        // A new decoration mid-pinch is drawn at once.
        l.update(needed: CGRect(x: 0, y: 0, width: 150, height: 200), page: page, transform: pinch, lists: lists,
                 generation: 2, assets: nil, doc: Fixtures.docID, zooming: true)
        XCTAssertEqual(l.redraws, 2)
        XCTAssertEqual(l.drawnZoom, 2)
        // The pinch ends at a new zoom: drawn again for it.
        let end = CGAffineTransform(scaleX: 3, y: 3)
        l.update(needed: CGRect(x: 0, y: 0, width: 100, height: 130), page: page, transform: end, lists: lists,
                 generation: 2, assets: nil, doc: Fixtures.docID)
        XCTAssertEqual(l.redraws, 3)
        XCTAssertEqual(l.drawnZoom, 3)
    }

    func testPatternDecorationsDrawOnlyAroundTheWindowOnTheirOwnGrid() throws {
        let area = CGRect(x: 500, y: 300, width: 100, height: 50)
        let dots = DisplayOp(op: .dots, rect: Rect(x: 10, y: 10, width: 10_000, height: 10_000), fill: .black,
                             spacing: 7, radius: 1)
        let d = try XCTUnwrap(DecorationLayer.clipped(dots, to: area)?.rect)
        // The dots stay where the whole op puts them (10 + k·7), and cover the area and what a dot's reach needs.
        XCTAssertEqual((d.x - 10) / 7, ((d.x - 10) / 7).rounded(), accuracy: 1e-9)
        XCTAssertEqual((d.y - 10) / 7, ((d.y - 10) / 7).rounded(), accuracy: 1e-9)
        XCTAssertLessThanOrEqual(d.x + 7, Double(area.minX) - 2)
        XCTAssertLessThanOrEqual(d.y + 7, Double(area.minY) - 2)
        XCTAssertGreaterThanOrEqual(d.maxX, Double(area.maxX) + 2)
        XCTAssertGreaterThanOrEqual(d.maxY, Double(area.maxY) + 2)
        XCTAssertLessThan(d.width * d.height, 200 * 200, "not the whole 10,000 pt square")

        let lines = DisplayOp(op: .hlines, rect: Rect(x: 0, y: 0, width: 5_000, height: 5_000), stroke: .black,
                              dash: [6, 4], spacing: 24)
        let l = try XCTUnwrap(DecorationLayer.clipped(lines, to: area)?.rect)
        XCTAssertEqual(l.y / 24, (l.y / 24).rounded(), accuracy: 1e-9)
        XCTAssertEqual(l.x / 10, (l.x / 10).rounded(), accuracy: 1e-9, "the dashes keep their phase")
        XCTAssertLessThanOrEqual(l.x, Double(area.minX))
        XCTAssertGreaterThanOrEqual(l.maxX, Double(area.maxX))
        XCTAssertLessThan(l.height, 200)

        // Nowhere near the window: nothing to draw. Other ops are left alone.
        XCTAssertNil(DecorationLayer.clipped(dots, to: CGRect(x: -500, y: -500, width: 10, height: 10)))
        let box = DisplayOp(op: .rect, rect: Rect(x: 0, y: 0, width: 1e6, height: 1e6), stroke: .black)
        XCTAssertEqual(DecorationLayer.clipped(box, to: area), box)
        XCTAssertEqual(DecorationLayer.clipped(DisplayList(ops: [box, dots]), to: area).ops.count, 2)
    }

    // MARK: Render failure (DESIGN.md §14.18)

    func testAPageThatFailsToRenderOffersTryAgainAndRestoreFromBackup() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let vc = try makeCanvas(h)
        vc.pageDidFail(Fixtures.page1)
        XCTAssertFalse(vc.errorView.isHidden)
        XCTAssertTrue(vc.errorView.superview === vc.fixedOverlay)
        // The design system's empty state (DESIGN.md §14.18), hosted as the canvas's child.
        XCTAssertTrue(vc.children.contains(vc.errorView.hosting))
        XCTAssertGreaterThan(vc.errorView.frame.height, 0)
        XCTAssertEqual(vc.errorView.actionTitles, ["Try Again"], "no backups without the Cloud & Backup panel")

        var opened: [JSONValue] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelOpen, title: "Open Panel", summary: "Test stand-in.",
                                                  params: .obj(["id": .str()], required: ["id"]), effect: .session)) { params, _ in
            opened.append(params)
            return .null
        }
        h.app.ui.panels.register(PanelDescriptor(id: PanelIDs.cloudBackup, title: "Cloud & Backup", icon: "externaldrive",
                                                 placement: .sheet, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        vc.pageDidFail(Fixtures.page1)
        XCTAssertEqual(vc.errorView.actionTitles, ["Try Again", "Restore from Backup"])
        vc.errorView.actions[1].handler()
        await waitUntil("panel.open") { !opened.isEmpty }
        XCTAssertEqual(opened.first?["id"]?.stringValue, PanelIDs.cloudBackup)

        vc.errorView.actions[0].handler()
        XCTAssertTrue(vc.errorView.isHidden)
        XCTAssertTrue(vc.failedPages.isEmpty)
    }

    func testABoardWhoseTilesFailToRenderSaysSoAndTriesAgain() async throws {
        let h = Harness(features: [FeatCanvasFeature.self])
        let renderer = FailingRenderer()
        h.app.services.renderer = renderer
        // A board has no low-resolution preview: only its tiles can fail.
        let vc = try makeCanvas(h, doc: Fixtures.whiteboardID)
        await waitUntil("the board to fail") { vc.failedPages.contains(Fixtures.boardID) }
        XCTAssertFalse(vc.errorView.isHidden)
        XCTAssertEqual(vc.errorView.actionTitles, ["Try Again"])
        let view = try XCTUnwrap(vc.scrollView.pageViews[Fixtures.boardID])
        XCTAssertFalse(view.tileKeys.isEmpty, "failed tiles keep their place, for Try Again")
        await waitUntil("every tile to finish") { view.isSettled }
        let failures = renderer.failures

        vc.errorView.actions[0].handler()
        XCTAssertTrue(vc.errorView.isHidden)
        await waitUntil("the tiles asked for again") { renderer.failures >= failures + view.tileKeys.count }
        await waitUntil("the board to fail again") { vc.failedPages.contains(Fixtures.boardID) }
        XCTAssertFalse(vc.errorView.isHidden)
    }
}

// MARK: - Test doubles

@MainActor
private final class ProbeAttachment: CanvasAttachment {
    var attached = 0
    var detached = 0
    var changes = 0
    let marker = UIView()

    func attach(to host: CanvasHost) {
        attached += 1
        host.canvasView.addSubview(marker)
    }

    func detach(from host: CanvasHost) {
        detached += 1
        marker.removeFromSuperview()
    }

    func canvasDidChange(_ host: CanvasHost) { changes += 1 }
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool { false }
}

@MainActor
private final class ProbeTool: CanvasTool {
    static let toolID = "test.probe"
    let id = "test.probe"
    var inputMode: CanvasInputMode { .samples }
    var isSticky: Bool { false }
    var activations = 0
    var deactivations = 0

    func activate(_ host: CanvasHost) { activations += 1 }
    func deactivate(_ host: CanvasHost) { deactivations += 1 }
}

@MainActor
private final class ProbeInput: CanvasInputController {
    var changes = 0
    var zoomEnds = 0
    var pageChanges = 0
    var toolChanges = 0
    var readOnlyChanges = 0
    var cancels = 0
    var closes = 0

    func canvasDidChange(_ host: CanvasHostImpl) { changes += 1 }
    func canvasDidEndZooming(_ host: CanvasHostImpl) { zoomEnds += 1 }
    func canvasActivePageDidChange(_ host: CanvasHostImpl) { pageChanges += 1 }
    func canvasActiveToolDidChange(_ host: CanvasHostImpl) { toolChanges += 1 }
    func canvasReadOnlyDidChange(_ host: CanvasHostImpl) { readOnlyChanges += 1 }
    func canvasCancelWetStroke(_ host: CanvasHostImpl) { cancels += 1 }
    func canvasWillClose(_ host: CanvasHostImpl) { closes += 1 }
}

/// Moves every stroke 10 pt down (stands in for stabilisation or ruler projection).
@MainActor
private final class ShiftProcessor: StrokeProcessor {
    var pages: [PageID] = []

    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool {
        pages.append(page)
        stroke.points = stroke.points.map { p in
            var p = p
            p.y += 10
            return p
        }
        return true
    }
}

/// Consumes every stroke (a gesture).
@MainActor
private final class DropProcessor: StrokeProcessor {
    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool { false }
}

/// World-coordinate test tiles with a coloured item at the fixture shape, so paper and placeholders cannot pass
/// the rendered-content snapshot assertion. No dependency on another feature's drawers.
private final class BoardSnapshotRenderer: PageRenderer {
    func render(_ request: RenderRequest) async throws -> RenderResult {
        let region = request.region ?? Rect(x: 0, y: 0, width: 200, height: 120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = CGFloat(request.scale)
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: region.cg.size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: -CGFloat(region.x), y: -CGFloat(region.y))
            cg.setFillColor(RGBA.white.cgColor)
            cg.fill(region.cg)
            cg.setFillColor(RGBA(30, 170, 70).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        }
        return RenderResult(image: image.cgImage!, region: region, scale: request.scale)
    }

    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? { nil }
    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {}
    func purgeCaches() {}
}

/// Records every render request (renders run concurrently, off the main actor) and returns a tiny bitmap.
private final class RecordingRenderer: PageRenderer {
    private let lock = NSLock()
    private var recorded: [RenderRequest] = []
    private var invalidated: [(page: PageID, rect: Rect?)] = []
    private let image = FakeRenderer.blank(CGSize(width: 4, height: 4))

    var requests: [RenderRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var invalidations: [(page: PageID, rect: Rect?)] {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    private func record(_ r: RenderRequest) {
        lock.lock()
        recorded.append(r)
        lock.unlock()
    }

    func render(_ request: RenderRequest) async throws -> RenderResult {
        record(request)
        return RenderResult(image: image, region: request.region ?? Rect(x: 0, y: 0, width: 1, height: 1), scale: request.scale)
    }

    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? { image }

    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {
        lock.lock()
        invalidated.append((page, rect))
        lock.unlock()
    }

    func purgeCaches() {}
}

/// Draws previews but fails every tile (a damaged page).
private final class FailingRenderer: PageRenderer {
    private let lock = NSLock()
    private var failed = 0
    private let image = FakeRenderer.blank(CGSize(width: 4, height: 4))

    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    private func countFailure() {
        lock.lock()
        failed += 1
        lock.unlock()
    }

    func render(_ request: RenderRequest) async throws -> RenderResult {
        guard request.region == nil else {
            countFailure()
            throw NibError(.internalError, "the tile could not be drawn")
        }
        return RenderResult(image: image, region: Rect(x: 0, y: 0, width: 1, height: 1), scale: request.scale)
    }

    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? { image }
    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {}
    func purgeCaches() {}
}
