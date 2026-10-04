import SwiftUI
import UIKit
import NibDesign

/// Keep an editing buffer independent of the numeric model. Formatting every
/// keystroke can move the insertion point (and discard a trailing decimal).
struct NotebookDimensionField: UIViewRepresentable {
    let label: String
    @Binding var value: Double
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> NotebookDimensionTextField {
        let field = NotebookDimensionTextField()
        field.onValueChanged = updateValue
        field.onFocusChanged = { isFocused = $0 }
        return field
    }

    func updateUIView(_ field: NotebookDimensionTextField, context: Context) {
        field.accessibilityLabel = label
        field.onValueChanged = updateValue
        field.onFocusChanged = { isFocused = $0 }
        field.setValue(value)
        field.wantsFocus = isFocused
        if isFocused && !field.isFirstResponder {
            // SwiftUI may request validation focus before the field is attached.
            DispatchQueue.main.async { [weak field] in
                guard let field, field.wantsFocus, field.window != nil else { return }
                field.becomeFirstResponder()
            }
        } else if !isFocused && field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    private func updateValue(_ next: Double) {
        guard value != next, !(value.isNaN && next.isNaN) else { return }
        value = next
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NotebookDimensionTextField,
                     context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? NibMetrics.hitTarget * 2,
               height: max(NibMetrics.hitTarget, uiView.font?.lineHeight ?? 0))
    }
}

@MainActor
final class NotebookDimensionTextField: UITextField, UITextFieldDelegate {
    var onValueChanged: (Double) -> Void = { _ in }
    var onFocusChanged: (Bool) -> Void = { _ in }
    var wantsFocus = false
    private let numberLocale: Locale
    private var editingBuffer = false

    init(locale: Locale = .current) {
        numberLocale = locale
        super.init(frame: .zero)
        delegate = self
        keyboardType = .decimalPad
        textAlignment = .right
        font = NibUIFont.body
        adjustsFontForContentSizeCategory = true
        autocorrectionType = .no
        spellCheckingType = .no
        addTarget(self, action: #selector(changed), for: .editingChanged)
        let toolbar = UIToolbar()
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace),
                         UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))]
        toolbar.sizeToFit()
        inputAccessoryView = toolbar
    }

    required init?(coder: NSCoder) { nil }

    func setValue(_ value: Double) {
        guard !editingBuffer else { return }
        let formatted = value.isFinite
            ? value.formatted(.number.locale(numberLocale).grouping(.never).precision(.fractionLength(0...1))) : ""
        if text != formatted { text = formatted }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        editingBuffer = true
        onFocusChanged(true)
        // Run after the tap's caret placement. Subsequent taps keep ordinary
        // native selection behaviour, including edits to individual digits.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFirstResponder else { return }
            self.selectAll(nil)
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        changed()
        editingBuffer = false
        onFocusChanged(false)
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        // A hardware keyboard and paste can offer letters even on decimalPad.
        let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn:
            (numberLocale.decimalSeparator ?? ".") + "+-"))
        return string.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    @objc private func changed() {
        let input = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let decimal = numberLocale.decimalSeparator ?? "."
        let normalized = input.replacingOccurrences(of: decimal, with: ".")
        // Empty, partial and invalid values must fail creation validation, not
        // silently reuse the previously valid dimension.
        onValueChanged(Double(normalized) ?? .nan)
    }

    @objc private func done() { resignFirstResponder() }
}
