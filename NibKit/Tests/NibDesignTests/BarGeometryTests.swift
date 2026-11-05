import XCTest
import UIKit
@testable import NibDesign

@MainActor
final class BarGeometryTests: XCTestCase {
    func testGeometryChangesAreScopedToTheRequestedBarAndContainerWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let otherWindow = UIWindow(frame: window.frame)
        let root = UIView(frame: window.bounds)
        window.addSubview(root)
        let marker = NibBarGeometryView()
        marker.id = "chrome.bar.trailing"
        root.addSubview(marker)
        let note = Notification(name: NibBarGeometry.didChange, object: marker)
        XCTAssertTrue(NibBarGeometry.isChange(note, for: "chrome.bar.trailing", in: root))
        XCTAssertFalse(NibBarGeometry.isChange(note, for: "chrome.bar.leading", in: root))
        XCTAssertFalse(NibBarGeometry.isChange(note, for: "chrome.bar.trailing", in: otherWindow))
        let sibling = UIView()
        window.addSubview(sibling)
        XCTAssertFalse(NibBarGeometry.isChange(note, for: "chrome.bar.trailing", in: sibling))
        marker.removeFromSuperview()
        XCTAssertFalse(NibBarGeometry.isChange(note, for: "chrome.bar.trailing", in: root))
        XCTAssertFalse(NibBarGeometry.isChange(Notification(name: NibBarGeometry.didChange),
                                              for: "chrome.bar.trailing", in: root))
    }
}
