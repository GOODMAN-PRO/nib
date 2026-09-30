import Foundation
import NibContracts

// The three commands F071 owns (ARCHITECTURE.md §6.5): `lock.setup {}`, `doc.setLocked {doc, locked}` and
// `doc.unlock {doc}`, plus the guard hook that lets the assistant, plugins and the bridge ASK the person at the device
// to unlock a document (the gateway refuses every other call that names a locked document).

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
        guard let result = await presenter.presentSetup(service.makeSetupRequest()) else { return state("cancelled") }
        let outcome = try await LockStore.apply(result, service: service, settings: settings)
        return state(outcome)
    }
}

/// The only place that writes the lock's settings (from `lock.setup`, inside the command).
@MainActor
enum LockStore {
    /// Stores what the sheet returned. Returns created | changed | removed | unchanged.
    static func apply(_ result: PasswordSetupResult, service: LockServiceImpl, settings: SettingsStore) async throws -> String {
        let hint = result.hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = settings.get(LockSettings.verifier)
        var outcome = "unchanged"
        switch result.action {
        case .create(let password):
            guard current == nil else {
                throw NibError(.conflict, "a password is already set up", hint: "run lock.setup again to change it")
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
            guard current != nil else { return "unchanged" }
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
        let biometrics = result.biometrics && service.biometrics?.kind != nil
        if settings.get(LockSettings.biometrics) != biometrics {
            settings.set(LockSettings.biometrics, biometrics)
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

    /// Face ID for this device from the settings page (`settings.set` as the user, so it stays a command).
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
        let title = p.locked ? String(localized: "Lock Document") : String(localized: "Remove Lock")
        try ctx.mutate(title) { tx in
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
