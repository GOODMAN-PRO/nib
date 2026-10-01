# F103: print text documents through print.present

**Filed by:** F103 (Text documents: comments, outline & export). **Affects:** F067 (FeatExportUI, owner of
`print.present`), NibContracts.

## Gap

Text documents have their own print layout (`TextDocPageRenderer` in FeatTextDoc: blocks paginated line by line for
the paper the user picks, tables by row group, vector text, page numbers). Today the only way to reach it is ⌘P while
a block has the caret (a `TextDocHooks` key served by the editor). There is no touch path (iPhone, iPad without a
keyboard), no command-bar entry, and nothing plugins or the assistant can call.

`print.present {doc, pages?}` is F067's command and the single print entry point, but F067 lives in another module and
cannot reach FeatTextDoc's renderer: features import only NibContracts and NibDesign.

## Request

1. **NibContracts:** a way for a feature to provide the print renderer of a document kind, for example

   ```swift
   public struct PrintRendererDescriptor: Registrable {
       public var id: String                    // "textdoc.print"
       public var docKinds: Set<DocumentKind>   // [.textDocument]
       public var owner: String
       /// A renderer for `doc`, paginated by the print system for the paper the user picks.
       public var makeRenderer: @MainActor (DocumentID, EditorSession?) throws -> UIPrintPageRenderer
   }
   // ContentRegistries.printRenderers: Registry<PrintRendererDescriptor>
   ```

   F103 registers one for `.textDocument` that returns `TextDocPrinter.renderer(doc:app:session:)`. That function
   exists already and needs no editor (blocks come from `app.workspace`, with the window editor's newer typing).

2. **F067:** `print.present {doc}` for a document whose kind has a registered renderer sets
   `UIPrintInteractionController.printPageRenderer` to it (page ranges and the paper stay the print sheet's).

3. **F067:** ⌘P as a `KeyCommandDescriptor` (contracts-v2.2) with `docKinds` covering the kinds it prints and
   `sessionParams` naming the window's document (`{"doc": "doc:<id>"}`), so the key works while no text is edited and
   shows in the command bar and keyboard settings.

When both land, F103 removes its `TextDocHooks` ⌘P key (`TextDocPrinter.install`), so the key has one owner.

## Until then

F103 keeps the ⌘P hook; FeatTextDocExtrasFeature documents the gap.
