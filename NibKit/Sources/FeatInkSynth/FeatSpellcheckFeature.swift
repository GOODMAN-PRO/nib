import NibContracts

/// Handwriting spellcheck and the personal dictionary (F104: T-043, S-032, S-033), the second half of FeatInkSynth.
///
/// A notebook or whiteboard with spellcheck on (`DocumentMeta.spellcheck`; new documents start from
/// `NibSettings.spellcheckNewDocuments`) has its handwriting recognised (`recognize.items`) and checked with
/// `UITextChecker` in the document's language, minus the personal dictionary (one synced setting per word,
/// `NibSettings.dictionaryWord`). Misspelled words get red squiggles (the "spellcheck.underlines" canvas attachment).
/// A finger tap on one runs `spellcheck.tapAt` (a tap handler, after links and before selection), which buds a
/// suggestions popover from the word: a suggestion rewrites the word with `handwriting.replaceWord` (F059, same
/// module) in the same size, slant and colour; More › Add to Dictionary runs `dictionary.add`. Document More ›
/// Writing Aids turns spellcheck and Math Assist on or off (`doc.setWritingAids`). The Writing Aids settings page
/// (F105) manages the dictionary through `dictionary.list` / `dictionary.add` / `dictionary.remove`.
public enum FeatSpellcheckFeature: NibFeature {
    public static let id = "spellcheck"

    public static func register(_ app: NibApp) {
        app.commands.register(DictionaryAdd.self)
        app.commands.register(DictionaryRemove.self)
        app.commands.register(DictionaryList.self)
        app.commands.register(DocSetWritingAids.self)
        app.commands.register(SpellcheckTapAt.self)
        app.content.tapHandlers.register(TapHandlerDescriptor(
            id: "spellcheck.tapAt", owner: id, gesture: .tap, command: CommandIDs.spellcheckTapAt, order: 350))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: SpellcheckUnderlines.id, owner: id, order: 100) { _ in
            SpellcheckUnderlines()
        })
        SpellcheckMenus.register(app, owner: id)
    }
}
