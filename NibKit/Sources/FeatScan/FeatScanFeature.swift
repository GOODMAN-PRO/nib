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
        // + New: after Import Files (F064, 600).
        menus.register(MenuItemDescriptor(
            id: ScanMenus.newDocumentsID, title: String(localized: "Scan Document"), icon: NibSymbol.scan.name,
            location: .libraryNew, order: 700, owner: id, command: ScanDocuments.descriptor.id,
            params: { ScanMenus.newNotebookParams($0) },
            isVisible: { _ in ScanSupport.documentCamera }))
        menus.register(MenuItemDescriptor(
            id: ScanMenus.newQRID, title: String(localized: "Scan QR Code"), icon: NibSymbol.qrCode.name,
            location: .libraryNew, order: 710, owner: id, command: ScanQR.descriptor.id,
            isVisible: { _ in ScanSupport.qrReader }))
        // Add Page: after Image and Take Photo (F034, 700 and 710).
        menus.register(MenuItemDescriptor(
            id: ScanMenus.addPageID, title: String(localized: "Scan Document"), icon: NibSymbol.scan.name,
            location: .addPage, order: 720, owner: id, command: ScanDocuments.descriptor.id,
            params: { ScanMenus.addPageParams($0) },
            isVisible: { ScanSupport.documentCamera && ScanMenus.canAddPages($0) }))
        menus.register(MenuItemDescriptor(
            id: ScanMenus.moreQRID, title: String(localized: "Scan QR Code"), icon: NibSymbol.qrCode.name,
            location: .documentMore, order: 900, owner: id, command: ScanQR.descriptor.id,
            isVisible: { _ in ScanSupport.qrReader }))
    }
}

@MainActor
enum ScanMenus {
    static let newDocumentsID = "scan.new.documents"
    static let newQRID = "scan.new.qr"
    static let addPageID = "scan.addPage.documents"
    static let moreQRID = "scan.more.qr"

    /// New › Scan Document: a new notebook in the folder the library shows (the root when none).
    static func newNotebookParams(_ ctx: MenuContext) -> JSONValue {
        guard let folder = ctx.folder else { return [:] }
        return ["folder": .string(NodeRef.folder(folder).description)]
    }

    /// Add Page › Scan Document: after the page the menu was opened on (else the open page), else at the end.
    static func addPageParams(_ ctx: MenuContext) -> JSONValue {
        guard let doc = ctx.doc ?? ctx.session?.document else { return [:] }
        var params: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description)]
        if let page = ctx.page ?? (ctx.session?.document == doc ? ctx.session?.page : nil) {
            params["position"] = .string(PagePosition.after.rawValue)
            params["anchor"] = .string(NodeRef.page(doc, page).description)
        } else {
            params["position"] = .string(PagePosition.end.rawValue)
        }
        return .object(params)
    }

    /// A notebook the person may add pages to (not read-only in this window or on disk).
    static func canAddPages(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc ?? ctx.session?.document, ctx.session?.readOnly != true, !ctx.app.isReadOnly(doc),
              let content = try? ctx.app.workspace.content(doc) else { return false }
        return content.meta.kind == .notebook
    }
}
