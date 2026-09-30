import Foundation
import Combine
import CommonCrypto
import LocalAuthentication
import Security
import UIKit
import os
import NibContracts

// Password lock (F071): one universal password for the library, optional Face ID / Touch ID per device, an unlock
// prompt before a locked document opens, the hint after three wrong entries, and relocking two minutes after leaving
// Nib or at once when the device locks.
//
// An ACCESS GATE, NOT ENCRYPTION. A locked document is a normal `.nibnote` package whose head says `meta.locked`; its
// files are never scrambled. The lock keeps it from opening in Nib, keeps the assistant, plugins and the bridge out
// (`Gateway.isLocked` → `locked` errors), and makes search, backup, WebDAV, export and collaboration skip it while it is
// locked (those features ask `services.lock`). Anyone who can read the library folder itself can read the notes. The
// settings page and the setup sheet say so in plain words.

// MARK: - Settings

enum LockSettings {
    /// The universal password's PBKDF2-SHA256 verifier and its hint. Synced, so it travels with the library to every
    /// device; "security.*", so only the user can read or change it (`settings.get` / `settings.set` refuse other
    /// principals). nil = no password is set up.
    static let verifier = SettingKey<LockVerifier?>("security.lock.verifier", default: nil, synced: true)
    /// Unlock with Face ID / Touch ID on THIS device (device-local, user only).
    static let biometrics = SettingKey("security.lock.biometrics", default: false)

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(verifier, summary: "Password lock verifier (PBKDF2-SHA256) and hint; written by lock.setup (user only).",
                  owner: owner,
                  schema: .obj(["version": .int(), "algorithm": .str(choices: [LockVerifier.algorithmName]),
                                "iterations": .int(min: 1, max: LockVerifier.maximumIterations),
                                "salt": .str("base64"), "hash": .str("base64"), "hint": .str(),
                                "updatedAt": .num("Unix seconds")],
                               required: ["algorithm", "iterations", "salt", "hash"]))
        s.declare(biometrics, summary: "Unlock locked documents with Face ID or Touch ID on this device (user only).",
                  owner: owner, schema: .bool())
    }
}

// MARK: - Verifier (PBKDF2-SHA256)

/// What the library stores instead of the password: a random salt and PBKDF2-HMAC-SHA256(password, salt, iterations),
/// plus the optional hint. Checking a password derives the same key and compares in constant time.
struct LockVerifier: Codable, Equatable {
    static let algorithmName = "pbkdf2-sha256"
    /// OWASP's 2023 figure for PBKDF2-HMAC-SHA256. About a quarter of a second on an A12, off the main actor.
    static let defaultIterations = 600_000
    /// A synced verifier asking for more rounds than this is refused instead of hanging the device.
    static let maximumIterations = 10_000_000

    var version: Int
    var algorithm: String
    var iterations: Int
    var salt: Data
    var hash: Data
    var hint: String
    var updatedAt: Double

    init(version: Int = 1, algorithm: String = LockVerifier.algorithmName, iterations: Int, salt: Data, hash: Data,
         hint: String, updatedAt: Double = Date().timeIntervalSince1970) {
        self.version = version
        self.algorithm = algorithm
        self.iterations = iterations
        self.salt = salt
        self.hash = hash
        self.hint = hint
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case version, algorithm, iterations, salt, hash, hint, updatedAt }

    /// Lenient: the key material (algorithm, iterations, salt, hash) is required; the rest defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        algorithm = try c.decode(String.self, forKey: .algorithm)
        iterations = try c.decode(Int.self, forKey: .iterations)
        salt = try c.decode(Data.self, forKey: .salt)
        hash = try c.decode(Data.self, forKey: .hash)
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }

    /// Hashes `password` with a fresh salt (off the main actor).
    static func make(password: String, hint: String, iterations: Int = LockVerifier.defaultIterations,
                     now: Date = Date()) async throws -> LockVerifier {
        let salt = PasswordHasher.makeSalt()
        guard let hash = await PasswordHasher.deriveDetached(password: password, salt: salt, iterations: iterations) else {
            throw NibError(.internalError, "the password could not be hashed")
        }
        return LockVerifier(iterations: iterations, salt: salt, hash: hash, hint: hint,
                            updatedAt: now.timeIntervalSince1970)
    }

    /// Key and salt lengths a verifier may carry. `matches` derives `hash.count` bytes, so a synced verifier with a huge
    /// hash could otherwise keep a core busy for minutes on every check.
    static let hashLengths = 16...64
    static let saltLengths = 8...64

    /// True when the verifier is one this build can check (a newer build's algorithm, or out-of-range key material, is
    /// not: the prompt then says to update Nib instead of counting wrong entries).
    var isUsable: Bool {
        algorithm == LockVerifier.algorithmName && (1...LockVerifier.maximumIterations).contains(iterations)
            && LockVerifier.saltLengths.contains(salt.count) && LockVerifier.hashLengths.contains(hash.count)
    }

    /// Checks a password (off the main actor). An unusable verifier accepts nothing.
    func matches(_ password: String) async -> Bool {
        guard isUsable else { return false }
        guard let derived = await PasswordHasher.deriveDetached(password: password, salt: salt, iterations: iterations,
                                                                length: hash.count) else { return false }
        return PasswordHasher.constantTimeEquals(derived, hash)
    }
}

enum PasswordHasher {
    static let saltLength = 16
    static let keyLength = 32

    /// PBKDF2-HMAC-SHA256 (CommonCrypto). The password is NFC-normalised first, so the same password typed on two
    /// keyboards (precomposed or combining accents) gives the same key. nil for an empty password or bad parameters.
    static func derive(password: String, salt: Data, iterations: Int, length: Int = keyLength) -> Data? {
        let bytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        guard !bytes.isEmpty, !salt.isEmpty, iterations > 0, iterations <= Int(UInt32.max), length > 0 else { return nil }
        var derived = [UInt8](repeating: 0, count: length)
        let status: Int32 = bytes.withUnsafeBufferPointer { pw in
            salt.withUnsafeBytes { saltBytes in
                pw.withMemoryRebound(to: CChar.self) { chars in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), chars.baseAddress, chars.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         &derived, length)
                }
            }
        }
        return Int(status) == kCCSuccess ? Data(derived) : nil
    }

    /// `derive` on a detached task, so hundreds of thousands of rounds never block the main actor.
    static func deriveDetached(password: String, salt: Data, iterations: Int, length: Int = keyLength) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            derive(password: password, salt: salt, iterations: iterations, length: length)
        }.value
    }

    static func makeSalt(count: Int = saltLength) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes)
    }

    /// Compares every byte whatever the first difference, so timing says nothing about the hash.
    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

/// What a new password must satisfy (the setup sheet shows the first problem under the fields).
enum PasswordRules {
    static let minimumLength = 4

    enum Problem: Equatable {
        case tooShort
        case mismatch
        case hintRevealsPassword
    }

    static func problems(password: String, confirmation: String, hint: String) -> [Problem] {
        var out: [Problem] = []
        if password.count < minimumLength { out.append(.tooShort) }
        if password != confirmation { out.append(.mismatch) }
        if revealsPassword(hint: hint, password: password) { out.append(.hintRevealsPassword) }
        return out
    }

    static func revealsPassword(hint: String, password: String) -> Bool {
        let p = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        return hint.range(of: p, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func message(_ problem: Problem) -> String {
        switch problem {
        case .tooShort:
            return String(localized: "Use at least \(minimumLength) characters.")
        case .mismatch:
            return String(localized: "The passwords don't match.")
        case .hintRevealsPassword:
            return String(localized: "The hint can't contain the password.")
        }
    }
}

// MARK: - Wrong entries and relocking (pure)

/// Wrong passwords in a row. The hint shows from the third one on (and stays until a password is accepted).
struct UnlockAttempts: Equatable {
    static let hintThreshold = 3
    private(set) var failures = 0

    var showsHint: Bool { failures >= UnlockAttempts.hintThreshold }

    mutating func recordFailure() { failures += 1 }
    mutating func reset() { failures = 0 }
}

/// Relocks every unlocked document two minutes after Nib leaves the screen (and at once when the device locks).
struct RelockPolicy: Equatable {
    static let delay: TimeInterval = 120
    /// When Nib went to the background; nil while it is in front.
    private(set) var leftAt: Date?

    mutating func didLeave(at date: Date) {
        if leftAt == nil { leftAt = date }
    }

    func isDue(at date: Date) -> Bool {
        guard let left = leftAt else { return false }
        return date.timeIntervalSince(left) >= RelockPolicy.delay
    }

    /// Nib is in front again: true when the documents must lock now.
    mutating func didReturn(at date: Date) -> Bool {
        defer { leftAt = nil }
        return isDue(at: date)
    }
}

// MARK: - Biometrics

enum BiometryKind: String, Equatable {
    case faceID, touchID, opticID

    /// Apple's product names (not translated).
    var name: String {
        switch self {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        }
    }
}

/// LocalAuthentication behind a seam, so hostless tests never touch it.
@MainActor
protocol BiometricAuthenticating: AnyObject {
    /// The biometry this device can use right now (enrolled and allowed); nil = none.
    var kind: BiometryKind? { get }
    func authenticate(reason: String) async -> Bool
}

@MainActor
final class SystemBiometrics: BiometricAuthenticating {
    var kind: BiometryKind? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return nil }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        case .none: return nil
        @unknown default: return nil
        }
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        // The fallback button ends the system sheet; Nib's own password prompt is the fallback.
        context.localizedFallbackTitle = String(localized: "Enter Password")
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            return false
        }
    }
}

// MARK: - UI seam

/// What the unlock prompt is for.
enum UnlockPurpose: Equatable {
    /// Open or read a locked document (the open gate, `doc.unlock`).
    case open
    /// Remove its lock (`doc.setLocked {locked: false}`): always the password.
    case removeLock
    /// Prove the password before a lock setting changes (turning on Face ID, `settings.set` of the verifier): always
    /// the password, never biometrics. `action` is the primary button ("Turn On Face ID"), `message` the explanation.
    case verify(action: String, message: String)
}

/// One password try, as the prompt shows it.
enum PasswordCheck: Equatable {
    case accepted
    /// Wrong. `hint` is set from the third wrong entry in a row ("" when the password has no hint).
    case rejected(failures: Int, hint: String?)
    /// No password is set up, so there is nothing to check against.
    case notConfigured
    /// The library's password was set by a newer Nib (or its verifier is damaged): this build cannot check it. Not a
    /// wrong entry, so it never counts towards the hint.
    case unsupported
}

enum UnlockOutcome: Equatable { case unlocked, cancelled }

@MainActor
struct UnlockRequest {
    /// The document to open or unlock; nil for `.verify`.
    var doc: DocumentID?
    var documentTitle: String
    var purpose: UnlockPurpose
    /// Who asked: the user, or the assistant, a plugin or a bridge client (the prompt says so).
    var requester: Principal
    /// Offered as a button when this device unlocks with biometrics (never for `removeLock`).
    var biometry: BiometryKind?
    /// Already due from earlier wrong entries ("" = no hint was set).
    var hint: String?
    var check: @MainActor (String) async -> PasswordCheck
    var biometric: @MainActor () async -> Bool
}

enum PasswordSetupMode: Equatable { case create, change }

@MainActor
struct PasswordSetupRequest {
    var mode: PasswordSetupMode
    /// Why the sheet is shown when something else asked for it ("Set a password to lock “Physics”.").
    var reason: String?
    var hint: String
    var biometry: BiometryKind?
    var biometricsOn: Bool
    /// Documents that still carry a lock (the password cannot be turned off while there are any).
    var lockedDocuments: Int
    /// Checks the current password (change mode).
    var check: @MainActor (String) async -> PasswordCheck

    /// Create mode while documents already carry a lock: their password has not synced to this device yet. Setting a
    /// new one replaces the library's password on every device, so the sheet asks for an explicit confirmation.
    var replacesMissingPassword: Bool { mode == .create && lockedDocuments > 0 }
}

struct PasswordSetupResult: Equatable {
    enum Action: Equatable {
        case create(password: String)
        /// nil keeps the current password (only the hint or Face ID changed).
        case change(newPassword: String?)
        case remove
    }

    var action: Action
    var hint: String
    var biometrics: Bool
    /// The person confirmed that the new password replaces a library password that has not synced yet
    /// (`PasswordSetupRequest.replacesMissingPassword`); `lock.setup` refuses such a create without it.
    var confirmedReplacement = false
}

/// The screens the lock shows. `LockUIPresenter` (UnlockPrompt.swift) in the app; a scripted fake in tests; nil in
/// hostless runs (commands then throw `unavailable`).
@MainActor
protocol LockPresenting: AnyObject {
    func presentUnlock(_ request: UnlockRequest) async -> UnlockOutcome
    func presentSetup(_ request: PasswordSetupRequest) async -> PasswordSetupResult?
    /// After a relock: covers every window that shows a locked document with the locked field.
    func coverLockedWindows()
    /// `doc` was unlocked: removes its covers.
    func uncover(_ doc: DocumentID)
}

// MARK: - The service

/// `services.lock`, `gateway.isLocked` and the engine behind `ui.openGate`, `doc.unlock`, `doc.setLocked` and
/// `lock.setup`. A document is locked when its head says `meta.locked` and it has not been unlocked in this app session.
@MainActor
final class LockServiceImpl: LockService {
    static let serviceKey = "lock.service"
    /// `lock.changed` {docs, locked, reason}: which documents are locked changed. reason = unlock | relock | background |
    /// deviceLocked (this session's unlocks) or lockAdded | lockRemoved (a document's `meta.locked` flipped: a command,
    /// an undo or a remote merge). `locked` is whether the documents are locked for this session now.
    static let changedEvent = "lock.changed"

    private weak var app: NibApp?
    private let settings: SettingsStore
    let log = Logger(subsystem: "app.nib", category: "lock")

    var presenter: LockPresenting?
    var biometrics: BiometricAuthenticating?
    /// PBKDF2 rounds for new verifiers (tests lower it).
    var iterations = LockVerifier.defaultIterations
    var now: () -> Date = { Date() }

    /// Unlocked in this app session (emptied by a relock).
    private(set) var unlocked = Set<DocumentID>()
    /// `meta.locked` of documents that are not loaded, from commits, remote merges and one head peek.
    private var flags: [DocumentID: Bool] = [:]
    private(set) var attempts = UnlockAttempts()
    private(set) var relock = RelockPolicy()
    /// Set by `doc.setLocked` / the open gate before they run `lock.setup`, so the sheet says why it appeared.
    var pendingSetupReason: String?
    private var inFlight: [String: Task<Bool, Never>] = [:]
    /// Undo groups whose undo put a document's lock back (from observed undo commits). While the document can redo, a
    /// redo may remove the lock again, so `edit.redo` from the assistant, a plugin or the bridge is refused (LockCommands).
    private var relockedByUndo: [DocumentID: Set<String>] = [:]
    private var backgroundRelock: Task<Void, Never>?
    private var commitSubscription: EventSubscription?
    private var eventSubscription: EventSubscription?
    private var cancellables = Set<AnyCancellable>()
    private(set) var isStarted = false

    init(app: NibApp) {
        self.app = app
        self.settings = app.settings
    }

    // MARK: LockService

    func isLocked(_ doc: DocumentID) -> Bool {
        !unlocked.contains(doc) && isFlagged(doc)
    }

    func unlock(_ doc: DocumentID) async -> Bool {
        await unlock(doc, purpose: .open, requester: .user)
    }

    // MARK: State

    /// The document's `meta.locked`: the loaded head when it is open, else what commits told us, else the library
    /// catalog, else one head peek (cached).
    func isFlagged(_ doc: DocumentID) -> Bool {
        guard let app = app else { return flags[doc] ?? false }
        let workspace = app.workspace
        if workspace.isLoaded(doc), let head = try? workspace.content(doc) { return head.meta.locked }
        if let known = flags[doc] { return known }
        if let node = app.services.library?.node(doc), node.kind == .document { return node.locked }
        guard let head = try? workspace.peekContent(doc) else { return false }
        flags[doc] = head.meta.locked
        return head.meta.locked
    }

    var verifier: LockVerifier? { settings.get(LockSettings.verifier) }

    /// A password is set up: a verifier is stored, even one this build cannot read (a newer Nib's), so nobody can set
    /// a new password over it from here.
    var isConfigured: Bool {
        if verifier != nil { return true }
        guard let raw = settings.json(LockSettings.verifier.name) else { return false }
        return raw != .null
    }

    /// Face ID / Touch ID is on for this device and usable now.
    var biometricsEnabled: Bool {
        settings.get(LockSettings.biometrics) && biometrics?.kind != nil
    }

    /// Documents that carry a lock (catalog and open heads), unlocked in this session or not.
    func lockedDocuments() -> Set<DocumentID> {
        guard let app = app else { return Set(flags.filter { $0.value }.keys) }
        var out = Set<DocumentID>()
        if let library = app.services.library {
            for node in library.allNodes() + library.trashedNodes() where node.kind == .document && node.locked {
                out.insert(node.id)
            }
        }
        for (doc, locked) in flags where !app.workspace.isLoaded(doc) {
            if locked { out.insert(doc) } else if app.services.library?.node(doc) == nil { out.remove(doc) }
        }
        for doc in app.workspace.loadedDocuments {
            guard let head = try? app.workspace.content(doc) else { continue }
            if head.meta.locked { out.insert(doc) } else { out.remove(doc) }
        }
        return out
    }

    func title(_ doc: DocumentID) -> String {
        app?.services.library?.node(doc)?.title ?? String(localized: "this document")
    }

    /// True when a window shows `doc` now: its session's document (locking it there keeps it open for this session).
    /// A window's navigator keeps `activeDocument` and its tabs after Back to the library, so they do not count; a
    /// background tab locks at once and meets the open gate when it is switched to.
    func isOpenInWindow(_ doc: DocumentID) -> Bool {
        guard let app = app else { return false }
        return app.services.sessions.sessions.contains { $0.document == doc }
    }

    // MARK: Password checks

    /// Checks one password try against the library's verifier and counts wrong entries (hint from the third). A
    /// verifier this build cannot check answers `.unsupported` without counting.
    func check(_ password: String) async -> PasswordCheck {
        guard let v = verifier else { return isConfigured ? .unsupported : .notConfigured }
        guard v.isUsable else { return .unsupported }
        if await v.matches(password) {
            attempts.reset()
            return .accepted
        }
        attempts.recordFailure()
        log.info("wrong password (\(self.attempts.failures, privacy: .public) in a row)")
        return .rejected(failures: attempts.failures, hint: attempts.showsHint ? (verifier ?? v).hint : nil)
    }

    /// The hint when it is already due (three wrong entries in a row before this prompt).
    var dueHint: String? { attempts.showsHint ? verifier?.hint : nil }

    func authenticateBiometric(reason: String) async -> Bool {
        guard let biometrics = biometrics, biometrics.kind != nil else { return false }
        let ok = await biometrics.authenticate(reason: reason)
        if ok { attempts.reset() }
        return ok
    }

    // MARK: Unlocking

    /// Asks the person at the device to unlock `doc` (Face ID or the password). `.open` marks it unlocked for this
    /// session; `.removeLock` only proves the password. One prompt per document and purpose at a time.
    func unlock(_ doc: DocumentID, purpose: UnlockPurpose, requester: Principal) async -> Bool {
        if purpose == .open && !isLocked(doc) { return true }
        let key = doc.raw + (purpose == .open ? "#open" : "#remove")
        if let running = inFlight[key] { return await running.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self = self else { return false }
            return await self.prompt(doc, purpose: purpose, requester: requester)
        }
        inFlight[key] = task
        let ok = await task.value
        inFlight[key] = nil
        return ok
    }

    private func prompt(_ doc: DocumentID, purpose: UnlockPurpose, requester: Principal) async -> Bool {
        let name = title(doc)
        guard isConfigured else {
            // A lock without a password: the library's password has not synced to this device yet (or its prefs were
            // lost). Fail closed: nothing opens. Only the person at the device may set a new password, and the sheet
            // asks them to confirm that it replaces the library's password on every device.
            guard requester.isUser, await setUpPasswordToUnlock(doc, title: name) else { return false }
            if purpose == .open { markUnlocked(doc, reason: "unlock") }
            return true
        }
        let offersBiometrics = purpose == .open && biometricsEnabled
        // The user's own open tries Face ID first (the iOS convention). A request from the assistant, a plugin or the
        // bridge always shows Nib's prompt first, so a glance at the screen can never unlock silently.
        if offersBiometrics && requester.isUser,
           await authenticateBiometric(reason: String(localized: "Unlock “\(name)”")) {
            markUnlocked(doc, reason: "unlock")
            return true
        }
        guard let presenter = presenter else { return false }
        let request = UnlockRequest(
            doc: doc, documentTitle: name, purpose: purpose, requester: requester,
            biometry: offersBiometrics ? biometrics?.kind : nil, hint: dueHint,
            check: { [weak self] password in await self?.check(password) ?? .notConfigured },
            biometric: { [weak self] in
                await self?.authenticateBiometric(reason: String(localized: "Unlock “\(name)”")) ?? false
            })
        guard await presenter.presentUnlock(request) == .unlocked else { return false }
        if purpose == .open { markUnlocked(doc, reason: "unlock") }
        return true
    }

    /// Runs `lock.setup` as the user with a reason; true when a password exists afterwards.
    private func setUpPasswordToUnlock(_ doc: DocumentID, title: String) async -> Bool {
        guard let app = app, presenter != nil else { return false }
        pendingSetupReason = String(localized: "“\(title)” is locked, but this library's password hasn't reached this device yet. Wait for it to sync, or set a new password to replace it on every device.")
        defer { pendingSetupReason = nil }
        do {
            _ = try await app.bus.execute(Invocation(command: LockIDs.setup, principal: .user,
                                                     session: app.services.sessions.active))
        } catch {
            log.error("password setup failed: \(NibError.wrap(error).description, privacy: .public)")
        }
        return isConfigured
    }

    /// Asks the person at the device for the password (never biometrics) before a lock setting changes. False when
    /// no password is set up, nobody is there to answer, or they cancel.
    func verifyPassword(action: String, message: String) async -> Bool {
        guard isConfigured, let presenter = presenter else { return false }
        let key = "#verify"
        if let running = inFlight[key] { return await running.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self = self else { return false }
            let request = UnlockRequest(
                doc: nil, documentTitle: String(localized: "Password Protection"),
                purpose: .verify(action: action, message: message), requester: .user, biometry: nil, hint: self.dueHint,
                check: { [weak self] password in await self?.check(password) ?? .notConfigured },
                biometric: { false })
            return await presenter.presentUnlock(request) == .unlocked
        }
        inFlight[key] = task
        let ok = await task.value
        inFlight[key] = nil
        return ok
    }

    func markUnlocked(_ doc: DocumentID, reason: String) {
        let inserted = unlocked.insert(doc).inserted
        presenter?.uncover(doc)
        guard inserted else { return }
        app?.events.emit(LockServiceImpl.changedEvent, doc: doc,
                         payload: ["docs": [.string(NodeRef.document(doc).description)], "locked": false,
                                   "reason": .string(reason)])
        app?.ui.setNeedsChromeUpdate()
    }

    /// After `doc.setLocked`: a document the user locks in front of them stays open for this session; any other one
    /// locks now, and a window that shows it (the assistant, a plugin or the bridge locked it) gets the locked field.
    func didSetLocked(_ doc: DocumentID, locked: Bool, keepUnlocked: Bool) {
        flags[doc] = locked
        if locked && !keepUnlocked {
            unlocked.remove(doc)
        } else {
            unlocked.insert(doc)
        }
        lockDidChange(doc, added: locked)
        coverIfShown(doc)
        app?.ui.setNeedsChromeUpdate()
    }

    /// Covers the windows that show `doc` when it is locked for this session (DESIGN.md §14.2).
    func coverIfShown(_ doc: DocumentID) {
        guard isLocked(doc), isOpenInWindow(doc) else { return }
        presenter?.coverLockedWindows()
    }

    /// The password changed or was turned off: wrong-entry counting starts again.
    func passwordDidChange() {
        attempts.reset()
        app?.ui.setNeedsChromeUpdate()
    }

    func makeSetupRequest() -> PasswordSetupRequest {
        let current = verifier
        return PasswordSetupRequest(
            mode: isConfigured ? .change : .create, reason: pendingSetupReason, hint: current?.hint ?? "",
            biometry: biometrics?.kind, biometricsOn: settings.get(LockSettings.biometrics),
            lockedDocuments: lockedDocuments().count,
            check: { [weak self] password in await self?.check(password) ?? .notConfigured })
    }

    // MARK: Relocking

    /// Locks every document again and covers the windows that show one.
    func relockAll(reason: String = "relock") {
        let docs = unlocked
        unlocked.removeAll()
        if !docs.isEmpty {
            log.info("relocked \(docs.count, privacy: .public) document(s): \(reason, privacy: .public)")
            app?.events.emit(LockServiceImpl.changedEvent,
                             payload: ["docs": .array(docs.map { .string(NodeRef.document($0).description) }),
                                       "locked": true, "reason": .string(reason)])
        }
        presenter?.coverLockedWindows()
        app?.ui.setNeedsChromeUpdate()
    }

    func appDidEnterBackground() {
        relock.didLeave(at: now())
        backgroundRelock?.cancel()
        // Nib may keep running in the background (recording, a download): relock on time there too.
        backgroundRelock = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RelockPolicy.delay * 1_000_000_000))
            guard let self = self, !Task.isCancelled, self.relock.isDue(at: self.now()) else { return }
            self.relockAll(reason: "background")
        }
    }

    func appWillEnterForeground() {
        backgroundRelock?.cancel()
        backgroundRelock = nil
        if relock.didReturn(at: now()) { relockAll(reason: "background") }
    }

    func deviceWillLock() {
        relockAll(reason: "deviceLocked")
    }

    // MARK: Observation

    /// Follows lock changes of documents that are not open and the app's lifecycle (FeatLockFeature.start).
    func start() {
        guard !isStarted, let app = app else { return }
        isStarted = true
        commitSubscription = app.bus.observeCommits { [weak self] changeset in
            self?.observe(changeset)
        }
        eventSubscription = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.libraryChanged() }
            } else {
                Task { @MainActor in self?.libraryChanged() }
            }
        }
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.appDidEnterBackground() }
            .store(in: &cancellables)
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.appWillEnterForeground() }
            .store(in: &cancellables)
        center.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)
            .sink { [weak self] _ in self?.deviceWillLock() }
            .store(in: &cancellables)
    }

    /// Commits, undo and remote merges that flip `meta.locked`. A document that becomes locked while a window shows it
    /// (a remote device locked it, an undo or redo put the lock back) gets the locked field unless this session
    /// unlocked it; `doc.setLocked` covers in `didSetLocked`, after it decided whether the document stays open.
    func observe(_ changeset: Changeset) {
        var flipped: [DocumentID: Bool] = [:]
        for mutation in changeset.mutations {
            guard case let .meta(doc, before, after) = mutation, before.locked != after.locked else { continue }
            flags[doc] = after.locked
            flipped[doc] = after.locked
            if changeset.command == CommandIDs.undo, after.locked, changeset.group.hasPrefix("undo:") {
                relockedByUndo[doc, default: []].insert(String(changeset.group.dropFirst("undo:".count)))
            }
        }
        if changeset.command == CommandIDs.redo, changeset.group.hasPrefix("redo:") {
            let group = String(changeset.group.dropFirst("redo:".count))
            for doc in changeset.documents { relockedByUndo[doc]?.remove(group) }
        }
        // `doc.setLocked` reports and covers in `didSetLocked`, once it knows whether the document stays open.
        guard !flipped.isEmpty, changeset.command != LockIDs.setLocked else { return }
        for (doc, locked) in flipped.sorted(by: { $0.key.raw < $1.key.raw }) {
            lockDidChange(doc, added: locked)
            if locked { coverIfShown(doc) }
        }
        app?.ui.setNeedsChromeUpdate()
    }

    /// `lock.changed` for a document whose `meta.locked` flipped.
    private func lockDidChange(_ doc: DocumentID, added: Bool) {
        app?.events.emit(LockServiceImpl.changedEvent, doc: doc,
                         payload: ["docs": [.string(NodeRef.document(doc).description)], "locked": .bool(isLocked(doc)),
                                   "reason": .string(added ? "lockAdded" : "lockRemoved")])
    }

    // MARK: Undo, redo and revert (LockCommands' guard)

    /// True when reverting `entry` would take `doc`'s lock off: its first write of the document's meta had no lock
    /// and the document carries one now.
    func revertRemovesLock(_ entry: UndoEntry, doc: DocumentID) -> Bool {
        let first = entry.mutations.lazy.compactMap { mutation -> DocumentMeta? in
            guard case let .meta(d, before, _) = mutation, d == doc else { return nil }
            return before
        }.first
        guard let before = first, !before.locked else { return false }
        return isFlagged(doc)
    }

    /// True when `edit.undo` / `edit.redo` / `history.revertGroup` on `doc` could remove a lock (of `doc` or, for a
    /// group linked across documents, of another document).
    func historyStepRemovesLock(command: String, doc: DocumentID, group: String?, history: UndoHistory) -> Bool {
        switch command {
        case CommandIDs.undo:
            guard let entry = history.entries(doc).last else { return false }
            if revertRemovesLock(entry, doc: doc) { return true }
            guard entry.linked else { return false }
            return lockedDocuments().contains { other in
                other != doc && history.entries(other).last.map { $0.group == entry.group && revertRemovesLock($0, doc: other) } ?? false
            }
        case CommandIDs.revertGroup:
            guard let group = group, let entry = history.entries(doc).last(where: { $0.group == group }) else { return false }
            return revertRemovesLock(entry, doc: doc)
        case CommandIDs.redo:
            // Redo entries are not readable, so this errs on the safe side: the step is "Remove Lock", or an undo in
            // this session put a lock back that a redo could take off again.
            if history.redoLabel(doc) == DocSetLocked.removeTitle { return true }
            func mayUnlock(_ d: DocumentID) -> Bool {
                guard history.canRedo(d) else {
                    relockedByUndo[d] = nil
                    return false
                }
                return !(relockedByUndo[d] ?? []).isEmpty && isFlagged(d)
            }
            if mayUnlock(doc) { return true }
            return Array(relockedByUndo.keys).contains { other in
                other != doc && mayUnlock(other) && (relockedByUndo[other] ?? []).contains { history.isLinked($0) }
            }
        default:
            return false
        }
    }

    /// The catalog was rebuilt (sync, import, rename): it now knows the heads of documents that are not open.
    func libraryChanged() {
        guard let app = app else { return }
        flags = flags.filter { app.workspace.isLoaded($0.key) }
    }
}

/// Command and component ids.
enum LockIDs {
    static let setup = "lock.setup"
    static let setLocked = "doc.setLocked"
    static let unlock = "doc.unlock"
    static let unlockGuard = "lock.unlockGuard"
    static let undoGuard = "lock.undoGuard"
    static let settingsGuard = "lock.settingsGuard"
    static let sessionGuard = "lock.sessionGuard"
    /// The commands this feature owns (the session guard leaves them to their own checks).
    static let commands: Set<String> = [setup, setLocked, unlock]
    static let settingsPage = "lock.settings"
    static let menuLockLibrary = "lock.library.lock"
    static let menuUnlockLibrary = "lock.library.removeLock"
    static let menuLockDocument = "lock.document.lock"
    static let menuUnlockDocument = "lock.document.removeLock"
}
