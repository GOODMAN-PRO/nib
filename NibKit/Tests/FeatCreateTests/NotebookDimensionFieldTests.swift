import XCTest
import UIKit
@testable import FeatCreate

@MainActor
final class NotebookDimensionFieldTests: XCTestCase {
    func testEditingPreservesDecimalAndSelectionAcrossModelRefreshes() {
        let field = NotebookDimensionTextField(locale: Locale(identifier: "en_US"))
        field.setValue(210)
        field.textFieldDidBeginEditing(field)
        field.text = "100."
        let position = field.position(from: field.beginningOfDocument, offset: 2)!
        field.selectedTextRange = field.textRange(from: position, to: position)
        var values: [Double] = []
        field.onValueChanged = { values.append($0) }
        field.changed()
        field.setValue(100)
        XCTAssertEqual(values, [100])
        XCTAssertEqual(field.text, "100.")
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start), 2)
    }

    func testReplacingNativeSelectionReplacesEveryOldDigit() {
        let field = NotebookDimensionTextField(locale: Locale(identifier: "en_US"))
        field.setValue(210)
        field.textFieldDidBeginEditing(field)
        // The hostless package runner has no UIApplication to dispatch Select
        // All. Supply its native range; CI exercises the focus/tap event path.
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("100")
        var value = 0.0
        field.onValueChanged = { value = $0 }
        field.changed()
        XCTAssertEqual(field.text, "100")
        XCTAssertEqual(value, 100)
    }

    func testLocaleDecimalAndInvalidBufferReachValidation() {
        let field = NotebookDimensionTextField(locale: Locale(identifier: "fr_FR"))
        field.setValue(25.4)
        XCTAssertEqual(field.text, "25,4")
        field.textFieldDidBeginEditing(field)
        var value = 0.0
        field.onValueChanged = { value = $0 }
        for invalid in ["", "-", "abc", "12,3,4"] {
            field.text = invalid
            field.changed()
            XCTAssertTrue(value.isNaN, "Invalid input must not reuse the previous valid size")
        }
        field.text = "100,5"
        field.changed()
        XCTAssertEqual(value, 100.5)
        field.textFieldDidEndEditing(field)
        field.setValue(150.5)
        XCTAssertEqual(field.text, "150,5")
        XCTAssertFalse((field.inputAccessoryView as? UIToolbar)?.items?.isEmpty ?? true,
                       "The decimal keyboard must offer Done")
    }

    func testLocalizedKeyboardDigitsRemainEditable() {
        let field = NotebookDimensionTextField(locale: Locale(identifier: "ar_EG"))
        var value = 0.0
        field.onValueChanged = { value = $0 }
        field.text = "١٠٠٫٥"
        field.changed()
        XCTAssertEqual(value, 100.5)
    }
}
