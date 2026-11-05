import XCTest
import SwiftUI
@testable import NibDesign

@MainActor
final class BudInteractionRegressionTests: XCTestCase {
    func testOpenBudOwnersDistinguishPaletteSlotsFromNavigation() {
        let field = DropletField()
        field.mode = .off
        field.setRest("palette", CGRect(x: 20, y: 100, width: 469, height: 56), style: .bar)
        field.setLocalAnchor("palette.pen", owner: "palette", rect: CGRect(x: 0, y: 0, width: 44, height: 44))
        field.setWorldAnchor("chrome.share", CGRect(x: 600, y: 20, width: 44, height: 44))
        field.setRest("menu", CGRect(x: 20, y: 180, width: 312, height: 400), style: .popover)
        field.setBud("menu", source: "palette.pen", presented: true, instant: true, dismiss: {})
        XCTAssertEqual(field.openBudOwners, ["palette"])
        XCTAssertTrue(field.hasOpenBud)
        field.setBud("menu", source: "palette.pen", presented: false, instant: true, dismiss: {})
        XCTAssertTrue(field.openBudOwners.isEmpty)
        XCTAssertFalse(field.hasOpenBud)
        field.setBud("menu", source: "chrome.share", presented: true, instant: true, dismiss: {})
        XCTAssertEqual(field.openBudOwners, ["chrome.share"])
        XCTAssertTrue(field.hasOpenBud, "Navigation buds still own the outside-tap shield")
        field.setActive(false)
    }

    func testDismissalReleasesInputBeforePresentationCatchesUp() {
        let field = DropletField()
        field.setRest("source", CGRect(x: 20, y: 20, width: 44, height: 44), style: .bar)
        field.setRest("menu", CGRect(x: 20, y: 80, width: 312, height: 400), style: .popover)
        field.setBud("menu", source: "source", presented: true, instant: true, dismiss: {})
        let node = field.node("menu")
        var requested = true
        let menu = AttachedDroplet(content: EmptyView(), id: "menu", style: .popover,
            managesDrag: false, dragScale: 1, bondsWith: nil, onDrag: nil,
            field: field, node: node, namespace: nil,
            bud: NibBudRequest(source: "source", isPresented: Binding(get: { requested }, set: { requested = $0 }),
                               instant: false))
        XCTAssertTrue(menu.acceptsInteraction)
        let visible = node.presentation
        requested = false
        XCTAssertFalse(menu.acceptsInteraction, "The next tap must reach the control beneath a closing menu")
        XCTAssertEqual(node.presentation, visible, "Input dismissal must not truncate the visual animation")
        field.setBud("menu", source: "source", presented: false, instant: false, dismiss: {})
        XCTAssertFalse(menu.acceptsInteraction)
        requested = true
        field.setBud("menu", source: "source", presented: true, instant: true, dismiss: {})
        XCTAssertTrue(menu.acceptsInteraction, "The retained menu must remain usable when reopened")
    }
}
