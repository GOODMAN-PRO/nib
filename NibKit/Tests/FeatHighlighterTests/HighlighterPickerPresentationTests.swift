import XCTest
import UIKit
@testable import FeatHighlighter

@MainActor
final class HighlighterPickerPresentationTests: XCTestCase {
    func testConcretePickerRetainsDelegateAndCommitsFinalColourOnce() throws {
        var colours: [UIColor] = []
        var finishes = 0
        let picker = SystemColourPicker(initial: .yellow, onPick: { colours.append($0) },
                                        onDone: { finishes += 1 }).makePicker()
        XCTAssertTrue(type(of: picker) == UIColorPickerViewController.self)
        XCTAssertEqual(picker.modalPresentationStyle, .formSheet)
        XCTAssertFalse(picker.supportsAlpha)
        let delegate = try XCTUnwrap(picker.delegate as? SystemColourPicker.Coordinator)
        XCTAssertTrue(picker.presentationController?.delegate === delegate)
        picker.selectedColor = .magenta
        delegate.colorPickerViewControllerDidSelectColor(picker)
        delegate.colorPickerViewControllerDidFinish(picker)
        delegate.colorPickerViewControllerDidFinish(picker)
        XCTAssertEqual(colours, [.magenta])
        XCTAssertEqual(finishes, 1)
    }
}
