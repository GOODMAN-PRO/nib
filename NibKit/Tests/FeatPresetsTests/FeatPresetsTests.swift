import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatPresets

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
            XCTAssertEqual(h.app.ui.toolMenus.get(tool)?.owner, FeatPresetsFeature.id, tool)
        }
        XCTAssertNotNil(h.app.ui.canvasAttachments.get(EyedropperAttachment.descriptorID))
        let keys = h.app.content.keyCommands.all.filter { $0.owner == FeatPresetsFeature.id }
        XCTAssertEqual(Set(keys.map { $0.shortcut.key }), Set(["[", "]", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]))
        XCTAssertTrue(keys.allSatisfy { $0.command == "preset.select" && $0.scope == .canvas })
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

    func testMenuRendersInEveryMode() {
        let h = Harness(features: [FeatPresetsFeature.self])
        let modes: [PresetBarMode] = [.width(1), .colour(.slot(0)), .colour(.add), .arrange]
        for tool in NibSettings.presetTools {
            for mode in modes {
                let host = UIHostingController(rootView: ToolPresetMenu(app: h.app, session: h.session, tool: tool, mode: mode))
                let size = host.sizeThatFits(in: CGSize(width: 1194, height: 834))
                XCTAssertGreaterThanOrEqual(size.height, 44, "\(tool) \(mode)")
                XCTAssertGreaterThan(size.width, 3 * 44, "\(tool) \(mode)")
            }
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
        XCTAssertEqual(presets(h, "highlighter").swatches[1].color, RGBA(0x86, 0xE3, 0xAE, PresetRules.highlighterAlpha),
                       "a highlighter colour without alpha gets the highlighter opacity")
        try await h.run("preset.setSwatch", ["tool": "pen", "index": 0, "color": "#D9432B80"])
        XCTAssertEqual(presets(h, "pen").swatches[0].color, RGBA(0xD9, 0x43, 0x2B, 0x80))
        await assertInvalid(h, "preset.setSwatch", ["tool": "pen", "index": 0, "color": "#12"], path: "$.color")
        await assertInvalid(h, "preset.setSwatch", ["tool": "pen", "index": 0, "color": "#FFFFFF", "pattern": "dots"],
                            path: "$.pattern")

        h.app.content.tapePatterns.register(TapePatternDescriptor(id: "builtin.dots", title: "Dots", owner: "test") {
            Fixtures.pngData
        })
        try await h.run("preset.setSwatch", ["tool": "tape", "index": 2, "color": "#F4C430", "pattern": "builtin.dots"])
        XCTAssertEqual(presets(h, "tape").swatches[2].pattern, AssetRef("builtin.dots"))
        try await h.run("preset.setSwatch", ["tool": "tape", "index": 2, "color": "#8EC5FF"])
        XCTAssertEqual(presets(h, "tape").swatches[2].pattern, AssetRef("builtin.dots"), "omitting the pattern keeps it")
        try await h.run("preset.setSwatch", ["tool": "tape", "index": 2, "color": "#8EC5FF", "pattern": ""])
        XCTAssertNil(presets(h, "tape").swatches[2].pattern)
        do {
            try await h.run("preset.setSwatch", ["tool": "tape", "index": 2, "color": "#8EC5FF", "pattern": "nope"])
            XCTFail("an unknown pattern should fail")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
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
            XCTAssertLessThan(WidthScale.slotLineWidth(range.lowerBound, tool: tool), WidthScale.slotLineWidth(range.upperBound, tool: tool))
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
        XCTAssertEqual(try PresetRules.colour("#FFE45C", tool: "highlighter").a, PresetRules.highlighterAlpha)
        XCTAssertEqual(try PresetRules.colour("#FFE45C", tool: "tape").a, 255)
    }

    /// The add-pattern path: preset.addSwatch, then preset.setSwatch at the old slot count.
    func testAddingATapePatternAddsASlotThatCarriesIt() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        h.app.content.tapePatterns.register(TapePatternDescriptor(id: "builtin.dots", title: "Dots", owner: "test") {
            Fixtures.pngData
        })
        let before = presets(h, "tape")
        let calls = ColourEditorRow.patternCalls(tool: "tape", slot: nil, count: before.swatches.count, hex: before.color.hex,
                                                 pattern: "builtin.dots")
        let ok = await PresetActions.run(h.app, session: h.session, calls).value
        XCTAssertTrue(ok)
        let after = presets(h, "tape")
        XCTAssertEqual(after.swatches.count, before.swatches.count + 1)
        XCTAssertEqual(after.selectedSwatch, before.swatches.count, "the new slot is selected")
        XCTAssertEqual(after.swatches.last?.pattern, AssetRef("builtin.dots"))
        XCTAssertEqual(after.swatches.last?.color, before.color)
        XCTAssertEqual(Array(after.swatches.prefix(before.swatches.count)), before.swatches, "the other slots are untouched")

        let unknown = ColourEditorRow.patternCalls(tool: "tape", slot: 0, count: after.swatches.count, hex: "#FFFFFF",
                                                   pattern: "nope")
        let failed = await PresetActions.run(h.app, session: h.session, unknown).value
        XCTAssertFalse(failed, "a failed command reports false")
        XCTAssertEqual(presets(h, "tape"), after)
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
        XCTAssertEqual(presets(h, "highlighter").color.a, PresetRules.highlighterAlpha)
        XCTAssertTrue(EyedropperAttachment.begin(.init(tool: "pen", target: .add), session: h.session))
        h.session.tool = "eraser"
        XCTAssertFalse(eyedropper.hitTest(.zero, host: host))
        XCTAssertEqual(presets(h, "pen").swatches.count, 3)
    }
}
