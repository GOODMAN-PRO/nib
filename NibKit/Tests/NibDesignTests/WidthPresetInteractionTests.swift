import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class WidthPresetInteractionTests: XCTestCase {
    func testSlotIdentitySurvivesSelectionAndEditedValues() {
        for selected in [false, true] {
            for value in ["0.42 millimetres, 1.2 points", "0.71 millimetres, 2.0 points, Dashed"] {
                let buttons = (0..<3).map { index in
                    NibWidthPresetButton(diameter: NibMetrics.widthPresetDot(index), isSelected: selected,
                                         label: "Thickness", slotID: "width.pen.\(index)", value: value) {}
                }
                XCTAssertEqual(Set(buttons.map(\.accessibilitySlotValue)).count, buttons.count)
                for (index, button) in buttons.enumerated() {
                    XCTAssertEqual(button.accessibilitySlotValue, "width.pen.\(index); \(value)")
                }
            }
        }
        let legacy = NibWidthPresetButton(diameter: NibMetrics.widthPresetDot(0), isSelected: false, label: "Width") {}
        XCTAssertEqual(legacy.accessibilitySlotValue, "", "Existing callers need no slot metadata")
    }

    func testAdjacentCellsOwnOnlyTheir44By40BoundsAndInvokeTheirOwnAction() async throws {
        var received: [Int] = []
        func row(selected: Int, enabled: Bool) -> some View {
            HStack(spacing: .zero) {
                ForEach(0..<3) { index in
                    NibWidthPresetButton(diameter: NibMetrics.widthPresetDot(index), isSelected: index == selected,
                                         label: "Thickness", slotID: "width.pen.\(index)") { received.append(index) }
                        .accessibilityIdentifier("cmd.preset.select")
                }
            }
            .disabled(!enabled)
            // A wide host must not make any of the native cell targets expand.
            .frame(maxWidth: .infinity)
        }
        func taps(_ view: UIView) -> [NibActionTapRecognizer] {
            (view.gestureRecognizers ?? []).compactMap { $0 as? NibActionTapRecognizer }
                + view.subviews.flatMap(taps)
        }
        let host = UIHostingController(rootView: row(selected: 0, enabled: true))
        let size = CGSize(width: NibMetrics.hitTarget * CGFloat(NibMetrics.widthPresetDots.count) + NibSpacing.x4,
                          height: NibMetrics.barHeight + NibSpacing.x4)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        for enabled in [true, false, true] {
            for selected in 0..<3 {
                host.rootView = row(selected: selected, enabled: enabled)
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
                let actions = taps(host.view).sorted {
                    ($0.view?.convert(CGPoint.zero, to: host.view).x ?? 0)
                        < ($1.view?.convert(CGPoint.zero, to: host.view).x ?? 0)
                }
                XCTAssertEqual(actions.count, 3)
                var previous: CGRect?
                for (index, tap) in actions.enumerated() {
                    let target = try XCTUnwrap(tap.view)
                    let frame = target.convert(target.bounds, to: host.view)
                    XCTAssertEqual(frame.width, NibMetrics.hitTarget, accuracy: 0.01)
                    XCTAssertEqual(frame.height, NibMetrics.hudHeight, accuracy: 0.01)
                    if let previous { XCTAssertEqual(previous.maxX, frame.minX, accuracy: 0.01) }
                    previous = frame
                    XCTAssertEqual(tap.isEnabled, enabled)
                    guard enabled else { continue }
                    // Probe both sides as well as the centre, including the selected cell.
                    for x in [frame.minX + NibStroke.hairline, frame.midX, frame.maxX - NibStroke.hairline] {
                        let hit = try XCTUnwrap(host.view.hitTest(CGPoint(x: x, y: frame.midY), with: nil))
                        XCTAssertTrue(hit.isDescendant(of: target), "Slot \(index) must own its full cell")
                    }
                    XCTAssertFalse(target.point(inside: CGPoint(x: -NibStroke.hairline, y: target.bounds.midY), with: nil))
                    XCTAssertFalse(target.point(inside: CGPoint(x: target.bounds.maxX + NibStroke.hairline,
                                                                y: target.bounds.midY), with: nil))
                    let count = received.count
                    tap.activate()
                    XCTAssertEqual(received.count, count + 1)
                    XCTAssertEqual(received.last, index)
                }
            }
        }
    }
}
