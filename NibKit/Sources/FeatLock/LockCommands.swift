import Foundation
import UIKit
import NibContracts

// The three commands F071 owns (ARCHITECTURE.md §6.5): `lock.setup {}`, `doc.setLocked {doc, locked}` and
// `doc.unlock {doc}`, plus the guard hooks around them:
// - `lock.unlockGuard` lets the assistant, plugins and the bridge ASK the person at the device to unlock a document (the
//   gateway refuses every other call that names a locked document);
// - `lock.settingsGuard` asks for the password before `settings.set` turns on Face ID or replaces the verifier;
// - `lock.undoGuard` keeps `edit.undo` / `edit.redo` / `history.revertGroup` from taking a lock off for anyone but the
//   user (`meta.locked` changes only through `doc.setLocked`);
// - `lock.sessionGuard` refuses calls that name no document but act on the window's document while it is locked.

@MainActor
enum LockCommandSupport {
    /// This feature's service (another `LockService`, e.g. a test fake, has no commands behind it).
    static func service(_ ctx: CommandContext) throws -> LockServiceImpl {
        guard let service = ctx.services.lock as? LockServiceImpl else { throw NibError.unavailable("the password lock") }
        return service
    }

    static func ref(_ doc: DocumentID) -> String { NodeRef.document(doc).description }

    /// Throws `not_found` for a document that does not exist (reads the head without opening it).
    static func requireDocument(_ doc: DocumentID, _ ctx: CommandContext) throws {
        if ctx.workspace.isLoaded(doc) || ctx.services.library?.node(doc) != nil { return }
        _ = try ctx.workspace.peekContent(doc)
    }

    static func noWindow(_ what: String) -> NibError {
        NibError(.unavailable, "\(what) needs a window on the device",
                 hint: "the user does this on the device (Settings › General › Password Protection)")
    }

    /// Lets `doc.unlock` from the assistant, a plugin or a bridge client reach the person at the device. The gateway
    /// refuses any non-user call that names a locked document, so this guard (which runs before authorisation) makes
    /// the same exposure and scope checks the gateway makes, then shows the unlock prompt; once the person unlocks,
    /// the call goes through. Dry runs and ask mode never prompt.
    static func unlockGuard(_ service: LockServiceImpl) -> CommandHookDescriptor {
        CommandHookDescriptor.guarding(id: LockIDs.unlockGuard, owner: FeatLockFeature.id, commands: [LockIDs.unlock]) {
            [weak service] _, params, ctx in
            guard let service = service, !ctx.principal.isUser, !ctx.dryRun else { return nil }
            guard let raw = params["doc"]?.stringValue, !raw.isEmpty else { return nil }
            let doc = NodeRef.documentID(from: raw)
            guard service.isLocked(doc) else { return nil }
            if case .sync = ctx.principal { throw NibError(.permissionDenied, "sync cannot run commands") }
            if let d = ctx.bus.registry.descriptor(LockIDs.unlock) {
                guard d.exposure.contains(ctx.principal.exposure) else {
                    throw NibError(.permissionDenied, "'\(d.id)' is not available to \(ctx.principal)")
                }
                let missing = d.scopes.subtracting(ctx.bus.gateway.grants(ctx.principal))
                guard missing.isEmpty else {
                    throw NibError(.permissionDenied,
                                   "missing permission(s): " + missing.map { $0.rawValue }.sorted().joined(separator: ", "),
                                   hint: "the user must grant these permissions")
                }
            }
            guard service.presenter != nil else { throw noWindow("Unlocking a document") }
            guard await service.unlock(doc, purpose: .open, requester: ctx.principal) else {
                throw NibError(.userDenied, "the user did not unlock document \(doc)",
                               hint: "the document stays locked; ask the user to open it on the device")
            }
            return nil
        }
    }

    /// `settings.set` is the other way to reach the lock's settings (the settings page's Face ID switch, the command
    /// bar). Turning on Face ID lets anyone whose face or finger this device knows open every locked document, and a
    /// new verifier replaces the password, so both ask for the current password first (never biometrics). Turning
    /// Face ID off needs nothing. Other principals never get here: `settings.set` refuses them `security.*`.
    static func settingsGuard(_ service: LockServiceImpl) -> CommandHookDescriptor {
        CommandHookDescriptor.guarding(id: LockIDs.settingsGuard, owner: FeatLockFeature.id,
                                       commands: [CommandIDs.settingsSet]) { [weak service] _, params, ctx in
            guard let service = service, ctx.principal.isUser, !ctx.dryRun,
                  let name = params["name"]?.stringValue else { return nil }
            let value = params["value"] ?? .null
            switch name {
            case LockSettings.biometrics.name:
                guard value.boolValue == true, !ctx.services.settings.get(LockSettings.biometrics) else { return nil }
                guard service.isConfigured else {
                    throw NibError(.unavailable, "no lock password is set up",
                                   hint: "set one up first (lock.setup, Settings › General › Password Protection)")
                }
                guard service.presenter != nil else { throw noWindow("Turning on Face ID") }
                let kind = (service.biometrics?.kind ?? .faceID).name
                guard await service.verifyPassword(
                    action: String(localized: "Turn On \(kind)"),
                    message: String(localized: "Enter the password to open locked documents with \(kind) on this \(UIDevice.current.localizedModel).")) else {
                    throw NibError(.userDenied, "the password was not entered; \(kind) stays off")
                }
            case LockSettings.verifier.name:
                let locked = service.lockedDocuments().count
                if value == .null && locked > 0 {
                    throw NibError(.conflict, "\(locked) document(s) still have a lock",
                                   hint: "remove their locks first (doc.setLocked {locked: false})")
                }
                if service.isConfigured {
                    guard service.presenter != nil else { throw noWindow("Changing the password") }
                    guard await service.verifyPassword(
                        action: String(localized: "Change Password"),
                        message: String(localized: "Enter the current password to change the library's password.")) else {
                        throw NibError(.userDenied, "the current password was not entered; the password is unchanged")
                    }
                } else if locked > 0 {
                    throw NibError(.conflict, "documents are locked with a password that has not synced to this device yet",
                                   hint: "wait for it to sync, or replace it in lock.setup")
                }
            default:
                return nil
            }
            return nil
        }
    }

    /// Undo, redo and selective revert may write `meta.locked` back. For the assistant, a plugin or the bridge, a step
    /// that would take a lock off is refused: the lock the user just added to the document in front of them keeps it
    /// unlocked for the session, so the gateway alone would let `edit.undo` remove it without the password.
    static func undoGuard(_ service: LockServiceImpl) -> CommandHookDescriptor {
        CommandHookDescriptor.guarding(id: LockIDs.undoGuard, owner: FeatLockFeature.id,
                                       commands: [CommandIDs.undo, CommandIDs.redo, CommandIDs.revertGroup]) {
            [weak service] command, params, ctx in
            guard let service = service, !ctx.principal.isUser else { return nil }
            if case .sync = ctx.principal { return nil }
            guard let doc = try? ctx.documentOrSession(params["doc"]?.stringValue) else { return nil }
            // A document still locked for this session is refused by the gateway (`locked`) before anything runs.
            if service.isLocked(doc) && Gateway.referencedDocuments(params).contains(doc) { return nil }
            guard service.historyStepRemovesLock(command: command, doc: doc, group: params["group"]?.stringValue,
                                                 history: ctx.bus.history) else { return nil }
            throw NibError(.permissionDenied, "this step would remove a document's lock",
                           hint: "the user removes locks with doc.setLocked")
        }
    }

    /// Calls that name no document but act on the window's (`CommandContext.activeSession`; the bridge's nil session
    /// means the active window) never reach a document that is locked for this session, e.g. while the locked field
    /// covers a window after a relock and an assistant turn is still running. The gateway only sees refs in params.
    /// Registered in `FeatLockFeature.start` over every command namespace registered by then.
    static func sessionGuard(_ service: LockServiceImpl, namespaces: [String]) -> CommandHookDescriptor {
        CommandHookDescriptor.guarding(id: LockIDs.sessionGuard, owner: FeatLockFeature.id,
                                       commands: namespaces.map { $0 + ".*" }) { [weak service] command, params, ctx in
            guard let service = service, !ctx.principal.isUser, !LockIDs.commands.contains(command) else { return nil }
            if case .sync = ctx.principal { return nil }
            guard ctx.bus.registry.descriptor(command)?.target == .document,
                  Gateway.referencedDocuments(params).isEmpty,
                  let doc = ctx.activeSession?.document, service.isLocked(doc) else { return nil }
            throw NibError(.locked, "document \(doc) is locked", hint: "ask the user to unlock it first")
        }
    }

    /// The namespaces of every registered command ("page" for page.add, …), for `sessionGuard`.
    static func namespaces(_ registry: CommandRegistry) -> [String] {
        Set(registry.all().compactMap { $0.id.split(separator: ".").first.map(String.init) }).sorted()
    }
}

// MARK: - lock.setup

/// Shows the password sheet: create the universal password (with a hint and Face ID), change it, or turn it off.
/// Security-scoped: only the person at the device, never the assistant, plugins or the bridge.
struct LockSetup: NibCommand {
    typealias Params = NoResult

    struct Output: Codable, Equatable {
        var configured: Bool
        var biometrics: Bool
        /// created | changed | removed | unchanged | cancelled
        var outcome: String
    }

    static let descriptor = CommandDescriptor(
        id: "lock.setup", title: "Password Protection",
        summary: "Show the sheet to set up, change or turn off the library's lock password, hint and Face ID (user only) → {configured, biometrics, outcome}.",
        params: .empty, examples: [[:]], effect: .session, target: .app, extraScopes: [.security],
        userPresence: true)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> Output {
        guard ctx.principal.isUser else {
            throw NibError(.permissionDenied, "'lock.setup' can only be run by the user")
        }
        let service = try LockCommandSupport.service(ctx)
        let settings = ctx.services.settings
        func state(_ outcome: String) -> Output {
            Output(configured: service.isConfigured, biometrics: settings.get(LockSettings.biometrics), outcome: outcome)
        }
        if ctx.dryRun { return state("unchanged") }
        guard let presenter = service.presenter else { throw LockCommandSupport.noWindow("Password setup") }
        let request = service.makeSetupRequest()
        guard let result = await presenter.presentSetup(request) else { return state("cancelled") }
        let outcome = try await LockStore.apply(result, request: request, service: service, settings: settings)
        return state(outcome)
    }
}

/// The only place that writes the lock's settings (from `lock.setup`, inside the command).
@MainActor
enum LockStore {
    /// Stores what the sheet returned (`request` is what the sheet was shown with). Returns created | changed |
    /// removed | unchanged.
    static func apply(_ result: PasswordSetupResult, request: PasswordSetupRequest? = nil, service: LockServiceImpl,
                      settings: SettingsStore) async throws -> String {
        let hint = result.hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = settings.get(LockSettings.verifier)
        var outcome = "unchanged"
        switch result.action {
        case .create(let password):
            guard !service.isConfigured else {
                throw NibError(.conflict, "a password is already set up", hint: "run lock.setup again to change it")
            }
            // Documents that carry a lock while no password is here: theirs has not synced yet. A new one replaces it
            // on every device, so only after the sheet's explicit confirmation.
            if !result.confirmedReplacement, !service.lockedDocuments().isEmpty {
                throw NibError(.conflict, "documents are locked with a password that has not synced to this device yet",
                               hint: "wait for it to sync, or confirm replacing it on every device")
            }
            try validate(password, hint: hint)
            let v = try await LockVerifier.make(password: password, hint: hint, iterations: service.iterations)
            settings.set(LockSettings.verifier, v)
            outcome = "created"
        case .change(let newPassword):
            guard var v = current else {
                throw NibError(.conflict, "the password was turned off meanwhile", hint: "run lock.setup to set one up")
            }
            if let password = newPassword {
                try validate(password, hint: hint)
                v = try await LockVerifier.make(password: password, hint: hint, iterations: service.iterations)
                settings.set(LockSettings.verifier, v)
                outcome = "changed"
            } else if v.hint != hint {
                // Only the hint changed (the sheet checked it against the current password it just verified).
                v.hint = hint
                v.updatedAt = Date().timeIntervalSince1970
                settings.set(LockSettings.verifier, v)
                outcome = "changed"
            }
        case .remove:
            guard service.isConfigured else { return "unchanged" }
            let locked = service.lockedDocuments()
            guard locked.isEmpty else {
                throw NibError(.conflict, "\(locked.count) document(s) still have a lock",
                               hint: "remove their locks first (doc.setLocked {locked: false})")
            }
            settings.setJSON(LockSettings.verifier.name, nil)
            settings.set(LockSettings.biometrics, false)
            service.passwordDidChange()
            return "removed"
        }
        // Only a switch the person moved changes Face ID (a lockout that makes it unavailable for a moment must not
        // quietly turn it off).
        let shown = request?.biometricsOn ?? settings.get(LockSettings.biometrics)
        if result.biometrics != shown, settings.get(LockSettings.biometrics) != result.biometrics {
            settings.set(LockSettings.biometrics, result.biometrics)
            if outcome == "unchanged" { outcome = "changed" }
        }
        if outcome != "unchanged" { service.passwordDidChange() }
        return outcome
    }

    static func validate(_ password: String, hint: String) throws {
        if let problem = PasswordRules.problems(password: password, confirmation: password, hint: hint).first {
            throw NibError.invalid(PasswordRules.message(problem))
        }
    }

    /// Face ID for this device from the settings page (`settings.set` as the user, so it stays a command; turning it
    /// on asks for the password in `LockCommandSupport.settingsGuard`).
    static func setBiometrics(_ on: Bool, app: NibApp) async throws {
        _ = try await app.bus.execute(Invocation(command: CommandIDs.settingsSet,
                                                 params: ["name": .string(LockSettings.biometrics.name), "value": .bool(on)],
                                                 principal: .user, session: app.services.sessions.active))
    }
}

// MARK: - doc.setLocked

/// Adds or removes a document's lock (`meta.locked`, undoable). Locking needs a password (the user is asked to set one
/// up first); removing asks for the password on the device.
struct DocSetLocked: NibCommand {
    struct Params: Codable {
        var doc: String?
        var locked: Bool
    }

    struct Output: Codable, Equatable {
        var doc: String
        var locked: Bool
        var changed: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "doc.setLocked", title: "Lock Document",
        summary: "Password-lock a document or remove its lock (removing asks the user for the password on the device) → {doc, locked, changed}.",
        params: .obj(["doc": .str("document ref doc:D (the user may omit it: the window's document)"),
                      "locked": .bool("true adds the lock, false removes it")],
                     required: ["doc", "locked"]),
        examples: [["doc": "doc:FIXTUREDOC01", "locked": true]],
        effect: .edit, userPresence: true)

    /// The undo step's names (the undo guard recognises "Remove Lock" on the redo stack).
    static var lockTitle: String { String(localized: "Lock Document") }
    static var removeTitle: String { String(localized: "Remove Lock") }

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = try ctx.documentOrSession(p.doc)
        let service = try LockCommandSupport.service(ctx)
        let meta = try ctx.workspace.content(doc).meta
        let ref = LockCommandSupport.ref(doc)
        if meta.locked == p.locked { return Output(doc: ref, locked: p.locked, changed: false) }
        if ctx.isReadOnly(doc) {
            throw NibError(.unsupported, "this document was saved by a newer version of Nib and opens read-only",
                           hint: "update Nib to change it")
        }
        var keepUnlocked = false
        if !ctx.dryRun {
            if p.locked {
                if !service.isConfigured {
                    guard ctx.principal.isUser, service.presenter != nil else {
                        throw NibError(.unavailable, "no lock password is set up",
                                       hint: "the user sets one up on the device (lock.setup, Settings › General › Password Protection)")
                    }
                    service.pendingSetupReason = String(localized: "Set a password to lock “\(service.title(doc))”. It unlocks every locked document in this library.")
                    defer { service.pendingSetupReason = nil }
                    _ = try await ctx.execute(LockIDs.setup)
                    guard service.isConfigured else { return Output(doc: ref, locked: meta.locked, changed: false) }
                }
                // The person who locks the document they are looking at keeps it open until the next relock.
                keepUnlocked = ctx.principal.isUser && service.isOpenInWindow(doc)
            } else {
                guard service.presenter != nil else { throw LockCommandSupport.noWindow("Removing a lock") }
                guard await service.unlock(doc, purpose: .removeLock, requester: ctx.principal) else {
                    if ctx.principal.isUser { return Output(doc: ref, locked: true, changed: false) }
                    throw NibError(.userDenied, "the user did not enter the password; the document keeps its lock")
                }
                keepUnlocked = true
            }
        }
        try ctx.mutate(p.locked ? lockTitle : removeTitle) { tx in
            var m = try tx.content(doc).meta
            m.locked = p.locked
            try tx.putMeta(m)
        }
        if !ctx.dryRun { service.didSetLocked(doc, locked: p.locked, keepUnlocked: keepUnlocked) }
        return Output(doc: ref, locked: p.locked, changed: true)
    }
}

// MARK: - doc.unlock

/// Unlocks a locked document for this app session: Face ID or the password, on the device.
struct DocUnlock: NibCommand {
    struct Params: Codable {
        var doc: String?
    }

    struct Output: Codable, Equatable {
        var doc: String
        var unlocked: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "doc.unlock", title: "Unlock Document",
        summary: "Ask the user to unlock a password-locked document for this session (Face ID or password on the device) → {doc, unlocked}.",
        params: .obj(["doc": .str("document ref doc:D (the user may omit it: the window's document)")],
                     required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"]],
        effect: .session, userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = try ctx.documentOrSession(p.doc)
        let service = try LockCommandSupport.service(ctx)
        try LockCommandSupport.requireDocument(doc, ctx)
        let ref = LockCommandSupport.ref(doc)
        guard service.isLocked(doc) else { return Output(doc: ref, unlocked: true) }
        if ctx.dryRun { return Output(doc: ref, unlocked: false) }
        guard service.presenter != nil || service.biometricsEnabled else {
            throw LockCommandSupport.noWindow("Unlocking a document")
        }
        let ok = await service.unlock(doc, purpose: .open, requester: ctx.principal)
        if !ok && !ctx.principal.isUser {
            throw NibError(.userDenied, "the user did not unlock document \(doc)", hint: "the document stays locked")
        }
        return Output(doc: ref, unlocked: ok)
    }
}
