import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class BudEscapeTests: XCTestCase {
    func testSheetThenTopmostBudThenCanvasEachConsumesOneEscape() {
        let field = DropletField()
        var lowerOpen = true
        var upperOpen = true
        let lower = bud("lower", field: field, presented: Binding(get: { lowerOpen }, set: { lowerOpen = $0 }))
        let upper = bud("upper", field: field, presented: Binding(get: { upperOpen }, set: { upperOpen = $0 }))
        defer { field.setActive(false) }
        let root = UIView()
        let canvas = NibEscapeCancellationView()
        let lowerOwner = NibEscapeCancellationView()
        let upperOwner = NibEscapeCancellationView()
        let sheet = NibEscapeCancellationView()
        var selection = true
        var sheetOpen = true
        var sheetEnabled = false
        canvas.onEscape = { selection = false; return true }
        lowerOwner.onEscape = { lower.cancelFromEscape() }
        upperOwner.onEscape = { upper.cancelFromEscape() }
        sheet.onEscape = {
            guard sheetOpen else { return false }
            if sheetEnabled { sheetOpen = false }
            return true
        }
        for owner in [canvas, lowerOwner, upperOwner, sheet] { root.addSubview(owner) }

        XCTAssertTrue(NibEscapeRouting.cancel(in: root))
        XCTAssertTrue(sheetOpen, "Disabled sheet cancellation blocks lower surfaces")
        sheetEnabled = true
        XCTAssertTrue(NibEscapeRouting.cancel(in: root))
        XCTAssertFalse(sheetOpen)
        XCTAssertTrue(upperOpen)
        XCTAssertTrue(lowerOpen)
        XCTAssertTrue(selection)
        XCTAssertTrue(NibEscapeRouting.cancel(in: root))
        XCTAssertFalse(upperOpen)
        XCTAssertTrue(lowerOpen)
        XCTAssertTrue(selection)
        XCTAssertTrue(NibEscapeRouting.cancel(in: root))
        XCTAssertFalse(lowerOpen, "A closing bud releases ownership before its view is removed")
        XCTAssertTrue(selection)
        XCTAssertTrue(NibEscapeRouting.cancel(in: root))
        XCTAssertFalse(selection)
    }

    func testOnlyPresentedModalBudsOwnEscape() {
        let field = DropletField()
        defer { field.setActive(false) }
        var open = true
        var writes = 0
        let binding = Binding(get: { open }, set: { open = $0; writes += 1 })
        let menu = bud("menu", field: field, presented: binding)
        var nonmodal = DropletStyle.popover
        nonmodal.modalWhenBudded = false
        let toast = bud("toast", field: field, presented: binding, style: nonmodal)
        XCTAssertFalse(toast.cancelFromEscape())
        XCTAssertTrue(open)
        XCTAssertTrue(menu.cancelFromEscape())
        XCTAssertFalse(open)
        XCTAssertFalse(menu.cancelFromEscape())
        XCTAssertEqual(writes, 1)
        open = true
        XCTAssertTrue(menu.cancelFromEscape(), "Reopening restores ownership")
        XCTAssertEqual(writes, 2)
    }

    func testAttachedBudRegistersItsBindingCancellationInTheViewTree() async throws {
        let field = DropletField()
        var open = true
        let menu = bud("menu", field: field, presented: Binding(get: { open }, set: { open = $0 }))
        let host = UIHostingController(rootView: menu)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; field.setActive(false) }
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(NibEscapeRouting.cancel(in: host.view))
        XCTAssertFalse(open)
        XCTAssertFalse(NibEscapeRouting.cancel(in: host.view), "No stale owner during retraction")
    }

    func testStackedAttachedBudHostsCancelFrontmostThenLower() async throws {
        let field = DropletField()
        var lowerOpen = true
        var upperOpen = true
        let lower = UIHostingController(rootView:
            bud("lower", field: field, presented: Binding(get: { lowerOpen }, set: { lowerOpen = $0 })))
        let upper = UIHostingController(rootView:
            bud("upper", field: field, presented: Binding(get: { upperOpen }, set: { upperOpen = $0 })))
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; field.setActive(false) }
        for host in [lower, upper] {
            root.addChild(host)
            host.view.frame = root.view.bounds
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
        }
        for _ in 0..<5 { root.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertTrue(NibEscapeRouting.cancel(in: root.view))
        XCTAssertFalse(upperOpen, "The frontmost real bud host owns the first Escape")
        XCTAssertTrue(lowerOpen)
        XCTAssertTrue(NibEscapeRouting.cancel(in: root.view))
        XCTAssertFalse(lowerOpen)
        XCTAssertFalse(NibEscapeRouting.cancel(in: root.view))
    }

    private func bud(_ id: String, field: DropletField, presented: Binding<Bool>,
                     style: DropletStyle = .popover) -> AttachedDroplet<Text> {
        field.mode = .off
        field.setRest("source", CGRect(x: 20, y: 20, width: 44, height: 44), style: .bar)
        field.setRest(id, CGRect(x: 20, y: 80, width: 312, height: 400), style: style)
        field.setBud(id, source: "source", presented: presented.wrappedValue, instant: true, dismiss: {})
        return AttachedDroplet(content: Text("Options"), id: id, style: style,
            managesDrag: false, dragScale: 1, bondsWith: nil, onDrag: nil,
            field: field, node: field.node(id), namespace: nil,
            bud: NibBudRequest(source: "source", isPresented: presented, instant: true))
    }
}
