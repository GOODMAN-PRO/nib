/// Focus recovery must leave a modal alone even between its appearance and its
/// text field becoming first responder. A missing responder is normal then.
public enum ShellFocusPolicy {
    public static func shouldReclaim(isKeyWindow: Bool, shellHasFocus: Bool, hasModal: Bool,
                                     isEditingText: Bool, showsDocument: Bool,
                                     hasFocusedResponder: Bool) -> Bool {
        guard isKeyWindow, !shellHasFocus, !hasModal, !isEditingText else { return false }
        return !showsDocument || !hasFocusedResponder
    }
}
