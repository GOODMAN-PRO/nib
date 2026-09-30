import Foundation
import SwiftUI
import UIKit
import os
import NibContracts
import NibDesign

/// Password lock (F071; Goodnotes parity D-024, D-025, P-033, P-034): one universal password for the library (a
/// PBKDF2-SHA256 verifier and hint in the synced, user-only setting `security.lock.verifier`), optional Face ID /
/// Touch ID per device, an unlock prompt before a locked document opens (`ui.openGate`), the hint after three wrong
/// entries, and relocking 2 minutes after leaving Nib or at once when the device locks.
///
/// It fills `services.lock` and `gateway.isLocked`, so the assistant, plugins and the bridge get `locked` errors for
/// locked documents, and search, backup, WebDAV, export and collaboration skip them while they are locked. The library
/// badge comes from `meta.locked` (`LibraryNode.locked`). It is an access gate, not encryption: see LockServiceImpl.swift.
///
/// Commands: `lock.setup {}` (session, user presence, security), `doc.setLocked {doc, locked}` (edit, user presence),
/// `doc.unlock {doc}` (session, user presence).
public enum FeatLockFeature: NibFeature {
    public static let id = "lock"

    public static func register(_ app: NibApp) {
        LockSettings.declare(app.settings, owner: id)

        let service = LockServiceImpl(app: app)
        if !NibApp.isHostlessTest {
            service.presenter = LockUIPresenter(app: app, service: service)
            service.biometrics = SystemBiometrics()
        }
        app.services.lock = service
        app.services.set(service, for: LockServiceImpl.serviceKey)
        app.gateway.isLocked = { [weak service] doc in service?.isLocked(doc) ?? false }
        app.ui.openGate = { [weak app] doc in
            guard let app = app else { return true }
            return await LockGate.open(doc, app: app)
        }

        app.commands.register(LockSetup.self)
        app.commands.register(DocSetLocked.self)
        app.commands.register(DocUnlock.self)
        app.bus.hooks.register(LockCommandSupport.unlockGuard(service))
        app.bus.hooks.register(LockCommandSupport.settingsGuard(service))
        app.bus.hooks.register(LockCommandSupport.undoGuard(service))

        LockMenus.register(app, owner: id)

        var page = SettingsPageDescriptor(id: LockIDs.settingsPage, title: String(localized: "Password Protection"),
                                          icon: NibSymbol.lock.name, section: .general, order: 60, owner: id) { app in
            AnyView(PasswordSettingsPage(app: app))
        }
        page.keywords = ["Face ID", "Touch ID"]
            + String(localized: "password, lock, unlock, privacy, hint, locked documents, security, protect")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        app.ui.settingsPages.register(page)
    }

    public static func start(_ app: NibApp) async {
        guard let service = app.services.lock as? LockServiceImpl, !service.isStarted else { return }
        service.start()
        // Every feature has registered its commands by now, so the guard covers all of their namespaces.
        app.bus.hooks.register(LockCommandSupport.sessionGuard(service,
                                                               namespaces: LockCommandSupport.namespaces(app.commands)))
    }
}

// MARK: - The open gate

/// `ui.openGate` and the locked field's Unlock button: `doc.unlock` as the user in the window's session.
@MainActor
enum LockGate {
    static let log = Logger(subsystem: "app.nib", category: "lock")

    static func open(_ doc: DocumentID, app: NibApp) async -> Bool {
        guard let lock = app.services.lock else { return true }
        guard lock.isLocked(doc) else { return true }
        return await unlock(doc, app: app, session: app.services.sessions.active)
    }

    static func unlock(_ doc: DocumentID, app: NibApp, session: EditorSession?) async -> Bool {
        guard app.commands.entry(LockIDs.unlock) != nil else {
            return await app.services.lock?.unlock(doc) ?? true
        }
        do {
            let result = try await app.bus.execute(Invocation(
                command: LockIDs.unlock, params: ["doc": .string(NodeRef.document(doc).description)],
                principal: .user, session: session))
            return result.value["unlocked"]?.boolValue ?? false
        } catch {
            let e = NibError.wrap(error)
            log.error("unlock failed: \(e.description, privacy: .public)")
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": LockIDs.unlock, "error": e])
            return false
        }
    }
}

// MARK: - Menus

/// Lock / Remove Lock on a library document and in a document's More menu; each runs `doc.setLocked`.
@MainActor
enum LockMenus {
    static func register(_ app: NibApp, owner: String) {
        let menus = app.ui.menus
        for locking in [true, false] {
            menus.register(MenuItemDescriptor(
                id: locking ? LockIDs.menuLockLibrary : LockIDs.menuUnlockLibrary,
                title: locking ? String(localized: "Lock") : String(localized: "Remove Lock"),
                icon: (locking ? NibSymbol.lock : NibSymbol.unlock).name,
                location: .libraryItem, order: 150, owner: owner, command: LockIDs.setLocked,
                params: { ctx in menuParams(libraryDocument(ctx), locked: locking) },
                isVisible: { ctx in libraryDocument(ctx).map { isFlagged($0, ctx.app) != locking } ?? false }))
            menus.register(MenuItemDescriptor(
                id: locking ? LockIDs.menuLockDocument : LockIDs.menuUnlockDocument,
                title: locking ? String(localized: "Lock Document") : String(localized: "Remove Lock"),
                icon: (locking ? NibSymbol.lock : NibSymbol.unlock).name,
                location: .documentMore, order: 600, owner: owner, command: LockIDs.setLocked,
                params: { ctx in menuParams(ctx.doc, locked: locking) },
                isVisible: { ctx in ctx.doc.map { isFlagged($0, ctx.app) != locking } ?? false }))
        }
    }

    /// The one document a library item menu is for (not a folder, not in the Trash).
    static func libraryDocument(_ ctx: MenuContext) -> DocumentID? {
        guard ctx.nodes.count == 1, let id = ctx.nodes.first else {
            if let ref = ctx.ref, case .document(let doc)? = NodeRef(ref) { return doc }
            return nil
        }
        guard let node = ctx.app.services.library?.node(id) else { return nil }
        return node.kind == .document && node.trashedAt == nil ? node.id : nil
    }

    static func isFlagged(_ doc: DocumentID, _ app: NibApp) -> Bool {
        (app.services.lock as? LockServiceImpl)?.isFlagged(doc) ?? (app.services.library?.node(doc)?.locked ?? false)
    }

    static func menuParams(_ doc: DocumentID?, locked: Bool) -> JSONValue {
        guard let doc = doc else { return ["locked": .bool(locked)] }
        return ["doc": .string(NodeRef.document(doc).description), "locked": .bool(locked)]
    }
}
