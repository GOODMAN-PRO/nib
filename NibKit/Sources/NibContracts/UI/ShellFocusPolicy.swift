/// Focus recovery must leave a modal alone even between its appearance and its
/// text field becoming first responder. A missing responder is normal then.
public enum ShellFocusPolicy {
    public static func shouldReclaim(isKeyWindow: Bool, shellHasFocus: Bool, hasModal: Bool,
                                     isEditingText: Bool, showsDocument: Bool,
                                     hasFocusedResponder: Bool, hasCommandResponder: Bool = false) -> Bool {
        guard isKeyWindow, !shellHasFocus, !hasModal, !isEditingText else { return false }
        // A feature's native responder is already the route through its hosting
        // boundary. Replacing it can split a modifier chord across responders.
        guard !hasCommandResponder else { return false }
        return !showsDocument || !hasFocusedResponder
    }
}
