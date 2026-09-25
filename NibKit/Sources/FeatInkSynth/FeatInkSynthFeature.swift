import NibContracts

/// Ink synthesis and the handwriting typesetter (F059: T-044, S-022, S-034). Glyph outlines of a handwriting-style
/// system font (Noteworthy, Bradley Hand or Marker Felt; device setting `inksynth.font`) are rasterised, thinned and
/// traced into centre-line strokes (`GlyphSkeleton`, cached per glyph), and `InkTypesetter` lays text out with them.
///
/// Commands: `ink.writeText` (the AI's handwriting tool, Math Assist answers, plugins such as word-complete) and
/// `handwriting.replaceWord` (spelling corrections, word completion). Both are ordinary undoable edits that honour
/// caller-chosen ids. Handwriting Restyle (F105, same module) re-writes recognised text with `InkTypesetter`, and its
/// Writing Aids settings page hosts the font picker.
public enum FeatInkSynthFeature: NibFeature {
    public static let id = "inksynth"

    public static func register(_ app: NibApp) {
        app.commands.register(InkWriteText.self)
        app.commands.register(HandwritingReplaceWord.self)
        InkSynthSettings.declare(app.settings, owner: id)
    }
}
