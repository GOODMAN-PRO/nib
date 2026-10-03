import XCTest
import SwiftUI
import UIKit
import NibContracts
@testable import NibDesign

@MainActor
final class InkControlTouchTests: XCTestCase {
    func testWidthAndColourCellsHaveIndependentNativeTouchTargets() async throws {
        var selectedWidth = -1
        var selectedColour: String?
        let inks = NibInk.allCases.prefix(3).map { NibSwatch(ink: $0) }
        let host = UIHostingController(rootView: VStack {
            HStack(spacing: 0) {
                ForEach(0..<3) { index in
                    NibWidthPresetButton(diameter: 8, isSelected: false, label: "Width \(index)") {
                        selectedWidth = index
                    }
                }
            }
            NibSwatchGrid(swatches: inks, selection: Binding(get: { selectedColour }, set: { selectedColour = $0 }))
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func targets(_ view: UIView) -> [NibActionTapRecognizer] {
            (view.gestureRecognizers ?? []).compactMap { $0 as? NibActionTapRecognizer }
                + view.subviews.flatMap(targets)
        }
        let actions = targets(window)
        func gestureTree(_ view: UIView) -> String {
            "\(type(of: view)): \(view.gestureRecognizers?.map { String(describing: type(of: $0)) } ?? [])\n"
                + view.subviews.map(gestureTree).joined()
        }
        XCTAssertEqual(actions.count, 6, gestureTree(window))
        var widths = Set<Int>()
        var colours = Set<String>()
        for action in actions {
            let target = try XCTUnwrap(action.view)
            let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: window)
            let hit = try XCTUnwrap(window.hitTest(point, with: nil))
            XCTAssertTrue(hit.isDescendant(of: target))
            let beforeWidth = selectedWidth, beforeColour = selectedColour
            action.activate()
            let changedWidth = beforeWidth != selectedWidth
            let changedColour = beforeColour != selectedColour
            XCTAssertNotEqual(changedWidth, changedColour, "One tap changes exactly one preset attribute")
            if changedWidth { widths.insert(selectedWidth) }
            if changedColour, let selectedColour { colours.insert(selectedColour) }
        }
        XCTAssertEqual(widths, [0, 1, 2])
        XCTAssertEqual(colours, Set(inks.map(\.id)))
    }
}
