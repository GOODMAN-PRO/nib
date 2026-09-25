import NibContracts
import NibDesign

/// Scan documents & QR (F065): `scan.documents` (document camera → notebook pages with OCR for search) and
/// `scan.qr` (QR reader), offered in the library's New menu, the Add Page menu and the document's More menu.
public enum FeatScanFeature: NibFeature {
    public static let id = "scan"

    public static func register(_ app: NibApp) {
        app.commands.register(ScanDocuments.self)
        app.commands.register(ScanQR.self)

        let menus = app.ui.menus
        menus.register(MenuItemDescriptor(
            id: "scan.new.documents", title: String(localized: "Scan Document"), icon: NibSymbol.scan.name,
            location: .libraryNew, order: 90, owner: id, command: ScanDocuments.descriptor.id,
            params: { ctx in ScanMenus.newNotebookParams(ctx) },
            isVisible: { _ in ScanSupport.documentCamera }))
        menus.register(MenuItemDescriptor(
            id: "scan.new.qr", title: String(localized: "Scan QR Code"), icon: ScanMenus.qrIcon,
            location: .libraryNew, order: 95, owner: id, command: ScanQR.descriptor.id,
            isVisible: { _ in ScanSupport.qrReader }))
        menus.register(MenuItemDescriptor(
            id: "scan.addPage.documents", title: String(localized: "Scan Document"), icon: NibSymbol.scan.name,
            location: .addPage, order: 80, owner: id, command: ScanDocuments.descriptor.id,
            params: { ctx in ScanMenus.addPageParams(ctx) },
            isVisible: { ctx in ScanSupport.documentCamera && ScanMenus.isNotebook(ctx) }))
        menus.register(MenuItemDescriptor(
            id: "scan.more.qr", title: String(localized: "Scan QR Code"), icon: ScanMenus.qrIcon,
            location: .documentMore, order: 900, owner: id, command: ScanQR.descriptor.id,
            isVisible: { _ in ScanSupport.qrReader }))
    }
}

@MainActor
enum ScanMenus {
    static let qrIcon = "qrcode.viewfinder"

    /// New › Scan Document: a new notebook in the folder the library is showing (the root when none).
    static func newNotebookParams(_ ctx: MenuContext) -> JSONValue {
        guard let folder = ctx.nodes.compactMap({ ctx.app.services.library?.node($0) }).first(where: { $0.kind == .folder })
        else { return [:] }
        return ["folder": .string(NodeRef.folder(folder.id).description)]
    }

    /// Add Page › Scan Document: after the open page (the command's default), in this notebook.
    static func addPageParams(_ ctx: MenuContext) -> JSONValue {
        guard let doc = ctx.doc else { return [:] }
        return ["doc": .string(NodeRef.document(doc).description)]
    }

    static func isNotebook(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc, let content = try? ctx.app.workspace.content(doc) else { return false }
        return content.meta.kind == .notebook
    }
}
