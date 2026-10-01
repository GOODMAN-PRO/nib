import Foundation
import NibContracts
import NibDesign

/// System integration (F074): deep links, Home Screen quick actions, App Intents support and the Copy Link entries.
///
/// - **Deep links** (ARCHITECTURE.md §12, P-072): `app.openURL {url}` follows every nib:// form: open a document or page
///   (and a comment thread), play audio at a time, QuickNote, new document, search, plugin install (always confirmed),
///   bridge pairing (the pairing sheet; never enables the bridge) and the share extension's pasteboard hand-off.
/// - **Quick actions** (P-070, D-018): the static QuickNote item plus up to four recently modified favourites, refreshed
///   when Nib goes to the background; `app.quickAction {type}` runs them. With an App Group the favourites are also
///   written to `favourites.json` for the Favourites widget (F096).
/// - **App Intents** (P-071, P-115) live in the app target (Nib/Intents/NibAppIntents.swift) and call the helpers below.
/// - **Copy Link** entries on documents, pages and audio clips put nib:// links on the clipboard (`clipboard.copyText`).
public enum FeatSystemIntegrationFeature: NibFeature {
    public static let id = "system"

    public static func register(_ app: NibApp) {
        app.commands.register(AppOpenURL.self)
        app.commands.register(AppQuickAction.self)
        app.ui.panels.register(BridgePairingSheet.panel(owner: id))
        for item in SystemMenus.items(owner: id) { app.ui.menus.register(item) }
        app.services.set(SystemRuntime(app: app), for: SystemRuntime.serviceKey)
    }

    /// Publishes the quick actions (and favourites.json) now and keeps them current.
    public static func start(_ app: NibApp) async {
        guard !NibApp.isHostlessTest else { return }
        SystemRuntime.shared(app.services)?.quickActions.start()
    }

    // MARK: App Intents support (Nib/Intents/NibAppIntents.swift)

    /// The link that makes a QuickNote.
    public static var quickNoteLink: String { DeepLink.quickNote.string }

    /// The link that opens a document.
    public static func openLink(_ doc: DocumentID) -> String { DeepLink.open(doc: doc, page: nil, comment: nil).string }

    /// The link that opens library search for `query`.
    public static func searchLink(_ query: String) -> String { DeepLink.search(query: query).string }

    /// Documents for a Shortcuts picker or Siri: matching `query` best first; with no query, favourites then recents.
    /// `location` is the folder path ("Physics › Mechanics"), nil at the library root.
    public static func intentDocuments(matching query: String?, app: NibApp,
                                       limit: Int = 50) -> [(node: LibraryNode, location: String?)] {
        guard let library = app.services.library else { return [] }
        return LibrarySearch.rank(library.allNodes(), query: query, kind: .document, limit: limit)
            .map { ($0, LibrarySearch.location(of: $0, in: library)) }
    }

    /// Folders for a Shortcuts picker or Siri, like `intentDocuments`.
    public static func intentFolders(matching query: String?, app: NibApp,
                                     limit: Int = 50) -> [(node: LibraryNode, location: String?)] {
        guard let library = app.services.library else { return [] }
        return LibrarySearch.rank(library.allNodes(), query: query, kind: .folder, limit: limit)
            .map { ($0, LibrarySearch.location(of: $0, in: library)) }
    }

    /// Library nodes by id (entity lookups), in the order asked, skipping any that are gone or in Trash.
    public static func intentNodes(_ ids: [String], app: NibApp) -> [(node: LibraryNode, location: String?)] {
        guard let library = app.services.library else { return [] }
        return ids.compactMap { raw -> (node: LibraryNode, location: String?)? in
            guard NibID.isValid(raw), let node = library.node(NibID(raw)), node.trashedAt == nil else { return nil }
            return (node, LibrarySearch.location(of: node, in: library))
        }
    }

    /// "Append Text to Note": a paragraph at the end of a text document, or a text box under the last thing on the
    /// last page of a notebook or whiteboard (a new page when it is full). One undo step; returns the new ref.
    public static func appendText(_ text: String, to doc: DocumentID, app: NibApp) async throws -> String {
        try await IntentActions.appendText(text, to: doc, app: app)
    }
}

/// This feature's objects, one per app, in `services` under `serviceKey`.
@MainActor
final class SystemRuntime {
    static let serviceKey = "system.runtime"

    /// How long a pairing the person opened stays available to its sheet when nobody taps Close.
    static let pairingLifetime: TimeInterval = 600

    let quickActions: QuickActionPublisher
    /// Asks the person before a link installs a plugin (tests swap it).
    var confirmer: LinkConfirming = AlertLinkConfirmer()
    /// The clock for pairing expiry (tests move it).
    var now: () -> Date = { Date() }
    /// Pairing links the person opened, by a fresh nonce: `panel.open` carries only the nonce, so the pairing sheet
    /// shows nothing another caller of `panel.open` made up (see `DeepLinkRouter.showPairing`).
    private var pairings: [String: (pairing: BridgePairing, expires: Date)] = [:]

    init(app: NibApp) {
        quickActions = QuickActionPublisher(app: app)
    }

    static func shared(_ services: NibServices) -> SystemRuntime? {
        services.get(serviceKey, as: SystemRuntime.self)
    }

    /// Keeps `pairing` for its sheet; returns the nonce `panel.open` names it by.
    func holdPairing(_ pairing: BridgePairing) -> String {
        let t = now()
        pairings = pairings.filter { $0.value.expires > t }
        let nonce = NibID.make().raw
        pairings[nonce] = (pairing, t.addingTimeInterval(SystemRuntime.pairingLifetime))
        return nonce
    }

    /// The pairing held under `nonce` (not consumed: the chrome may build the sheet again); nil when unknown or expired.
    func pairing(_ nonce: String) -> BridgePairing? {
        guard let entry = pairings[nonce] else { return nil }
        guard entry.expires > now() else {
            pairings[nonce] = nil
            return nil
        }
        return entry.pairing
    }

    /// The sheet closed (or never showed): forget the pairing.
    func releasePairing(_ nonce: String) {
        pairings[nonce] = nil
    }
}

/// Copy Link entries: a document (library item menu), the open page (document More menu and page thumbnails) and an
/// audio clip. They run `clipboard.copyText` (F014) with the nib:// link, and show only when that command exists.
enum SystemMenus {
    @MainActor
    static func items(owner: String) -> [MenuItemDescriptor] {
        let icon = NibSymbol.link.name
        let canCopy: @MainActor (MenuContext) -> Bool = { $0.app.commands.entry(SystemIDs.clipboardCopyText) != nil }
        return [
            MenuItemDescriptor(
                id: SystemIDs.copyLinkLibrary, title: String(localized: "Copy Link"), icon: icon, location: .libraryItem,
                order: 850, owner: owner, command: SystemIDs.clipboardCopyText,
                params: { ctx in params(libraryDocument(ctx).map { DeepLink.open(doc: $0, page: nil, comment: nil) }) },
                isVisible: { ctx in canCopy(ctx) && libraryDocument(ctx) != nil }),
            MenuItemDescriptor(
                id: SystemIDs.copyLinkDocument, title: String(localized: "Copy Link to Page"), icon: icon,
                location: .documentMore, order: 850, owner: owner, command: SystemIDs.clipboardCopyText,
                params: { ctx in params(pageLink(doc: ctx.doc ?? ctx.session?.document, page: ctx.page ?? ctx.session?.page)) },
                isVisible: { ctx in canCopy(ctx) && pageLink(doc: ctx.doc ?? ctx.session?.document,
                                                             page: ctx.page ?? ctx.session?.page) != nil }),
            MenuItemDescriptor(
                id: SystemIDs.copyLinkSidebarPage, title: String(localized: "Copy Link to Page"), icon: icon,
                location: .sidebarPage, order: 850, owner: owner, command: SystemIDs.clipboardCopyText,
                params: { ctx in params(pageLink(doc: ctx.doc, page: ctx.page)) },
                isVisible: { ctx in canCopy(ctx) && ctx.nodes.count <= 1 && pageLink(doc: ctx.doc, page: ctx.page) != nil }),
            MenuItemDescriptor(
                id: SystemIDs.copyLinkAudio, title: String(localized: "Copy Link"), icon: icon, location: .audioClip,
                order: 850, owner: owner, command: SystemIDs.clipboardCopyText,
                params: { ctx in params(audioLink(ctx.ref)) },
                isVisible: { ctx in canCopy(ctx) && audioLink(ctx.ref) != nil }),
        ]
    }

    static func params(_ link: DeepLink?) -> JSONValue {
        guard let link else { return [:] }
        return ["url": .string(link.string), "text": .string(link.string)]
    }

    static func pageLink(doc: DocumentID?, page: PageID?) -> DeepLink? {
        guard let doc, let page else { return nil }
        return .open(doc: doc, page: page, comment: nil)
    }

    static func audioLink(_ ref: String?) -> DeepLink? {
        guard let ref, case let .audio(doc, clip)? = NodeRef(ref) else { return nil }
        return .audio(doc: doc, clip: clip, time: nil)
    }

    /// The one document a library item menu is for (its ref, else the single node when it is a document).
    @MainActor
    static func libraryDocument(_ ctx: MenuContext) -> DocumentID? {
        if let ref = ctx.ref, case let .document(doc)? = NodeRef(ref) { return doc }
        guard ctx.nodes.count == 1, let id = ctx.nodes.first else { return nil }
        if let library = ctx.app.services.library, library.node(id)?.kind != .document { return nil }
        return id
    }
}
