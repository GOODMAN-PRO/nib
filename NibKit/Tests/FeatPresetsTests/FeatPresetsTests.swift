import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
import NibDesign
@testable import FeatPresets

@MainActor
private final class PresetTestNavigator: SceneNavigator {
    let session: EditorSession
    var openDocuments: [DocumentID] { [] }
    var activeDocument: DocumentID? { session.document }
    var rootViewController: UIViewController? { nil }
    var presented: [UIViewController] = []
    var onPresent: ((UIViewController) -> Void)?

    init(session: EditorSession) { self.session = session }
    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {}
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) {}
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) {
        onPresent?(viewController)
        presented.append(viewController)
    }
}

/// Like the toolbar, re-read the feature's descriptor from a SwiftUI body. Constructing
/// a descriptor once in the test would freeze the Binding's cached value in the root view.
private struct PresetPopoverTestHost: View {
    let model: PresetMenuModel

    var body: some View {
        let popover = model.makePopover()
        NibPopoverPanel(title: popover.title) { popover.content }
            .budsFrom(popover.source, isPresented: popover.isPresented, instant: true)
    }
}

/// Paints `rect` (page points) in `colour` over white, for the requested region; `scaleFactor` makes it answer with a
/// different scale than asked, the way a renderer that caps the long edge does.
final class PaintedRenderer: PageRenderer {
    let rect: Rect
    let colour: UIColor
    let scaleFactor: Double
    private(set) var requests: [RenderRequest] = []

    init(rect: Rect, colour: UIColor, scaleFactor: Double = 1) {
        self.rect = rect
        self.colour = colour
        self.scaleFactor = scaleFactor
    }

    func render(_ request: RenderRequest) async throws -> RenderResult {
        requests.append(request)
        let region = request.region ?? Rect(x: 0, y: 0, width: PageSize.a4.width, height: PageSize.a4.height)
        let scale = request.scale * scaleFactor
        let size = CGSize(width: max(1, (region.width * scale).rounded()), height: max(1, (region.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            colour.setFill()
            ctx.fill(CGRect(x: (rect.x - region.x) * scale, y: (rect.y - region.y) * scale,
                            width: rect.width * scale, height: rect.height * scale))
        }
        return RenderResult(image: image.cgImage!, region: region, scale: scale)
    }

    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? { nil }
    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {}
    func purgeCaches() {}
}

@MainActor
final class FeatPresetsTests: XCTestCase {
    private let vermilion = RGBA(0xD9, 0x43, 0x2B)

    private func presets(_ h: Harness, _ tool: String) -> ToolPresets {
        h.app.settings.get(NibSettings.presets(tool))
    }

    private func assertInvalid(_ h: Harness, _ command: String, _ params: JSONValue, path: String? = nil,
                               as principal: Principal = .user, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await h.run(command, params, as: principal)
            XCTFail("\(command) \(params.jsonString()) should fail", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams, e.message, file: file, line: line)
            if let path { XCTAssertEqual(e.path, path, file: file, line: line) }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func assertClose(_ a: RGBA?, _ b: RGBA, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("no colour", file: file, line: line) }
        let close = abs(Int(a.r) - Int(b.r)) <= 1 && abs(Int(a.g) - Int(b.g)) <= 1 && abs(Int(a.b) - Int(b.b)) <= 1
        XCTAssertTrue(close, "\(a.hex) is not \(b.hex)", file: file, line: line)
    }

    // MARK: Registration

    func testRegistersCommandsMenusAttachmentAndShortcuts() {
        let h = Harness(features: [FeatPresetsFeature.self])
        let ids = ["preset.select", "preset.setSwatch", "preset.addSwatch", "preset.removeSwatch", "preset.moveSwatch",
                   "preset.setWidth", "preset.reset"]
        for id in ids {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, FeatPresetsFeature.id, id)
            XCTAssertEqual(h.app.commands.descriptor(id)?.effect, .session, id)
        }
        XCTAssertEqual(Set(h.app.commands.all().filter { $0.owner == FeatPresetsFeature.id }.map { $0.id }), Set(ids))
        for tool in NibSettings.presetTools {
            let menu = h.app.ui.toolMenus.get(tool)
            XCTAssertEqual(menu?.owner, FeatPresetsFeature.id, tool)
            // contracts-v2: the thickness slider and the colour editor are the menu's popover, not modes of the bar.
            let popover = menu?.makePopover?(h.session)
            XCTAssertNotNil(popover, tool)
            XCTAssertEqual(popover?.source, PresetMenuModel.anchorID(tool), tool)
            XCTAssertEqual(popover?.isPresented.wrappedValue, false, "\(tool): closed until a slot is tapped again")
        }
        XCTAssertNotNil(h.app.ui.canvasAttachments.get(EyedropperAttachment.descriptorID))
        let keys = h.app.content.keyCommands.all.filter { $0.owner == FeatPresetsFeature.id }
        XCTAssertEqual(Set(keys.map { $0.shortcut.key }), Set(["[", "]", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]))
        XCTAssertTrue(keys.allSatisfy { $0.command == "preset.select" && $0.scope == .canvas })
    }

    /// contracts-v2.2 routing: the plain preset keys are live on notebook and whiteboard canvases only, never while
    /// text has the keyboard, in the library, a study set or a text document.
    func testPresetKeysLiveOnCanvasDocumentsOnly() throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let keys = h.app.content.keyCommands.all.filter { $0.owner == FeatPresetsFeature.id }
        XCTAssertEqual(keys.count, 12)
        for key in keys {
            XCTAssertEqual(key.docKinds, [.notebook, .whiteboard], key.id)
            XCTAssertTrue(key.isActive(in: KeyCommandContext(docKind: .notebook)), key.id)
            XCTAssertTrue(key.isActive(in: KeyCommandContext(docKind: .whiteboard)), key.id)
            XCTAssertFalse(key.isActive(in: KeyCommandContext(docKind: .notebook, isEditingText: true)), key.id)
            XCTAssertFalse(key.isActive(in: KeyCommandContext(docKind: .studySet)), key.id)
            XCTAssertFalse(key.isActive(in: KeyCommandContext(docKind: .textDocument)), key.id)
            XCTAssertFalse(key.isActive(in: KeyCommandContext(docKind: nil, hasTabs: true)), key.id)
        }
        let thinner = try XCTUnwrap(h.app.content.keyCommands.get("presets.width.previous"))
        XCTAssertEqual(KeyCommandRouting.active([thinner], in: KeyCommandContext(docKind: .whiteboard)).map { $0.id },
                       [thinner.id])
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatPresetsFeature.self])
        XCTAssertEqual(problems, [])
    }

    /// Acceptance: the menu renders for all six tools.
    func testMenuRendersForAllSixTools() {
        let h = Harness(features: [FeatPresetsFeature.self])
        for tool in NibSettings.presetTools {
            guard let menu = h.app.ui.toolMenus.get(tool) else { return XCTFail("no menu for \(tool)") }
            let host = UIHostingController(rootView: menu.makeView(h.session))
            let size = host.sizeThatFits(in: CGSize(width: 1194, height: 834))
            XCTAssertGreaterThanOrEqual(size.height, 44, tool)
            // Three thickness slots, a separator and three colour slots at least.
            XCTAssertGreaterThan(size.width, 6 * 44, tool)
        }
    }

    /// Include the toolbar-owned chevron, separator and NibDesign capsule padding in the fit check.
    /// fixedSize prevents the proposed width from hiding an intrinsically oversized row, as in the screenshots.
    func testCompactPresetCapsuleFitsChromeInsetsWithoutShrinkingTargets() throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        for tool in NibSettings.presetTools {
            for count in [1, 3, ToolPresets.maxSwatches] {
                var saved = ToolPresets.defaults(for: tool)
                saved.swatches = Array(repeating: saved.swatches[0], count: count)
                saved.selectedSwatch = count - 1
                h.app.settings.set(NibSettings.presets(tool), saved)
                let model = PresetMenuModel(app: h.app, session: h.session, tool: tool)
                for appearance in [ColorScheme.light, .dark] {
                    for typeSize in [DynamicTypeSize.large, .accessibility3] {
                        let capsule = NibToolOptionsBar(id: "test.presets") {
                            HStack(spacing: 0) {
                                ToolPresetMenu(model: model)
                                NibBarSeparator()
                                NibIconButton(.chevronDown, label: "Tool Settings") {}
                            }
                        }
                        .fixedSize()
                        .environment(\.horizontalSizeClass, .compact)
                        .environment(\.colorScheme, appearance)
                        .environment(\.dynamicTypeSize, typeSize)
                        let host = UIHostingController(rootView: capsule)
                        let size = host.sizeThatFits(in: CGSize(width: 320, height: 852))
                        let context = "\(tool), \(count) swatches, \(appearance), \(typeSize)"
                        XCTAssertLessThanOrEqual(size.width, 320 - 2 * NibMetrics.chromeInset, context)
                        XCTAssertGreaterThanOrEqual(size.width, 5 * NibMetrics.hitTarget,
                                                    "Three widths, current colour and expansion: \(context)")
                        XCTAssertGreaterThanOrEqual(size.height, NibMetrics.hitTarget, context)

                        // Restore, Done and the host chevron must also fit after a long-press rearrangement.
                        model.beginArranging()
                        let arranged = host.sizeThatFits(in: CGSize(width: 320, height: 852))
                        XCTAssertLessThanOrEqual(arranged.width, 320 - 2 * NibMetrics.chromeInset, context)
                        model.endArranging()
                    }
                }
            }
        }
    }

    func testCompactColourOptionsExposeSavedPresetsAndAddThroughExistingPopover() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let model = PresetMenuModel(app: h.app, session: h.session, tool: "pen")
        model.tapSwatch(model.presets.selectedSwatch)
        XCTAssertEqual(model.popover, .colour(.slot(0)))

        // The compact bar has no Add control; the same action now comes from its expanded colour options.
        model.addColour()
        XCTAssertEqual(model.popover, .colour(.add))
        XCTAssertEqual(model.makePopover().source, PresetMenuModel.anchorID("pen"))
        let added = try XCTUnwrap(model.pick(vermilion))
        let succeeded = await added.value
        XCTAssertTrue(succeeded)
        model.reload()
        XCTAssertEqual(model.presets.swatches.count, 4)
        XCTAssertEqual(model.presets.selectedSwatch, 3)

        // A saved slot that is absent from the compact bar remains selectable without replacing any colour.
        let colours = model.presets.swatches
        model.tapSwatch(0)
        for _ in 0..<200 where presets(h, "pen").selectedSwatch != 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.reload()
        XCTAssertEqual(model.presets.selectedSwatch, 0)
        XCTAssertEqual(model.presets.swatches, colours)
        model.tapSwatch(0)
        let content = UIHostingController(rootView: model.makePopover().content
            .environment(\.horizontalSizeClass, .compact)
            .frame(width: NibMetrics.popoverContentWidth))
        let size = content.sizeThatFits(in: CGSize(width: NibMetrics.popoverContentWidth, height: 834))
        XCTAssertEqual(size.width, NibMetrics.popoverContentWidth, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(size.height, NibMetrics.hitTarget)
    }

    func testBarAndPopoverRenderInEveryMode() throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let menus = PresetMenus(app: h.app)
        let popovers: [PresetPopover] = [.width(0), .width(2), .colour(.slot(0)), .colour(.add)]
        for tool in NibSettings.presetTools {
            let model = try XCTUnwrap(menus.model(tool, session: h.session))
            model.beginArranging()
            let bar = UIHostingController(rootView: ToolPresetMenu(model: model))
            let arranged = bar.sizeThatFits(in: CGSize(width: 1194, height: 834))
            XCTAssertGreaterThanOrEqual(arranged.height, 44, "\(tool) arranging")
            XCTAssertGreaterThan(arranged.width, 3 * 44, "\(tool) arranging")
            model.endArranging()
            for popover in popovers {
                model.open(popover)
                // The palette's popover leaves its content 280 pt (NibMetrics.popoverContentWidth).
                let content = UIHostingController(rootView: model.makePopover().content.frame(width: 280))
                let size = content.sizeThatFits(in: CGSize(width: 280, height: 834))
                XCTAssertGreaterThanOrEqual(size.height, 44, "\(tool) \(popover)")
                model.close()
            }
        }
    }

    /// The bar (`makeView`) and its popover (`makePopover`) of one window read one state; another window has its own.
    func testBarAndPopoverShareOneStatePerWindow() throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let menus = PresetMenus(app: h.app)
        let menu = FeatPresetsFeature.menuDescriptor("pen", menus: menus)
        let other = EditorSession()
        h.app.services.sessions.add(other)
        let model = try XCTUnwrap(menus.model("pen", session: h.session))
        XCTAssertTrue(menus.model("pen", session: h.session) === model)
        XCTAssertFalse(menus.model("pen", session: other) === model, "each window has its own popover state")
        XCTAssertFalse(menus.model("pencil", session: h.session) === model, "and each tool")

        final class Log: @unchecked Sendable { var sessions: [String] = [] }  // written on the posting (main) thread
        let updates = Log()
        let token = NotificationCenter.default.addObserver(forName: .nibChromeNeedsUpdate, object: h.app.ui, queue: nil) {
            updates.sessions.append(($0.userInfo?["session"] as? String) ?? "all")
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Tapping the selected thickness again opens its slider as the menu's popover.
        model.tapWidth(model.presets.selectedWidth)
        XCTAssertEqual(model.popover, .width(1))
        XCTAssertEqual(menu.makePopover?(h.session)?.isPresented.wrappedValue, true)
        XCTAssertEqual(menu.makePopover?(other)?.isPresented.wrappedValue, false)
        XCTAssertEqual(updates.sessions, [h.session.id.raw], "the palette is asked to re-read the popover of this window")
        // The palette closes it (tool change, another popover) through the binding.
        let popover = try XCTUnwrap(menu.makePopover?(h.session))
        popover.isPresented.wrappedValue = false
        XCTAssertNil(model.popover)
        XCTAssertEqual(model.shown, .width(1), "the content stays while the bud retracts")

        // The selected colour again: its editor; again: closed. Another colour: selected, nothing opens.
        model.tapSwatch(0)
        XCTAssertEqual(model.popover, .colour(.slot(0)))
        model.tapSwatch(0)
        XCTAssertNil(model.popover)
        model.addColour()
        XCTAssertEqual(model.popover, .colour(.add))
        model.beginArranging()
        XCTAssertNil(model.popover, "rearranging closes the popover")
        XCTAssertTrue(model.arranging)
        model.open(.width(0))
        XCTAssertFalse(model.arranging)
    }

    func testThicknessPopoverCommitsThroughPresetCommands() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let model = try XCTUnwrap(PresetMenus(app: h.app).model("pencil", session: h.session))
        model.open(.width(2))
        XCTAssertEqual(model.editedWidth, 2.4, accuracy: 0.011)
        model.setWidthPosition(1)
        XCTAssertEqual(model.editedWidth, PresetRules.widthRange("pencil").upperBound)
        XCTAssertEqual(presets(h, "pencil").widths[2], 2.4, "nothing is written while the slider moves")
        let committed = try XCTUnwrap(model.commitWidth())
        let ok = await committed.value
        XCTAssertTrue(ok)
        XCTAssertEqual(presets(h, "pencil").widths[2], 10)
        model.reload()
        XCTAssertNil(model.commitWidth(), "an unchanged thickness writes nothing")

        let pattern = try XCTUnwrap(model.setPattern(.dashed))
        _ = await pattern.value
        XCTAssertEqual(presets(h, "pencil").patterns[2], .dashed)

        // Closing the popover commits a slider that has not rested yet.
        model.reload()
        model.setWidthPosition(0)
        model.close()
        for _ in 0..<200 where presets(h, "pencil").widths[2] != 0.1 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(presets(h, "pencil").widths[2], 0.1)
        XCTAssertEqual(presets(h, "pen"), ToolPresets.defaults(for: "pen"), "other tools are untouched")
    }

    func testColourPopoverSetsAddsAndRemovesSlots() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let model = try XCTUnwrap(PresetMenus(app: h.app).model("highlighter", session: h.session))
        let mint = try XCTUnwrap(PresetColour.palette(for: "highlighter").first { $0.id == NibHighlighter.mint.rawValue })
        model.open(.colour(.slot(0)))
        let set = try XCTUnwrap(model.pick(mint.colour))
        _ = await set.value
        XCTAssertNil(model.popover, "a choice closes the editor")
        XCTAssertEqual(presets(h, "highlighter").swatches[0].color, RGBA(mint.colour.r, mint.colour.g, mint.colour.b,
                                                                         RGBA.highlighterAlpha))
        model.reload()
        XCTAssertEqual(PresetColour.name(model.presets.swatches[0].color), mint.name)

        model.open(.colour(.add))
        XCTAssertNil(model.colourSlot)
        let added = try XCTUnwrap(model.pick(mint.colour))
        _ = await added.value
        XCTAssertEqual(presets(h, "highlighter").swatches.count, 4)
        XCTAssertEqual(presets(h, "highlighter").selectedSwatch, 3)

        model.reload()
        model.open(.colour(.slot(3)))
        model.removeEdited()
        for _ in 0..<200 where presets(h, "highlighter").swatches.count != 3 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(presets(h, "highlighter").swatches.count, 3)
        XCTAssertNil(model.popover)

        // A slot removed elsewhere (another window, the AI) closes its open editor.
        model.reload()
        model.open(.colour(.slot(2)))
        try await h.run("preset.removeSwatch", ["tool": "highlighter", "index": 2])
        model.reload()
        XCTAssertNil(model.popover)
    }

    func testColourSlotsHostNativeLongPressMenusAndKeepTapSeparate() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let model = PresetMenuModel(app: h.app, session: h.session, tool: "pen")
        let host = UIHostingController(rootView: ToolPresetMenu(model: model)
            .environment(\.horizontalSizeClass, .regular))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 300))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func buttons(_ view: UIView) -> [PresetSwatchNativeButton] {
            (view as? PresetSwatchNativeButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        for _ in 0..<100 where buttons(host.view).count != model.presets.swatches.count {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let slots = buttons(host.view)
        XCTAssertEqual(slots.count, model.presets.swatches.count)
        let selected = try XCTUnwrap(slots.first(where: \.isSelected))
        var ancestor = selected.superview
        while let view = ancestor {
            XCTAssertFalse(view is UIScrollView, "colours that fit must not delay the long press in a nested scroll view")
            ancestor = view.superview
        }
        XCTAssertTrue(selected.isContextMenuInteractionEnabled, "UIKit must own the long press on the swatch itself")
        XCTAssertFalse(selected.showsMenuAsPrimaryAction, "a short tap keeps the existing select/edit behaviour")
        let interaction = try XCTUnwrap(selected.contextMenuInteraction)
        let configuration = try XCTUnwrap(selected.contextMenuInteraction(interaction, configurationForMenuAtLocation:
            CGPoint(x: selected.bounds.midX, y: selected.bounds.midY)))
        selected.sendActions(for: .menuActionTriggered)
        selected.sendActions(for: .touchUpInside)
        XCTAssertNil(model.popover, "requesting the long-press menu must not run the tap action")
        XCTAssertEqual(selected.accessibilityLabel, PresetColour.name(model.presets.color))
        XCTAssertTrue(selected.accessibilityTraits.contains(.selected))
        let change = try XCTUnwrap(selected.menu?.children.compactMap { $0 as? UIAction }
            .first { $0.title == "Change Colour" })
        selected.sendAction(change)
        XCTAssertEqual(model.popover, .colour(.slot(0)), "the menu edits the held slot")
        selected.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
        selected.sendActions(for: .touchUpInside)
        XCTAssertEqual(model.popover, .colour(.slot(0)), "the menu's final release must not toggle the editor closed")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        model.close()
        selected.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(model.popover, .colour(.slot(0)), "a short tap still opens the selected slot")
        selected.sendActions(for: .primaryActionTriggered)
        XCTAssertNil(model.popover, "and another short tap closes it")
    }

    func testNativeColourMenuEditsHeldSlotAndPreservesOtherActionsForEveryTool() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        for tool in NibSettings.presetTools {
            let model = PresetMenuModel(app: h.app, session: h.session, tool: tool)
            let button = PresetSwatchNativeButton()
            let original = model.presets
            var askedToRestore = false
            let menu = PresetSwatchMenu.make(model: model, index: 1) { askedToRestore = true }
            let actions = menu.children.compactMap { $0 as? UIAction }
            XCTAssertEqual(actions.map(\.title), ["Change Colour", "Rearrange Colours", "Remove Colour", "Restore Default Presets"])
            button.sendAction(actions[0])
            XCTAssertEqual(model.popover, .colour(.slot(1)), tool)
            XCTAssertEqual(model.presets.selectedSwatch, original.selectedSwatch, "holding another slot must not select it")
            let picked = try XCTUnwrap(model.pick(vermilion))
            let succeeded = await picked.value
            XCTAssertTrue(succeeded)
            model.reload()
            XCTAssertEqual(model.presets.swatches.count, original.swatches.count)
            XCTAssertEqual(model.presets.swatches[0], original.swatches[0])
            XCTAssertEqual(PresetColour.rgbHex(model.presets.swatches[1].color), PresetColour.rgbHex(vermilion))
            try await h.run("preset.select", ["tool": .string(tool), "swatch": 1])
            XCTAssertEqual(PresetColour.rgbHex(presets(h, tool).color), PresetColour.rgbHex(vermilion),
                           "the next stroke uses the changed colour after selecting that slot")
            button.sendAction(actions[1])
            XCTAssertTrue(model.arranging)
            button.sendAction(actions[3])
            XCTAssertTrue(askedToRestore)
            XCTAssertNotEqual(presets(h, tool), original, "Restore still requires confirmation")
            XCTAssertTrue(actions[2].attributes.contains(.destructive))
            button.sendAction(actions[2])
            for _ in 0..<100 where presets(h, tool).swatches.count == original.swatches.count {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(presets(h, tool).swatches.count, original.swatches.count - 1)
            while presets(h, tool).swatches.count > 1 {
                try await h.run("preset.removeSwatch", ["tool": .string(tool), "index": 0])
            }
            model.reload()
            let lastSlotMenu = PresetSwatchMenu.make(model: model, index: 0) {}
            XCTAssertFalse(lastSlotMenu.children.contains { $0.title == "Remove Colour" }, "the last colour cannot be removed")
        }
    }

    // MARK: Commands

    func testSelectChecksBounds() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        try await h.run("preset.select", ["tool": "pen", "swatch": 2, "width": 0])
        XCTAssertEqual(presets(h, "pen").selectedSwatch, 2)
        XCTAssertEqual(presets(h, "pen").selectedWidth, 0)
        await assertInvalid(h, "preset.select", ["tool": "pen", "swatch": 3], path: "$.swatch")
        await assertInvalid(h, "preset.select", ["tool": "pen", "width": 3], path: "$.width")
        await assertInvalid(h, "preset.select", ["tool": "pen"], path: "$.swatch")
        await assertInvalid(h, "preset.select", ["tool": "eraser", "swatch": 0], path: "$.tool")
        // Other callers get the schema check first.
        await assertInvalid(h, "preset.select", ["tool": "pen", "width": 7], path: "$.width", as: .ai("chat"))
        XCTAssertEqual(presets(h, "pen").selectedSwatch, 2, "a failed call changes nothing")
    }

    func testSelectCurrentToolAndWidthStep() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        h.session.tool = "highlighter"
        try await h.run("preset.select", ["tool": "current", "widthStep": 1])
        XCTAssertEqual(presets(h, "highlighter").selectedWidth, 2)
        try await h.run("preset.select", ["tool": "current", "widthStep": 1])
        XCTAssertEqual(presets(h, "highlighter").selectedWidth, 2, "the step stops at the last slot")
        XCTAssertEqual(presets(h, "pen").selectedWidth, 1, "only the active tool changes")
        h.session.tool = "eraser"
        let out = try await h.run("preset.select", ["tool": "current", "swatch": 0])
        XCTAssertEqual(out["applied"], false)
    }

    func testKeyboardShortcutsDriveTheActiveTool() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        h.session.tool = "pencil"
        let thinner = try XCTUnwrap(h.app.content.keyCommands.get("presets.width.previous"))
        try await h.run(thinner.command, thinner.params)
        XCTAssertEqual(presets(h, "pencil").selectedWidth, 0)
        let third = try XCTUnwrap(h.app.content.keyCommands.get("presets.swatch.3"))
        try await h.run(third.command, third.params)
        XCTAssertEqual(presets(h, "pencil").selectedSwatch, 2)
        let ninth = try XCTUnwrap(h.app.content.keyCommands.get("presets.swatch.9"))
        let out = try await h.run(ninth.command, ninth.params)
        XCTAssertEqual(out["applied"], false, "a colour key past the last slot does nothing")
        XCTAssertEqual(presets(h, "pencil").selectedSwatch, 2)
    }

    /// Acceptance: at most 12 colour slots; the new one is selected.
    func testAddSwatchCapsAtTwelve() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        for i in 3..<ToolPresets.maxSwatches {
            try await h.run("preset.addSwatch", ["tool": "pen", "color": "#2F7A3C"])
            XCTAssertEqual(presets(h, "pen").swatches.count, i + 1)
            XCTAssertEqual(presets(h, "pen").selectedSwatch, i)
        }
        await assertInvalid(h, "preset.addSwatch", ["tool": "pen", "color": "#2F7A3C"], path: "$.tool")
        XCTAssertEqual(presets(h, "pen").swatches.count, 12)
        await assertInvalid(h, "preset.addSwatch", ["tool": "pencil", "color": "green"], path: "$.color")
    }

    func testRemoveKeepsOneAndFixesTheSelection() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        try await h.run("preset.select", ["tool": "pen", "swatch": 2])
        try await h.run("preset.removeSwatch", ["tool": "pen", "index": 0])
        XCTAssertEqual(presets(h, "pen").swatches.count, 2)
        XCTAssertEqual(presets(h, "pen").selectedSwatch, 1, "the selection stays on the same colour")
        XCTAssertEqual(presets(h, "pen").color, ToolPresets.defaults(for: "pen").swatches[2].color)
        await assertInvalid(h, "preset.removeSwatch", ["tool": "pen", "index": 5], path: "$.index")
        try await h.run("preset.removeSwatch", ["tool": "pen", "index": 1])
        await assertInvalid(h, "preset.removeSwatch", ["tool": "pen", "index": 0], path: "$.index")
        XCTAssertEqual(presets(h, "pen").swatches.count, 1)
    }

    func testMoveFollowsTheSelection() throws {
        var p = ToolPresets.defaults(for: "pen")
        p.swatches.append(PresetSwatch(color: vermilion))
        p.selectedSwatch = 1
        let moved = try PresetRules.moveSwatch(p, from: 1, to: 3)
        XCTAssertEqual(moved.swatches[3], p.swatches[1])
        XCTAssertEqual(moved.selectedSwatch, 3)
        let before = try PresetRules.moveSwatch(p, from: 3, to: 0)
        XCTAssertEqual(before.swatches[0].color, vermilion)
        XCTAssertEqual(before.selectedSwatch, 2, "the selected colour moved one to the right")
        let after = try PresetRules.moveSwatch(p, from: 0, to: 3)
        XCTAssertEqual(after.selectedSwatch, 0)
        XCTAssertThrowsError(try PresetRules.moveSwatch(p, from: 0, to: 4))
    }

    func testSetWidthBoundsAndPatterns() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        try await h.run("preset.setWidth", ["tool": "pen", "index": 2, "width": 3.456, "pattern": "dotted"])
        XCTAssertEqual(presets(h, "pen").widths[2], 3.46)
        XCTAssertEqual(presets(h, "pen").patterns[2], .dotted)
        await assertInvalid(h, "preset.setWidth", ["tool": "pen", "index": 0, "width": 12], path: "$.width")
        await assertInvalid(h, "preset.setWidth", ["tool": "pen", "index": 3, "width": 1], path: "$.index")
        await assertInvalid(h, "preset.setWidth", ["tool": "highlighter", "index": 0, "width": 10, "pattern": "dashed"],
                            path: "$.pattern")
        await assertInvalid(h, "preset.setWidth", ["tool": "tape", "index": 0, "width": 2], path: "$.width")
        try await h.run("preset.setWidth", ["tool": "tape", "index": 0, "width": 40])
        XCTAssertEqual(presets(h, "tape").widths[0], 40)
    }

    func testSetSwatchColourAndTapePattern() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        try await h.run("preset.setSwatch", ["tool": "highlighter", "index": 1, "color": "#86E3AE"])
        XCTAssertEqual(presets(h, "highlighter").swatches[1].color, RGBA(0x86, 0xE3, 0xAE, RGBA.highlighterAlpha),
                       "a highlighter colour without alpha gets the highlighter opacity")
        try await h.run("preset.setSwatch", ["tool": "pen", "index": 0, "color": "#D9432B80"])
        XCTAssertEqual(presets(h, "pen").swatches[0].color, RGBA(0xD9, 0x43, 0x2B, 0x80))
        await assertInvalid(h, "preset.setSwatch", ["tool": "pen", "index": 0, "color": "#12"], path: "$.color")
        await assertInvalid(h, "preset.setSwatch", ["tool": "pen", "index": 0, "color": "#FFFFFF", "pattern": "dots"],
                            path: "$.pattern")

        h.app.content.tapePatterns.register(TapePatternDescriptor(id: "builtin.dots", title: "Dots", owner: "test") {
            Fixtures.pngData
        })
        // contracts-v2 (G23): the slot stores the pinned "<id>.png" ref; a bare id or the ref itself is accepted.
        let dots = PresetSwatch.tapePatternRef(id: "builtin.dots")
        XCTAssertEqual(dots, AssetRef("builtin.dots.png"))
        try await h.run("preset.setSwatch", ["tool": "tape", "index": 2, "color": "#F4C430", "pattern": "builtin.dots"])
        XCTAssertEqual(presets(h, "tape").swatches[2].pattern, dots)
        try await h.run("preset.setSwatch", ["tool": "tape", "index": 1, "color": "#F4C430", "pattern": "builtin.dots.png"])
        XCTAssertEqual(presets(h, "tape").swatches[1].pattern, dots)
        try await h.run("preset.setSwatch", ["tool": "tape", "index": 2, "color": "#8EC5FF"])
        XCTAssertEqual(presets(h, "tape").swatches[2].pattern, dots, "omitting the pattern keeps it")
        try await h.run("preset.setSwatch", ["tool": "tape", "index": 2, "color": "#8EC5FF", "pattern": ""])
        XCTAssertNil(presets(h, "tape").swatches[2].pattern)
        do {
            try await h.run("preset.setSwatch", ["tool": "tape", "index": 2, "color": "#8EC5FF", "pattern": "nope"])
            XCTFail("an unknown pattern should fail")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }

        // The check uses the invoking app's registry (contracts-v2 `ctx.content`): another app's pattern is unknown here.
        let other = Harness(features: [FeatPresetsFeature.self])
        do {
            try await other.run("preset.setSwatch", ["tool": "tape", "index": 0, "color": "#8EC5FF", "pattern": "builtin.dots"])
            XCTFail("a pattern registered in another app should fail")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
    }

    /// A slot saved before contracts-v2 with a bare pattern id still shows and edits as that pattern.
    func testLegacyBarePatternIDsStillResolve() throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        var tape = ToolPresets.defaults(for: "tape")
        tape.swatches[0].pattern = AssetRef("builtin.dots")
        h.app.settings.set(NibSettings.presets("tape"), tape)
        let model = try XCTUnwrap(PresetMenus(app: h.app).model("tape", session: h.session))
        model.open(.colour(.slot(0)))
        XCTAssertEqual(model.editedPatternID, "builtin.dots")
        model.close()
        model.open(.colour(.slot(1)))
        XCTAssertNil(model.editedPatternID)
    }

    /// contracts-v2 (G23): a partial preset written with settings.set decodes instead of falling back to the defaults;
    /// the preset rules still clamp it.
    func testPartialPresetsDecodeAndAreClamped() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        h.app.settings.setJSON(NibSettings.presets("pen").name,
                               ["swatches": [["color": "#D9432B"], ["color": "#1F5FD1"]], "widths": [0.5, 20]])
        let stored = presets(h, "pen")
        XCTAssertEqual(stored.swatches.count, 2, "no fallback to the three defaults")
        XCTAssertEqual(stored.patterns, [.solid, .solid])
        let out = try await h.run("preset.select", ["tool": "pen", "swatch": 1])
        let p = try XCTUnwrap(try out["presets"]?.decode(ToolPresets.self))
        XCTAssertEqual(p.swatches.map { $0.color }, [vermilion, RGBA(0x1F, 0x5F, 0xD1)])
        XCTAssertEqual(p.widths, [0.5, 10, 2.0], "clamped to the pen's bounds, the missing slot from the defaults")
        XCTAssertEqual(p.patterns, [.solid, .solid, .solid])
        XCTAssertEqual(p.selectedSwatch, 1)
        XCTAssertEqual(presets(h, "pen"), p)
    }

    /// Acceptance: reset restores the defaults.
    func testResetRestoresDefaults() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        try await h.run("preset.addSwatch", ["tool": "shape", "color": "#7B3FA0"])
        try await h.run("preset.setWidth", ["tool": "shape", "index": 0, "width": 9])
        XCTAssertNotEqual(presets(h, "shape"), ToolPresets.defaults(for: "shape"))
        let out = try await h.run("preset.reset", ["tool": "shape"])
        XCTAssertEqual(presets(h, "shape"), ToolPresets.defaults(for: "shape"))
        XCTAssertEqual(try out["presets"]?.decode(ToolPresets.self), ToolPresets.defaults(for: "shape"))
    }

    func testPresetCommandsNeverTouchDocumentsOrUndo() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let before = try h.snapshotAll()
        let depths = h.undoDepths()
        try await h.run("preset.addSwatch", ["tool": "pen", "color": "#0B8793"])
        try await h.run("preset.moveSwatch", ["tool": "pen", "from": 3, "to": 0])
        try await h.run("preset.reset", ["tool": "pen"])
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.undoDepths(), depths)
    }

    func testNormalisedRepairsSyncedState() {
        let broken = ToolPresets(swatches: [], widths: [0.01, 99, 1, 2, 3], patterns: [.dashed], selectedSwatch: 7,
                                 selectedWidth: -4)
        let fixed = PresetRules.normalized(broken, tool: "pen")
        XCTAssertEqual(fixed.swatches, ToolPresets.defaults(for: "pen").swatches)
        XCTAssertEqual(fixed.widths, [0.1, 10, 1])
        XCTAssertEqual(fixed.patterns, [.dashed, .solid, .solid])
        XCTAssertEqual(fixed.selectedSwatch, 2)
        XCTAssertEqual(fixed.selectedWidth, 0)
        let many = ToolPresets(swatches: Array(repeating: PresetSwatch(color: vermilion), count: 15), widths: [1, 2])
        XCTAssertEqual(PresetRules.normalized(many, tool: "pencil").swatches.count, 12)
        XCTAssertEqual(PresetRules.normalized(many, tool: "pencil").widths, [1, 2, 2.4])
    }

    // MARK: UI logic

    func testWidthScaleRoundTripsAndStaysInRange() {
        for tool in NibSettings.presetTools {
            let range = PresetRules.widthRange(tool)
            for w in ToolPresets.defaults(for: tool).widths {
                XCTAssertEqual(WidthScale.width(at: WidthScale.position(w, range: range), range: range), w, accuracy: 0.011)
            }
            XCTAssertEqual(WidthScale.width(at: -1, range: range), range.lowerBound)
            XCTAssertEqual(WidthScale.width(at: 2, range: range), range.upperBound)
            XCTAssertLessThan(WidthScale.position(range.lowerBound, range: range),
                              WidthScale.position(range.upperBound, range: range))
        }
    }

    /// Exercise the actual options row, so replacing its shared width buttons with stroke samples regresses here.
    func testOptionsWidthsUseDistinctDotsAndRoundedSelectedCellsForEveryTool() throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let size = CGSize(width: 600, height: 44)
        for tool in NibSettings.presetTools {
            for selected in 0..<3 {
                var saved = ToolPresets.defaults(for: tool)
                // Equal saved widths must still produce the three distinct slot dots, even for patterned pens.
                saved.widths = Array(repeating: saved.widths[1], count: 3)
                if PresetRules.patternTools.contains(tool) { saved.patterns = [.solid, .dashed, .dotted] }
                saved.selectedWidth = selected
                h.app.settings.set(NibSettings.presets(tool), saved)
                let model = PresetMenuModel(app: h.app, session: h.session, tool: tool)
                for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
                    let row = ToolPresetMenu(model: model)
                        .environment(\.horizontalSizeClass, sizeClass)
                        .fixedSize()
                        .frame(width: size.width, height: size.height, alignment: .leading)
                    for variant in NibSnapshot.Variant.allCases {
                        let image = try XCTUnwrap(NibSnapshot.image(row, size: size, variant: variant))
                        let context = "\(tool), selected \(selected), \(sizeClass), \(variant)"
                        func alpha(_ x: CGFloat, _ y: CGFloat) throws -> UInt8 {
                            try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: x, y: y))).a
                        }
                        for (index, diameter) in [CGFloat(5), 8, 12].enumerated() {
                            let origin = CGFloat(index) * 44
                            if index == selected {
                                XCTAssertGreaterThan(try alpha(origin + 22, 4), 0, context)
                                XCTAssertGreaterThan(try alpha(origin + 22, 40), 0, context)
                                XCTAssertEqual(try alpha(origin + 22, 1), 0, context)
                                XCTAssertEqual(try alpha(origin + 22, 43), 0, context)
                                // Inside the radius-12 rectangle, outside the old circular selection.
                                XCTAssertGreaterThan(try alpha(origin + 3, 10), 0, context)
                                XCTAssertEqual(try alpha(origin + 1, 3), 0, context)
                            } else {
                                var horizontal: [CGFloat] = [], vertical: [CGFloat] = []
                                for offset in stride(from: CGFloat(0), to: 44, by: 0.5) {
                                    if try alpha(origin + offset, 22) > 127 { horizontal.append(offset) }
                                    if try alpha(origin + 22, offset) > 127 { vertical.append(offset) }
                                }
                                let width = try XCTUnwrap(horizontal.last) - XCTUnwrap(horizontal.first) + 0.5
                                let height = try XCTUnwrap(vertical.last) - XCTUnwrap(vertical.first) + 0.5
                                XCTAssertEqual(width, diameter, accuracy: 0.5, context)
                                XCTAssertEqual(height, diameter, accuracy: 0.5, "Dots, never dashes: \(context)")
                                XCTAssertEqual(try alpha(origin + 3, 10), 0, context)
                            }
                        }
                    }
                }
            }
        }
    }

    func testColourHelpers() {
        XCTAssertEqual(PresetColour.rgba(UIColor(red: 0xD9 / 255.0, green: 0x43 / 255.0, blue: 0x2B / 255.0, alpha: 1)), vermilion)
        XCTAssertEqual(PresetColour.rgba(UIColor(white: 1, alpha: 0.5)), RGBA(255, 255, 255, 128))
        XCTAssertEqual(PresetColour.rgbHex(RGBA(0x12, 0xAB, 0xEF, 0x40)), "#12ABEF")
        XCTAssertEqual(PresetColour.name(vermilion), NibInk.vermilion.rawValue.capitalized)
        XCTAssertTrue(PresetColour.needsRing(PresetColour.rgba(NibInk.chalk), dark: false))
        XCTAssertTrue(PresetColour.needsRing(RGBA(0x05, 0x05, 0x05), dark: true))
        XCTAssertFalse(PresetColour.needsRing(vermilion, dark: true))
        XCTAssertEqual(PresetColour.palette(for: "highlighter").count, 6)
        XCTAssertEqual(PresetColour.palette(for: "pen").count, 12)
        XCTAssertEqual(try PresetRules.colour("#FFE45C", tool: "highlighter").a, RGBA.highlighterAlpha)
        XCTAssertEqual(try PresetRules.colour("#FFE45C", tool: "tape").a, 255)
    }

    /// The add-pattern path: preset.addSwatch, then preset.setSwatch at the old slot count.
    func testAddingATapePatternAddsASlotThatCarriesIt() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        h.app.content.tapePatterns.register(TapePatternDescriptor(id: "builtin.dots", title: "Dots", owner: "test") {
            Fixtures.pngData
        })
        let before = presets(h, "tape")
        let calls = ColourEditor.patternCalls(tool: "tape", slot: nil, count: before.swatches.count, hex: before.color.hex,
                                              pattern: "builtin.dots")
        let ok = await PresetActions.run(h.app, session: h.session, calls).value
        XCTAssertTrue(ok)
        let after = presets(h, "tape")
        XCTAssertEqual(after.swatches.count, before.swatches.count + 1)
        XCTAssertEqual(after.selectedSwatch, before.swatches.count, "the new slot is selected")
        XCTAssertEqual(after.swatches.last?.pattern, PresetSwatch.tapePatternRef(id: "builtin.dots"))
        XCTAssertEqual(after.swatches.last?.color, before.color)
        XCTAssertEqual(Array(after.swatches.prefix(before.swatches.count)), before.swatches, "the other slots are untouched")

        let unknown = ColourEditor.patternCalls(tool: "tape", slot: 0, count: after.swatches.count, hex: "#FFFFFF",
                                                pattern: "nope")
        let failed = await PresetActions.run(h.app, session: h.session, unknown).value
        XCTAssertFalse(failed, "a failed command reports false")
        XCTAssertEqual(presets(h, "tape"), after)
    }

    func testColourChoiceReleasesNativePopoverAndKeepsSelectedInk() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let model = PresetMenuModel(app: h.app, session: h.session, tool: "pen")
        model.open(.colour(.slot(0)))
        let host = UIHostingController(rootView: PresetPopoverTestHost(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for _ in 0..<100 where scrollViews(host.view).isEmpty {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let scroll = try XCTUnwrap(scrollViews(host.view).first)
        XCTAssertTrue(scroll.isUserInteractionEnabled, "the open editor accepts colour choices")
        let original = presets(h, "pen")
        let choice = try XCTUnwrap(model.pick(vermilion))
        let succeeded = await choice.value
        XCTAssertTrue(succeeded)
        for _ in 0..<100 where scroll.isUserInteractionEnabled {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(model.popover)
        XCTAssertFalse(scroll.isUserInteractionEnabled, "retained native popover content must release canvas input")
        XCTAssertTrue(scroll.accessibilityElementsHidden)
        XCTAssertFalse(scroll.isScrollEnabled, "layout must not reactivate the closed scroll host")
        let changed = presets(h, "pen")
        XCTAssertEqual(changed.color, vermilion, "the next stroke reads the edited selected slot")
        XCTAssertEqual(changed.selectedSwatch, original.selectedSwatch)
        XCTAssertEqual(changed.swatches.count, original.swatches.count)
        XCTAssertEqual(changed.widths, original.widths)

        model.open(.colour(.slot(1)))
        for _ in 0..<100 where !scroll.isUserInteractionEnabled || !scroll.isScrollEnabled {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(scroll.isUserInteractionEnabled, "opening another slot restores its controls")
        XCTAssertTrue(scroll.isScrollEnabled)
    }

    func testCustomPickerClosesPopoverBeforePresentationAndRetainsEachWindowDelegate() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let navigator = PresetTestNavigator(session: h.session)
        h.app.ui.activeNavigator = navigator
        let model = PresetMenuModel(app: h.app, session: h.session, tool: "pen")
        model.open(.colour(.slot(0)))
        let initial = model.editedSwatch.color
        navigator.onPresent = { _ in
            XCTAssertNil(model.popover, "the popover must give up modal input before presenting UIKit")
            XCTAssertFalse(model.makePopover().isPresented.wrappedValue)
        }
        model.openPicker()
        let first = try XCTUnwrap(navigator.presented.last as? UIColorPickerViewController)
        XCTAssertEqual(PresetColour.rgba(first.selectedColor), initial)
        XCTAssertTrue(first.supportsAlpha)
        XCTAssertEqual(first.sheetPresentationController?.selectedDetentIdentifier, .large)

        // A second scene can show its picker while the first scene's remains open.
        let otherSession = EditorSession()
        h.app.services.sessions.add(otherSession)
        let otherNavigator = PresetTestNavigator(session: otherSession)
        h.app.ui.activeNavigator = otherNavigator
        let other = PresetMenuModel(app: h.app, session: otherSession, tool: "highlighter")
        other.open(.colour(.slot(0)))
        other.openPicker()
        let second = try XCTUnwrap(otherNavigator.presented.last as? UIColorPickerViewController)
        XCTAssertFalse(second.supportsAlpha)
        let firstDelegate = try XCTUnwrap(first.delegate as? SystemColourPicker,
                                         "another window must not release the first picker's weak delegate")
        XCTAssertFalse(first.delegate === second.delegate)
        let custom = try XCTUnwrap(RGBA(hex: "#D03080"))
        firstDelegate.colorPickerViewController(first, didSelect: PresetColour.uiColor(custom), continuously: false)
        for _ in 0..<100 where presets(h, "pen").color != custom {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(presets(h, "pen").color, custom)
        XCTAssertEqual(presets(h, "highlighter"), ToolPresets.defaults(for: "highlighter"))
        await assertInvalid(h, "preset.setSwatch", ["tool": "pen", "index": 0, "color": "#ZZZZZZ"], path: "$.color")
        XCTAssertEqual(presets(h, "pen").color, custom)
    }

    func testCustomPickerUsesNativeControllerAndFullSizePresentation() throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let navigator = PresetTestNavigator(session: h.session)
        h.app.ui.activeNavigator = navigator
        let model = PresetMenuModel(app: h.app, session: h.session, tool: "pen")
        model.open(.colour(.slot(0)))
        model.openPicker()
        let picker = try XCTUnwrap(navigator.presented.last as? UIColorPickerViewController)
        // ARCHITECTURE §15: this target runs without UIApplication. Verify the native
        // controller and presentation contract here; InkUITests exercises its actual
        // Grid/Spectrum/Sliders interface in the app, including valid and invalid HEX.
        XCTAssertEqual(ObjectIdentifier(type(of: picker)), ObjectIdentifier(type(of: UIColorPickerViewController())),
                       "retain the delegate without substituting a feature subclass for UIKit's picker")
        XCTAssertEqual(picker.modalPresentationStyle, .formSheet)
        let sheet = try XCTUnwrap(picker.sheetPresentationController)
        XCTAssertEqual(sheet.detents.map(\.identifier), [.medium, .large])
        XCTAssertEqual(sheet.selectedDetentIdentifier, .large)
        XCTAssertTrue(picker.presentationController?.delegate === picker.delegate)
        XCTAssertEqual(navigator.presented.count, 1)
    }

    func testPickerCloseAndSwipeCommitOnlyOnce() {
        let picker = UIColorPickerViewController()
        let presentation = UIPresentationController(presentedViewController: picker, presenting: nil)
        var picks: [RGBA] = []
        let coordinator = SystemColourPicker(initial: .black, commitsOnFinishOnly: true) { picks.append($0) }
        coordinator.colorPickerViewController(picker, didSelect: PresetColour.uiColor(vermilion), continuously: true)
        coordinator.presentationControllerDidDismiss(presentation)
        XCTAssertEqual(picks, [vermilion], "a swipe must not lose the new colour")
        coordinator.colorPickerViewControllerDidFinish(picker)
        coordinator.colorPickerViewController(picker, didSelect: .blue, continuously: false)
        coordinator.presentationControllerDidDismiss(presentation)
        XCTAssertEqual(picks, [vermilion], "late delegate callbacks cannot add a second swatch")

        let closed = SystemColourPicker(initial: .black, commitsOnFinishOnly: true) { picks.append($0) }
        closed.colorPickerViewController(picker, didSelect: PresetColour.uiColor(vermilion), continuously: true)
        closed.colorPickerViewControllerDidFinish(picker)
        closed.presentationControllerDidDismiss(presentation)
        XCTAssertEqual(picks, [vermilion, vermilion], "Close followed by presentation dismissal also commits once")
    }

    func testNativePickerOwnsItsDelegateOnlyForItsLifetime() throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let navigator = PresetTestNavigator(session: h.session)
        h.app.ui.activeNavigator = navigator
        weak var delegate: SystemColourPicker?
        try autoreleasepool {
            SystemColourPicker.present(title: "Pen Colour", initial: .black, supportsAlpha: true,
                                       commitsOnFinishOnly: false, app: h.app, session: h.session) { _ in }
            let picker = try XCTUnwrap(navigator.presented.last as? UIColorPickerViewController)
            delegate = try XCTUnwrap(picker.delegate as? SystemColourPicker)
            navigator.presented.removeAll()
            XCTAssertNotNil(delegate, "the native picker must retain its otherwise weak delegate")
        }
        XCTAssertNil(delegate, "releasing the picker must release its window-specific coordinator")
    }

    /// A slot commits every settled choice; a new slot commits once, when the picker closes; an unchanged colour never.
    func testSystemColourPickerCommitRules() {
        let vc = UIColorPickerViewController()
        let blue = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
        let red = UIColor(red: 1, green: 0, blue: 0, alpha: 1)

        var slotPicks: [RGBA] = []
        let slot = SystemColourPicker(initial: vermilion, commitsOnFinishOnly: false) { slotPicks.append($0) }
        slot.colorPickerViewController(vc, didSelect: PresetColour.uiColor(vermilion), continuously: false)
        XCTAssertEqual(slotPicks, [], "the colour it opened with is not a change")
        slot.colorPickerViewController(vc, didSelect: blue, continuously: true)
        XCTAssertEqual(slotPicks, [], "a drag in progress commits nothing")
        slot.colorPickerViewController(vc, didSelect: blue, continuously: false)
        XCTAssertEqual(slotPicks, [RGBA(0, 0, 255)])
        slot.colorPickerViewController(vc, didSelect: red, continuously: false)
        XCTAssertEqual(slotPicks, [RGBA(0, 0, 255), RGBA(255, 0, 0)])
        slot.colorPickerViewControllerDidFinish(vc)
        XCTAssertEqual(slotPicks.count, 2, "closing on the committed colour adds nothing")

        var addPicks: [RGBA] = []
        let add = SystemColourPicker(initial: vermilion, commitsOnFinishOnly: true) { addPicks.append($0) }
        add.colorPickerViewController(vc, didSelect: blue, continuously: false)
        add.colorPickerViewController(vc, didSelect: red, continuously: false)
        XCTAssertEqual(addPicks, [], "adding waits for the picker to close")
        add.colorPickerViewControllerDidFinish(vc)
        XCTAssertEqual(addPicks, [RGBA(255, 0, 0)])

        var untouchedPicks: [RGBA] = []
        let untouched = SystemColourPicker(initial: vermilion, commitsOnFinishOnly: true) { untouchedPicks.append($0) }
        untouched.colorPickerViewController(vc, didSelect: PresetColour.uiColor(vermilion), continuously: false)
        untouched.colorPickerViewControllerDidFinish(vc)
        XCTAssertEqual(untouchedPicks, [], "closing without a change adds nothing")
    }

    // MARK: Eyedropper

    func testPixelReadIsTopLeftOrigin() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            UIColor.green.setFill(); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
            UIColor.white.setFill(); ctx.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        }.cgImage!
        assertClose(EyedropperSampler.colour(in: image, x: 0, y: 0), RGBA(255, 0, 0))
        assertClose(EyedropperSampler.colour(in: image, x: 1, y: 0), RGBA(0, 255, 0))
        assertClose(EyedropperSampler.colour(in: image, x: 0, y: 1), RGBA(0, 0, 255))
        assertClose(EyedropperSampler.colour(in: image, x: 1, y: 1), RGBA(255, 255, 255))
        let px = EyedropperSampler.pixel(for: Point(15, 25), width: 40, height: 40, region: Rect(x: 10, y: 20, width: 20, height: 20))
        XCTAssertEqual(px.x, 10)
        XCTAssertEqual(px.y, 10)
    }

    /// Acceptance: the loupe returns the rendered colour at a point on the fixture page.
    func testLoupeReturnsTheRenderedColourOnTheFixturePage() async throws {
        let blank = FakeRenderer()
        let paper = try await EyedropperSampler.sample(blank, doc: Fixtures.docID, page: Fixtures.page1, at: Point(300, 400), scale: 10)
        assertClose(paper.colour, RGBA(255, 255, 255))
        let asked = try XCTUnwrap(blank.requests.last)
        XCTAssertEqual(asked.region, Rect(x: 290, y: 390, width: EyedropperSampler.span, height: EyedropperSampler.span))
        XCTAssertTrue(asked.background, "PDF and template backgrounds are part of the sample")

        let painted = PaintedRenderer(rect: Rect(x: 100, y: 100, width: 50, height: 50),
                                      colour: UIColor(red: 0xD9 / 255.0, green: 0x43 / 255.0, blue: 0x2B / 255.0, alpha: 1))
        for (point, expected) in [(Point(120, 120), vermilion), (Point(100.2, 149.8), vermilion),
                                  (Point(99.5, 120), RGBA(255, 255, 255)), (Point(120, 150.5), RGBA(255, 255, 255))] {
            let s = try await EyedropperSampler.sample(painted, doc: Fixtures.docID, page: Fixtures.page1, at: point, scale: 10)
            assertClose(s.colour, expected)
        }
        // A renderer that answers at another scale (long-edge cap) still maps the point to the right pixel.
        let capped = PaintedRenderer(rect: Rect(x: 100, y: 100, width: 50, height: 50), colour: .blue, scaleFactor: 0.5)
        let edge = try await EyedropperSampler.sample(capped, doc: Fixtures.docID, page: Fixtures.page1, at: Point(101, 101), scale: 10)
        assertClose(edge.colour, RGBA(0, 0, 255))
    }

    func testEyedropperSetsTheSlotToTheColourUnderTheFinger() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        h.app.services.renderer = PaintedRenderer(rect: Rect(x: 100, y: 100, width: 50, height: 50),
                                                  colour: UIColor(red: 0xD9 / 255.0, green: 0x43 / 255.0, blue: 0x2B / 255.0, alpha: 1))
        let host = FakeCanvasHost(h)
        let eyedropper = EyedropperAttachment()
        eyedropper.attach(to: host)
        defer { eyedropper.detach(from: host) }
        XCTAssertTrue(EyedropperAttachment.canPick(session: h.session, app: h.app))
        XCTAssertFalse(eyedropper.hitTest(.zero, host: host), "closed: touches go to the tool")

        XCTAssertTrue(EyedropperAttachment.begin(.init(tool: "pen", target: .slot(1)), session: h.session))
        XCTAssertTrue(eyedropper.hitTest(.zero, host: host), "open: it claims the next touch")
        eyedropper.touchesBegan(CanvasSample(page: Fixtures.page1, location: Point(20, 20)), host: host)
        eyedropper.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(110, 110))], host: host)
        eyedropper.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(125, 125)), host: host)
        await eyedropper.commitTask?.value
        assertClose(presets(h, "pen").swatches[1].color, vermilion)
        XCTAssertFalse(eyedropper.hitTest(.zero, host: host), "one pick closes it")

        // Adding from the page, then a tool switch closes an open eyedropper without picking.
        XCTAssertTrue(EyedropperAttachment.begin(.init(tool: "highlighter", target: .add), session: h.session))
        eyedropper.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(130, 130)), host: host)
        await eyedropper.commitTask?.value
        XCTAssertEqual(presets(h, "highlighter").swatches.count, 4)
        XCTAssertEqual(presets(h, "highlighter").color.a, RGBA.highlighterAlpha)
        XCTAssertTrue(EyedropperAttachment.begin(.init(tool: "pen", target: .add), session: h.session))
        h.session.tool = "eraser"
        XCTAssertFalse(eyedropper.hitTest(.zero, host: host))
        XCTAssertEqual(presets(h, "pen").swatches.count, 3)
    }
}
