import UIKit
import NibContracts

/// The "text" canvas tool (key T, taps only, T-055): a tap on the page starts a new text box with the keyboard up;
/// a tap on a text box edits it. Non-sticky unless pinned (`text.pinned`, T-035): after the new box is finished the
/// previous tool comes back.
@MainActor
final class TextTool: CanvasTool {
    static let toolID = "text"

    let id = "text"
    let inputMode: CanvasInputMode = .taps
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var isSticky: Bool { settings.get(TextSettings.pinned) }

    func tap(_ sample: CanvasSample, host: CanvasHost) {
        guard !host.session.readOnly, let editor = TextBoxEditor.editor(for: host) else { return }
        if editor.isEditing {
            editor.endEditing()
            return
        }
        // Tap handlers (`text.tapAt`) normally claim taps on text boxes first; this covers hosts that route every
        // tap to the tool.
        if let items = try? host.app.workspace.items(host.documentID, page: sample.page),
           let hit = TextHitTest.textItem(at: sample.location, in: items), !hit.locked,
           hit.layer == host.session.activeLayer {
            editor.beginEditing(doc: host.documentID, page: sample.page, item: hit, caretAt: sample.location)
            return
        }
        editor.beginNewBox(page: sample.page, at: sample.location)
    }
}
