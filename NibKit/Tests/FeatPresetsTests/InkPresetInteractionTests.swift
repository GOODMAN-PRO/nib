import XCTest
import UIKit
import NibDesign
import NibContracts
import NibTesting
@testable import FeatPresets

@MainActor
final class InkPresetInteractionTests: XCTestCase {
    func testRebuiltBarSharesDragOwnershipOnlyWithinItsWindowAndTool() throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let menus = PresetMenus(app: h.app)
        let source = try XCTUnwrap(menus.model("pen", session: h.session))
        source.beginArranging()
        source.draggedSwatch = 0
        let destination = try XCTUnwrap(menus.model("pen", session: h.session))
        XCTAssertTrue(source === destination)
        XCTAssertEqual(destination.draggedSwatch, 0)
        XCTAssertNil(menus.model("highlighter", session: h.session)?.draggedSwatch)
        XCTAssertNil(menus.model("pen", session: EditorSession())?.draggedSwatch)
        destination.endArranging()
        XCTAssertNil(source.draggedSwatch, "Finishing or cancelling arrangement releases the drag")
        source.beginArranging()
        XCTAssertNil(source.draggedSwatch, "A new drag session must not inherit stale ownership")
    }

    func testNativeDragMovesSelectedColourOnceAndRejectsForeignOrStaleDrags() async throws {
        let h = Harness(features: [FeatPresetsFeature.self])
        let model = PresetMenuModel(app: h.app, session: h.session, tool: "pen")
        let other = PresetMenuModel(app: h.app, session: h.session, tool: "highlighter")
        model.beginArranging()
        other.beginArranging()
        let before = model.presets
        let source = PresetSwatchReorder(model: model, index: 0)
        let destination = PresetSwatchReorder(model: model, index: 2)
        model.draggedSwatch = 0
        other.draggedSwatch = 0
        XCTAssertFalse(destination.perform(PresetSwatchReorder(model: other, index: 0)))
        XCTAssertTrue(destination.perform(source))
        XCTAssertFalse(destination.perform(source), "A completed drag must not move the slot twice")
        for _ in 0..<200 where model.presets.swatches == before.swatches {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.presets.swatches, [before.swatches[1], before.swatches[2], before.swatches[0]])
        XCTAssertEqual(model.presets.swatches[model.presets.selectedSwatch], before.swatches[before.selectedSwatch])
        model.draggedSwatch = 0
        model.endArranging()
        XCTAssertFalse(destination.perform(source), "Closing the bar cancels its drag")
    }

    func testArrangementUsesNativeDragAndDropOnTheSwatchButton() {
        let h = Harness(features: [FeatPresetsFeature.self])
        let model = PresetMenuModel(app: h.app, session: h.session, tool: "pen")
        let button = PresetSwatchNativeButton()
        let swatch = PresetColour.swatch(model.presets.swatches[0].color, id: "test", name: "Black")
        button.configure(swatch: swatch, isSelected: false, menu: nil,
                         reorder: PresetSwatchReorder(model: model, index: 0), action: {})
        XCTAssertTrue(button.interactions.compactMap { $0 as? UIDragInteraction }.first?.isEnabled == true)
        XCTAssertTrue(button.interactions.contains { $0 is UIDropInteraction })
        XCTAssertEqual(button.accessibilityIdentifier, "cmd.preset.removeSwatch")
        button.configure(swatch: swatch, isSelected: true, menu: UIMenu(children: []), action: {})
        XCTAssertFalse(button.interactions.compactMap { $0 as? UIDragInteraction }.first?.isEnabled ?? true)
        XCTAssertEqual(button.accessibilityIdentifier, "cmd.preset.select")
    }

}
