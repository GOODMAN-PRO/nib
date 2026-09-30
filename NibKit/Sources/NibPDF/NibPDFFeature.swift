import NibContracts

/// PDF engine (F024): the PDFKit-backed `services.pdf` (text, line blocks, links, outline, drag selections and the
/// word at a point, in page points), the "pdf" importer (the PDF stored once as an asset, one page per PDF page) and
/// the read commands `pdf.text` and `pdf.links`. The PDF outline is read through F046's `outline.list`, which calls
/// `services.pdf.outline`; F024 adds no outline command.
public enum NibPDFFeature: NibFeature {
    public static let id = "pdf"

    public static func register(_ app: NibApp) {
        app.services.pdf = PDFKitService()
        app.services.set(AlertPasswordProvider(app: app), for: PDFImporter.passwordServiceKey)
        app.content.importers.register(PDFImporter.descriptor(owner: id))
        app.commands.register(PDFTextCommand.self)
        app.commands.register(PDFLinksCommand.self)
    }
}
