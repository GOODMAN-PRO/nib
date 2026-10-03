import UIKit

/// Read-only transport for the actual Copy output, read in the writing app rather than the background UI runner.
/// The shell exposes this only in fixture mode and only when automation explicitly reads the clipboard probe.
public struct NibUITestClipboardSnapshot: Codable {
    public let changeCount: Int
    public let fragment: Data?

    @MainActor
    public init(pasteboard: UIPasteboard) {
        changeCount = pasteboard.changeCount
        // Checking types does not request paste authorization. Never read unrelated clipboard representations.
        let data = pasteboard.contains(pasteboardTypes: ["app.nib.fragment"])
            ? pasteboard.data(forPasteboardType: "app.nib.fragment") : nil
        // Do not pair bytes with the revision of a different clipboard write.
        fragment = pasteboard.changeCount == changeCount ? data : nil
    }
}
