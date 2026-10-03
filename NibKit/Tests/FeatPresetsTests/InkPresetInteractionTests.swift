import XCTest
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
}
